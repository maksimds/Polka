import Foundation
import Network
import Security
import SystemConfiguration

/// Nearby Sharing (N1: NS-1 to NS-3, N2: links and text, N3: files). While the Settings switch is
/// on, Polka advertises `_polka._tcp` under a random name and listens for TLS
/// connections. It browses for other Polkas only while something needs the list (the
/// Settings window, the open shelf), since browsing keeps the Wi-Fi radio hopping to
/// the peer-to-peer channel, which costs battery. Each Polka found is asked its name in
/// a short `hello` exchange.
///
/// Offers that arrive wait in `offers` for the panel to show them, in the order and at
/// the pace `NearbyOfferLine` allows; `send` makes an offer to a Mac found nearby.
/// Offers from a remembered Mac (N4) skip all that and are accepted on their own.
/// Remembering happens while the Settings Remember sheet is open (`startRemembering`).
///
/// Follows the settings by itself: UserDefaults says when any of them changes.
@MainActor
final class NearbyService: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case on
        /// macOS's Local Network access was turned down for Polka.
        case noLocalNetwork
        case failed(String)
    }

    /// Another Polka nearby that told its name.
    struct Peer: Identifiable, Equatable {
        /// Its Bonjour name, new each time it starts advertising.
        let id: String
        /// The name it sent. Not verified.
        let heardName: String
        let fingerprint: String?
        /// Its whole public key, from the TLS session.
        var publicKey: Data? = nil
        let isPeerToPeer: Bool
        /// Its protocol version: below `NearbyProtocol.offerVersion`, it can't be sent to.
        var version = NearbyProtocol.version
        /// The name it has among the remembered Macs, if its key is one of theirs.
        var rememberedName: String? = nil

        /// What it's shown as: its remembered name, or the name it sent.
        var name: String { rememberedName ?? heardName }
        var isRemembered: Bool { rememberedName != nil }
        var takesOffers: Bool { version >= NearbyProtocol.offerVersion }
        var canRemember: Bool { version >= NearbyProtocol.rememberVersion }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var peers: [Peer] = []
    /// When the current look for Macs nearby began, or nil while not looking. Send To
    /// says "Looking for Macs…" at first, and "No Macs Nearby" once it's had a while.
    @Published private(set) var browsingSince: Date?
    /// Offers waiting for an answer, in the order they arrived.
    @Published private(set) var offers: [NearbyIncomingOffer] = []
    /// Accepted offers still arriving, in the order they were accepted.
    @Published private(set) var receiving: [NearbyReceiving] = []
    /// The Macs remembered here, in the order they were remembered.
    @Published private(set) var rememberedMacs: [NearbyRememberedMac] = []
    /// Where the Remember sheet stands; nil while it's closed.
    @Published private(set) var rememberPhase: NearbyRememberPhase?

    /// What an accepted offer brought, once it has all arrived and checked out, with
    /// the name the sender gave (a remembered Mac's remembered name), and whether it
    /// came from a remembered Mac, accepted without asking.
    var onReceived: ((_ items: [NearbyReceivedItem], _ senderName: String, _ fromRemembered: Bool) -> Void)?
    /// A remembered Mac's offer was turned away: its files don't fit on the disk with
    /// `spareSpace` to spare.
    var onRememberedOfferTooLarge: ((_ senderName: String) -> Void)?
    /// Where the remembered Macs are kept. Setting it reads them; without it they're
    /// only kept until Polka quits, as in tests.
    var rememberedFile: URL? {
        didSet {
            remembered = rememberedFile.map(NearbyRememberedList.load(from:)) ?? NearbyRememberedList()
            rememberedChanged(save: false)
        }
    }
    /// An accepted offer that never fully arrived, with the name the sender gave and
    /// why: the sender stopped it, or something went wrong. Nothing from it was kept.
    /// Not called when the person here cancelled.
    var onReceiveFailed: ((_ senderName: String, _ cancelledByThem: Bool) -> Void)?

    /// Where received files are written. Without it, offers of files are declined.
    var copies: ShelfCopies?
    /// Where link icons are saved, for the pictures an offer of links brings.
    var previewsFolder: URL?

    /// What Accept needs free on the disk beyond the files themselves.
    static let spareSpace: Int64 = 2_000_000_000

    enum AcceptResult: Equatable {
        case accepted
        /// The files plus `spareSpace` don't fit on the disk. The offer is declined.
        case notEnoughSpace
        /// The offer is no longer waiting.
        case gone
    }

    /// The Mac's name, as in System Settings > General > Sharing, which is what AirDrop
    /// shows too.
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap(NearbyName.clean) ?? "Mac"
    }

    /// The Settings switch.
    var isEnabled: Bool { settings.nearbySharingEnabled }

    /// The port the listener took, once it's listening. Only tests use it, to reach
    /// this Mac directly rather than through Bonjour. A listener just started says 0
    /// until it has one.
    var listeningPort: NWEndpoint.Port? {
        guard let port = listener?.port, port.rawValue != 0 else { return nil }
        return port
    }

    /// The random Bonjour name it advertises under, while it does. Only tests use it.
    var advertisedName: String? { listener == nil ? nil : serviceName }

    /// This Mac's public key, once it's been read from the Keychain.
    var thisMacKey: Data? { identity?.publicKey }

    /// The name others see right now.
    var displayName: String {
        ShelfSettings.nearbyName(typed: settings.nearbyName, macName: Self.macName)
    }

    private let settings: ShelfSettings
    /// Which Keychain key is this Mac's; tests pass their own.
    private let identityTag: String
    private var identity: NearbyIdentity?
    private var isMakingIdentity = false
    /// Set when the identity couldn't be made, so it isn't tried again on every
    /// settings change, only once the switch goes off and on.
    private var identityFailed = false
    private var listener: NWListener?
    /// What the listener was started with, so a change restarts it: the name, and
    /// whether every Mac hears it, or only remembered ones.
    private var advertised: (name: String, visibleToAll: Bool)?
    private var browser: NWBrowser?
    private var browseRequests = 0
    private var exchanges: [ObjectIdentifier: NearbyHelloExchange] = [:]
    private var incoming: [UUID: NearbyIncomingSession] = [:]
    private var outgoing: [UUID: NearbyOutgoingSession] = [:]
    /// Sends whose files and pictures are still being got ready.
    private var preparing: Set<UUID> = []
    /// The free space on the disk that holds `url`; tests pass their own.
    private let freeSpace: (URL) -> Int64?
    /// Accepted offers still arriving.
    private var accepted: Set<UUID> = []
    /// Those of them accepted without asking, from remembered Macs.
    private var acceptedWithoutAsking: Set<UUID> = []
    private var remembered = NearbyRememberedList()
    private var rememberSession: NearbyRememberSession?
    /// Until when the Remember sheet takes a request.
    private var rememberLooksUntil: Date?
    private var rememberDeadline: DispatchWorkItem?
    /// How long the Remember sheet takes requests (PRD: Remembering spam).
    static let rememberWindow: TimeInterval = 120
    private var line = NearbyOfferLine()
    /// Where each Mac found nearby can be reached, by its Bonjour name.
    private var endpoints: [String: NWEndpoint] = [:]
    private let answerTimeout: TimeInterval
    /// Bonjour names asked for their name since browsing started.
    private var asked: Set<String> = []
    /// How many times each Bonjour name was asked without an answer.
    private var unanswered: [String: Int] = [:]
    private var serviceName = NearbyService.randomServiceName()
    private var defaultsObserver: NSObjectProtocol?

    /// Connections at once, from every Mac together. Past it, a connection is turned
    /// away before its handshake.
    private static let maxIncoming = 8
    /// Of them, from Macs that aren't remembered (N6). A caller is only known by its key
    /// once its handshake is done, so one over this is turned away then, and a
    /// remembered Mac still gets through while strangers fill their share.
    private static let maxStrangers = 4
    /// The incoming connections from Macs that aren't remembered.
    private var strangerSessions: Set<UUID> = []
    private static let maxOutgoing = 8
    /// How many times a Polka is asked its name before it's left alone.
    private static let maxAsks = 6
    /// What Bonjour reports when Local Network access is turned down
    /// (`kDNSServiceErr_PolicyDenied`).
    private static let policyDenied: Int32 = -65570

    init(settings: ShelfSettings = ShelfSettings(), identityTag: String = NearbyIdentity.standardTag,
         answerTimeout: TimeInterval = NearbyOfferLine.answerTimeout,
         freeSpace: @escaping (URL) -> Int64? = NearbyService.freeSpace(at:)) {
        self.settings = settings
        self.identityTag = identityTag
        self.answerTimeout = answerTimeout
        self.freeSpace = freeSpace
    }

    /// What the disk holding `url` has free for files the person wants, as Finder
    /// counts it.
    nonisolated static func freeSpace(at url: URL) -> Int64? {
        var folder = url
        // The copies folder may not exist yet; its parent does.
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    func start() {
        // Taken on whatever thread changed a setting, then followed up on the main
        // thread a moment later. With `queue: .main`, the changing thread would wait for
        // the main thread to run it, and AppKit changes settings from background threads
        // too: text drawing for Convert to PDF registers defaults the first time it runs.
        // If the main thread was waiting on that thread right then (both setting up the
        // same AppKit class), neither could go on.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
        }
        apply()
    }

    /// Several changes in a row are followed up once.
    private var isApplyPending = false

    private func settingsChanged() {
        guard !isApplyPending else { return }
        isApplyPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isApplyPending = false
                self?.apply()
            }
        }
    }

    /// Stops everything and stops following the settings.
    func stop() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        stopAll()
    }

    /// Something wants the list of nearby Macs. Pair with `endBrowsing`.
    func beginBrowsing() {
        browseRequests += 1
        apply()
    }

    func endBrowsing() {
        browseRequests = max(browseRequests - 1, 0)
        apply()
    }

    // MARK: - Following the settings

    /// Brings what's running in line with the settings. Cheap, since UserDefaults says
    /// it changed for every setting, Polka's own included.
    private func apply() {
        guard settings.nearbySharingEnabled else {
            stopAll()
            return
        }
        guard let identity else {
            makeIdentity()
            return
        }
        let wanted = (name: displayName, visibleToAll: isVisibleToAll)
        if listener == nil || advertised?.name != wanted.name || advertised?.visibleToAll != wanted.visibleToAll {
            startListener(identity, as: wanted)
        }
        if browseRequests > 0 {
            if browser == nil { startBrowser() }
        } else if browser != nil {
            stopBrowser()
        }
    }

    private func stopAll() {
        guard status != .off || listener != nil || browser != nil else { return }
        listener?.cancel()
        listener = nil
        advertised = nil
        stopBrowser()
        endExchanges { _ in true }
        endIncoming()
        outgoing.values.forEach { $0.cancel() }
        outgoing = [:]
        preparing = []
        let session = rememberSession
        rememberSession = nil
        session?.cancel()
        rememberDeadline?.cancel()
        if rememberPhase != nil { rememberPhase = .stoppedLooking }
        identityFailed = false
        status = .off
        Log.nearby.info("Nearby Sharing is off")
    }

    private func makeIdentity() {
        guard !isMakingIdentity, !identityFailed else { return }
        isMakingIdentity = true
        status = .starting
        let tag = identityTag
        // The Keychain can stop to ask for permission, so not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NearbyIdentity.loadOrCreate(tag: tag) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.identityMade(result) }
            }
        }
    }

    private func identityMade(_ result: Result<NearbyIdentity, Error>) {
        isMakingIdentity = false
        switch result {
        case let .success(identity):
            self.identity = identity
            Log.nearby.info("Nearby identity ready")
            apply()
        case let .failure(error):
            identityFailed = true
            status = .failed("Polka couldn't make its key: \(error)")
            Log.nearby.error("Nearby identity failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Listener

    private func startListener(_ identity: NearbyIdentity, as wanted: (name: String, visibleToAll: Bool)) {
        listener?.cancel()
        // A new Bonjour name with every change, so Macs browsing see a new service and
        // ask again, and learn the new name, or that they no longer get one.
        serviceName = Self.randomServiceName()
        // Connections already made stay up through a change of name. Not through
        // hiding from all but remembered Macs, which shuts everyone else out at once.
        if advertised?.visibleToAll == true && !wanted.visibleToAll {
            incoming.values.filter { !remembered.contains($0.peerKey) }.forEach { $0.end(because: nil) }
        }
        advertised = wanted
        do {
            let listener = try NWListener(using: Self.parameters(identity))
            listener.service = NWListener.Service(name: serviceName, type: NearbyProtocol.serviceType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, listener === self.listener else { return }
                    self.listenerChanged(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            if status != .on { status = .starting }
            Log.nearby.info("Advertising as \(self.serviceName, privacy: .public), \(wanted.visibleToAll ? "to everyone" : "to remembered Macs", privacy: .public)")
        } catch {
            self.listener = nil
            status = .failed("Polka couldn't listen for Macs nearby (\(error.logCode)).")
            Log.nearby.error("Listener failed: \(error.logCode, privacy: .public)")
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .on
            Log.nearby.info("Listening")
        case let .waiting(error), let .failed(error):
            report(error, from: "Listener")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard incoming.count < Self.maxIncoming else {
            // Started only to be closed, so the other Mac hears at once that it was turned
            // away (its handshake fails) and asks again later, rather than waiting out its
            // handshake timeout for a connection nobody will ever answer.
            connection.start(queue: .main)
            connection.cancel()
            Log.nearby.info("Turned a connection away: too many at once")
            return
        }
        let session = NearbyIncomingSession(connection: connection) { [weak self] id, key in
            self?.greeting(for: id, caller: key) ?? .silence
        }
        incoming[session.id] = session
        session.onOffer = { [weak self] in self?.offered($0) }
        session.onRememberRequest = { [weak self] in self?.rememberRequested(by: $0) }
        session.onReceived = { [weak self, weak session] items in
            guard let self, let session else { return }
            self.received(items, by: session)
        }
        session.onProgress = { [weak self, weak session] done, total in
            guard let self, let session, let index = self.receiving.firstIndex(where: { $0.id == session.id }) else { return }
            self.receiving[index].receivedBytes = done
            self.receiving[index].totalBytes = total
        }
        session.onEnd = { [weak self] in self?.incomingEnded($0) }
        session.start()
    }

    private func endIncoming() {
        incoming.values.forEach { $0.end(because: nil) }
    }

    /// Every Mac hears this Mac's name, or only remembered ones: Receive From says
    /// which, but while the Remember sheet takes requests, everyone does, so a Mac
    /// that's to be remembered can find this one.
    private var isVisibleToAll: Bool {
        settings.nearbyReceiveFrom == .everyone || rememberPhase == .looking
    }

    /// What this Mac says to a caller, once its key is known: its name; nothing at all
    /// to a Mac it hides from; or, to a stranger past `maxStrangers`, that it's busy.
    private func greeting(for session: UUID, caller key: Data?) -> NearbyIncomingSession.Greeting {
        let isRemembered = remembered.contains(key)
        guard let advertised, advertised.visibleToAll || isRemembered else { return .silence }
        if !isRemembered {
            guard strangerSessions.count < Self.maxStrangers else {
                Log.nearby.info("Turned a connection away: too many from Macs that aren't remembered")
                return .busy
            }
            strangerSessions.insert(session)
        }
        return .hello(NearbyHello(version: NearbyProtocol.version, name: advertised.name))
    }

    // MARK: - Offers to this Mac

    /// The waiting offer the panel may show now, if none is on screen. Otherwise nil,
    /// with when to ask again, if an offer is waiting for its Mac's minute to pass.
    func nextOfferToShow() -> (id: UUID?, checkAgainAt: Date?) {
        line.next(at: Date())
    }

    /// The panel is showing this offer.
    func showingOffer(_ id: UUID) {
        line.show(id, at: Date())
    }

    /// Accept: the offer leaves the line, and its items arrive through `onReceived`,
    /// following `receiving` meanwhile. Declined instead if its files don't fit on the
    /// disk with `spareSpace` to spare.
    @discardableResult
    func accept(_ id: UUID) -> AcceptResult {
        guard let offer = offers.first(where: { $0.id == id }), let session = incoming[id] else { return .gone }
        guard hasRoom(for: offer.offer) else {
            decline(id)
            Log.nearby.info("Declined an offer: not enough space")
            return .notEnoughSpace
        }
        removeOffer(id)
        startReceiving(session, offer.offer, from: offer.senderName)
        return .accepted
    }

    /// The disk has room for the offer's files and `spareSpace` besides.
    private func hasRoom(for offer: NearbyOffer) -> Bool {
        guard offer.hasFiles else { return true }
        guard let copies, let free = freeSpace(copies.folder) else { return false }
        return free >= offer.totalFileBytes + Self.spareSpace
    }

    private func startReceiving(_ session: NearbyIncomingSession, _ offer: NearbyOffer, from name: String) {
        accepted.insert(session.id)
        receiving.append(NearbyReceiving(id: session.id, senderName: name, itemCount: offer.items.count,
                                         receivedBytes: 0, totalBytes: offer.totalFileBytes))
        session.answer(accept: true, copies: copies)
        Log.nearby.info("Accepted an offer of \(offer.totalFileBytes, privacy: .public) bytes of files")
    }

    /// Stops an accepted offer that's still arriving. Nothing from it is kept.
    func cancelReceiving(_ id: UUID) {
        guard accepted.contains(id), let session = incoming[id] else { return }
        session.cancel()
        Log.nearby.info("Stopped receiving")
    }

    /// Decline, or Decline and Block, which turns away that Mac's offers until Polka
    /// quits, and every Mac that isn't remembered for `NearbyOfferLine.blockPause`, the
    /// ones waiting included: the sender could come back with a new key.
    func decline(_ id: UUID, block: Bool = false) {
        guard let offer = offers.first(where: { $0.id == id }) else { return }
        if block { line.block(offer.fingerprint) }
        removeOffer(id)
        incoming[id]?.answer(accept: false, copies: nil)
        Log.nearby.info("Declined an offer\(block ? " and blocked its Mac" : "", privacy: .public)")
        if block {
            for waiting in offers { decline(waiting.id) }
        }
    }

    private func offered(_ session: NearbyIncomingSession) {
        guard let fingerprint = session.fingerprint, let name = session.senderName,
              let offer = session.offer else {
            session.end(because: "offer without a sender")
            return
        }
        // A remembered Mac's tiles arrive without asking (NS-12), with every check on
        // what arrives just the same. Remembered is its key, never its name.
        if let mac = heard(name, from: session.peerKey) {
            guard hasRoom(for: offer) else {
                session.answer(accept: false, copies: nil)
                Log.nearby.info("Turned a remembered Mac's offer away: not enough space")
                onRememberedOfferTooLarge?(mac.name)
                return
            }
            acceptedWithoutAsking.insert(session.id)
            startReceiving(session, offer, from: mac.name)
            return
        }
        // Hidden from all but remembered Macs: a stranger only gets this far while the
        // Remember sheet is open, and that's for remembering, not sharing.
        guard settings.nearbyReceiveFrom == .everyone else {
            session.answer(accept: false, copies: nil)
            Log.nearby.info("Turned an offer away: not from a remembered Mac")
            return
        }
        let admission = line.admit(id: session.id, fingerprint: fingerprint)
        guard admission == .admitted else {
            session.answer(accept: false, copies: nil)
            Log.nearby.info("Turned an offer away: \(String(describing: admission), privacy: .public)")
            return
        }
        offers.append(NearbyIncomingOffer(id: session.id, senderName: name, fingerprint: fingerprint,
                                          offer: offer, pictures: session.previews,
                                          usesRememberedName: remembered.mac(named: name) != nil))
        Log.nearby.info("""
            Offer of \(offer.items.count, privacy: .public) item(s) from \(name, privacy: .private), \
            \(self.offers.count, privacy: .public) waiting
            """)
        let id = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + answerTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.offers.contains(where: { $0.id == id }) else { return }
                Log.nearby.info("An offer wasn't answered in time")
                self.decline(id)
            }
        }
    }

    private func received(_ items: [NearbyReceivedItem], by session: NearbyIncomingSession) {
        let name = senderName(of: session)
        accepted.remove(session.id)
        receiving.removeAll { $0.id == session.id }
        let withoutAsking = acceptedWithoutAsking.remove(session.id) != nil
        Log.nearby.info("Received \(items.count, privacy: .public) item(s)\(withoutAsking ? " from a remembered Mac" : "", privacy: .public)")
        onReceived?(items, name, withoutAsking)
    }

    /// The name an accepted offer is shown under: a remembered Mac's remembered name.
    private func senderName(of session: NearbyIncomingSession) -> String {
        receiving.first { $0.id == session.id }?.senderName ?? session.senderName ?? ""
    }

    private func incomingEnded(_ session: NearbyIncomingSession) {
        let name = senderName(of: session)
        incoming[session.id] = nil
        strangerSessions.remove(session.id)
        acceptedWithoutAsking.remove(session.id)
        // Withdrawn: the other Mac went away before an answer.
        if offers.contains(where: { $0.id == session.id }) {
            removeOffer(session.id)
            Log.nearby.info("An offer was withdrawn")
        }
        receiving.removeAll { $0.id == session.id }
        if accepted.remove(session.id) != nil {
            switch session.ending {
            case .cancelledHere:
                break
            case .cancelledByThem:
                Log.nearby.info("The sender stopped an accepted offer")
                onReceiveFailed?(name, true)
            case .finished, .failed:
                Log.nearby.error("An accepted offer didn't fully arrive")
                onReceiveFailed?(name, false)
            }
        }
    }

    private func removeOffer(_ id: UUID) {
        line.remove(id)
        offers.removeAll { $0.id == id }
    }

    // MARK: - Offers from this Mac

    /// Offers these tiles to a Mac found nearby, leaving out any that can't be sent.
    /// Nil if the Mac is no longer there; otherwise the send's id, for
    /// `cancelSending`, and `onStatus` follows it to its end. Files are measured and
    /// pictures made in the background first, so a selection that's too large, or
    /// holds nothing that can go, fails through `onStatus`.
    @discardableResult
    func send(_ items: [ShelfItem], to peerID: String,
              onStatus: @escaping (NearbyOutgoingSession.Status) -> Void) -> UUID? {
        guard let identity, let peer = peers.first(where: { $0.id == peerID }), peer.takesOffers,
              let endpoint = endpoints[peerID] else { return nil }
        let id = UUID()
        preparing.insert(id)
        onStatus(.connecting)
        let previewsFolder = self.previewsFolder
        // Holds the service until it's done, a moment at most.
        Task.detached(priority: .userInitiated) {
            let result = Result { try NearbyOutgoingItem.prepare(items) }
            let previews: [Int: Data]
            if case let .success(pairs) = result {
                previews = await NearbyPreviewMaker.previews(for: pairs, previewsFolder: previewsFolder)
            } else {
                previews = [:]
            }
            let prepared = result.map { $0.map(\.item) }
            await self.prepared(id, prepared, previews: previews, to: peer, at: endpoint,
                                identity: identity, onStatus: onStatus)
        }
        return id
    }

    /// Stops a send, whether it's still being got ready, waiting for an answer, or
    /// sending.
    func cancelSending(_ id: UUID) {
        if preparing.remove(id) != nil {
            Log.nearby.info("Stopped a send before it went")
        }
        outgoing[id]?.cancel()
    }

    private func prepared(_ id: UUID, _ result: Result<[NearbyOutgoingItem], Error>, previews: [Int: Data],
                          to peer: Peer, at endpoint: NWEndpoint, identity: NearbyIdentity,
                          onStatus: @escaping (NearbyOutgoingSession.Status) -> Void) {
        // Cancelled, or Nearby Sharing turned off, meanwhile.
        guard preparing.remove(id) != nil else {
            onStatus(.cancelled)
            return
        }
        let items: [NearbyOutgoingItem]
        switch result {
        case let .success(prepared):
            items = prepared
        case .failure(NearbyOutgoingItem.Failure.tooLarge):
            onStatus(.failed(.tooLarge))
            return
        case .failure:
            onStatus(.failed(.nothingToSend))
            return
        }
        let transfer = NearbyOutgoingTransfer(items: items, previews: previews)
        if !transfer.files.isEmpty && peer.version < NearbyProtocol.fileVersion {
            onStatus(.failed(.tooOld))
            return
        }
        Log.nearby.info("""
            Offering \(items.count, privacy: .public) item(s), \(transfer.totalBytes, privacy: .public) bytes \
            of files, \(previews.count, privacy: .public) picture(s), to \(peer.name, privacy: .private)
            """)
        connect(id, transfer, to: peer, at: endpoint, identity: identity, attempt: 1, onStatus: onStatus)
    }

    /// How many times an offer is tried when the other Mac turns the connection away
    /// before saying anything, as it does while it's busy with other Macs.
    private static let maxOfferAttempts = 4

    private func connect(_ id: UUID, _ transfer: NearbyOutgoingTransfer, to peer: Peer, at endpoint: NWEndpoint,
                         identity: NearbyIdentity, attempt: Int,
                         onStatus: @escaping (NearbyOutgoingSession.Status) -> Void) {
        // A Mac that wants to share says who it is, even while it keeps its name from
        // everyone else (Remembered Macs Only): it chose to show it to this one.
        let hello = NearbyHello(version: NearbyProtocol.version, name: displayName)
        let session = NearbyOutgoingSession(connection: NWConnection(to: endpoint, using: Self.parameters(identity)),
                                            hello: hello, transfer: transfer,
                                            expectedFingerprint: peer.fingerprint)
        outgoing[id] = session
        session.onStatus = { [weak self, weak session] status in
            guard let self, let session, self.outgoing[id] === session else { return }
            if status == .failed(.unreachable), session.wasTurnedAway, attempt < Self.maxOfferAttempts {
                // Turned away: try again in a moment, the pause doubling each time.
                Log.nearby.info("An offer was turned away; trying again")
                self.outgoing[id] = nil
                self.preparing.insert(id)
                let pause = 0.4 * pow(2, Double(attempt - 1)) * Double.random(in: 0.8...1.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Stopped between two tries.
                        guard self.preparing.remove(id) != nil else {
                            onStatus(.cancelled)
                            return
                        }
                        self.connect(id, transfer, to: peer, at: endpoint, identity: identity,
                                     attempt: attempt + 1, onStatus: onStatus)
                    }
                }
                return
            }
            if status.isFinished { self.outgoing[id] = nil }
            if case .sending = status {} else {
                Log.nearby.info("Sending: \(String(describing: status), privacy: .public)")
            }
            onStatus(status)
        }
        session.start()
    }

    // MARK: - Remembering

    /// Forget: that Mac's offers go back to asking first, at once. The other Mac isn't
    /// told; each side keeps its own list.
    func forget(_ key: Data) {
        guard remembered.forget(key) else { return }
        rememberedChanged()
        Log.nearby.info("Forgot a remembered Mac")
    }

    /// The Remember sheet opened: Macs nearby are looked for, and one of them may ask to
    /// remember this one, for `rememberWindow`. Pair with `stopRemembering`.
    func startRemembering() {
        guard rememberPhase == nil else { return }
        beginBrowsing()
        lookForRememberRequests()
    }

    /// Try Again, after the time ran out or remembering didn't work.
    func rememberAgain() {
        guard rememberPhase != nil, rememberSession == nil else { return }
        lookForRememberRequests()
    }

    /// The sheet closed: anything going on is cancelled.
    func stopRemembering() {
        guard rememberPhase != nil else { return }
        endRememberSession()
        rememberDeadline?.cancel()
        rememberPhase = nil
        endBrowsing()
    }

    /// The person here picked a Mac in the sheet: asks it to remember this one.
    func remember(_ peerID: String) {
        guard rememberPhase == .looking, let identity,
              let peer = peers.first(where: { $0.id == peerID }), let endpoint = endpoints[peerID],
              peer.publicKey != identity.publicKey else { return }
        guard peer.canRemember else {
            rememberPhase = .failed(name: peer.name, .tooOld)
            apply()
            return
        }
        let session = NearbyRememberSession(asking: NWConnection(to: endpoint, using: Self.parameters(identity)),
                                            hello: NearbyHello(version: NearbyProtocol.version, name: displayName),
                                            ownKey: identity.publicKey, expectedKey: peer.publicKey)
        Log.nearby.info("Asking \(peer.name, privacy: .private) to remember this Mac")
        run(session, name: peer.name)
    }

    /// Codes Match.
    func confirmRememberCode() {
        guard case let .comparing(name, code, askedByThem, false) = rememberPhase,
              let session = rememberSession else { return }
        rememberPhase = .comparing(name: name, code: code, askedByThem: askedByThem, confirmedHere: true)
        session.confirm()
    }

    /// Cancel while asking or comparing: the other Mac is told, and the sheet goes back
    /// to the list for another `rememberWindow`.
    func cancelRemembering() {
        guard rememberSession != nil else { return }
        endRememberSession()
        Log.nearby.info("Cancelled remembering")
        lookForRememberRequests()
    }

    private func lookForRememberRequests() {
        rememberDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rememberPhase == .looking else { return }
                self.rememberPhase = .stoppedLooking
                self.apply()
            }
        }
        rememberDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rememberWindow, execute: deadline)
        rememberPhase = .looking
        apply()
    }

    private func endRememberSession() {
        let session = rememberSession
        rememberSession = nil
        session?.cancel()
    }

    /// A Mac asks to remember this one. Taken only while the sheet lists Macs, one at a
    /// time; otherwise it hears this Mac isn't ready.
    private func rememberRequested(by session: NearbyIncomingSession) {
        guard let identity, let key = session.peerKey, let name = session.senderName,
              key != identity.publicKey else {
            session.refuseRemembering()
            return
        }
        if case .connecting(_, false) = rememberPhase, let asking = rememberSession, asking.expectedKey == key {
            // Both people picked each other at once, so two connections cross. Both
            // Macs keep the one asked by the Mac with the lower key.
            guard key.lexicographicallyPrecedes(identity.publicKey) else {
                session.refuseRemembering()
                return
            }
            endRememberSession()
        } else if rememberPhase != .looking {
            session.refuseRemembering()
            Log.nearby.info("Turned a remember request away: not looking")
            return
        }
        incoming[session.id] = nil
        strangerSessions.remove(session.id)
        let connection = session.handOver()
        guard let remember = NearbyRememberSession(asked: connection, by: name, ownKey: identity.publicKey) else {
            connection.end(because: "no key or exporter to bind the code to")
            return
        }
        Log.nearby.info("Asked to remember \(name, privacy: .private)")
        run(remember, name: remembered.mac(for: key)?.name ?? name)
    }

    private func run(_ session: NearbyRememberSession, name: String) {
        rememberSession = session
        rememberPhase = .connecting(name: name, askedByThem: session.askedByThem)
        session.onCode = { [weak self, weak session] code in
            guard let self, let session, self.rememberSession === session else { return }
            self.rememberPhase = .comparing(name: name, code: code, askedByThem: session.askedByThem,
                                            confirmedHere: false)
        }
        session.onEnd = { [weak self, weak session] outcome in
            guard let self, let session, self.rememberSession === session else { return }
            self.rememberSession = nil
            switch outcome {
            case let .remembered(key, heardName):
                self.remembered.remember(key, name: heardName, at: Date())
                self.rememberedChanged()
                self.rememberPhase = .remembered(name: self.remembered.mac(for: key)?.name ?? heardName)
                Log.nearby.info("Remembered a Mac")
            case .cancelledHere:
                break
            case let .failed(reason):
                self.rememberPhase = .failed(name: name, reason)
                Log.nearby.info("Remembering didn't work: \(String(describing: reason), privacy: .public)")
            }
            self.apply()
        }
        apply()
        session.start()
    }

    /// A Mac gave this name. If its key is remembered, it's shown by the name from now
    /// on, unless another remembered Mac goes by it. The remembered Mac, or nil if the
    /// key isn't one.
    @discardableResult
    private func heard(_ name: String, from key: Data?) -> NearbyRememberedMac? {
        guard let mac = remembered.mac(for: key) else { return nil }
        if mac.name != name, remembered.rename(mac.publicKey, to: name) {
            rememberedChanged()
            Log.nearby.info("A remembered Mac has a new name")
        }
        return remembered.mac(for: key)
    }

    private func rememberedChanged(save: Bool = true) {
        if save, let rememberedFile {
            do {
                try remembered.save(to: rememberedFile)
            } catch {
                Log.nearby.error("Remembered Macs couldn't be saved: \(error.logCode, privacy: .public)")
            }
        }
        rememberedMacs = remembered.macs
        peers = peers.map { peer in
            var peer = peer
            peer.rememberedName = remembered.mac(for: peer.publicKey)?.name
            return peer
        }.sorted(by: Self.listOrder)
        // A Mac that hid from this one may not now that they remember each other, so
        // every Mac nearby that gave no name is asked again.
        asked = asked.filter { name in peers.contains { $0.id == name } }
        unanswered = [:]
        askNames()
    }

    /// Remembered Macs first, then by name.
    private static func listOrder(_ first: Peer, _ second: Peer) -> Bool {
        if first.isRemembered != second.isRemembered { return first.isRemembered }
        return first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    // MARK: - Browser

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NearbyProtocol.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                switch state {
                case let .waiting(error), let .failed(error): self.report(error, from: "Browser")
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                self.found(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        browsingSince = Date()
        Log.nearby.info("Looking for Macs nearby")
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        browsingSince = nil
        asked = []
        unanswered = [:]
        peers = []
        endpoints = [:]
        endExchanges { _ in true }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var present: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  name != serviceName else { continue }
            present[name] = result.endpoint
        }
        peers.removeAll { present[$0.id] == nil }
        endpoints = present
        asked.formIntersection(present.keys)
        askNames()
        Log.nearby.info("\(present.count, privacy: .public) Polka(s) nearby, \(self.peers.count, privacy: .public) named")
    }

    /// Asks each Polka found and not yet asked for its name, `maxOutgoing` at a time.
    /// Called again as each exchange ends, so with more Polkas around than that, the
    /// rest are asked in turn rather than only when the browse results next change.
    private func askNames() {
        guard browser != nil, let identity else { return }
        // A Mac that only shares with remembered Macs asks without telling its name.
        let hello = NearbyHello(version: NearbyProtocol.version, name: isVisibleToAll ? displayName : nil)
        for (name, endpoint) in endpoints.sorted(by: { $0.key < $1.key }) where !asked.contains(name) {
            guard exchanges.count < Self.maxOutgoing else { break }
            asked.insert(name)
            let connection = NWConnection(to: endpoint, using: Self.parameters(identity))
            run(NearbyHelloExchange(connection: connection, hello: hello, serviceName: name))
        }
    }

    // MARK: - Exchanges

    private func run(_ exchange: NearbyHelloExchange) {
        let id = ObjectIdentifier(exchange)
        exchanges[id] = exchange
        let name = exchange.serviceName
        exchange.onEnd = { [weak self] answered, closedByThem in
            guard let self else { return }
            self.exchanges[id] = nil
            if !answered && !closedByThem { self.askAgainLater(name) }
            self.askNames()
        }
        exchange.onAnswer = { [weak self, weak exchange] answer in
            guard let self, let exchange else { return }
            self.answered(answer, by: exchange.serviceName)
        }
        exchange.start()
    }

    private func answered(_ answer: NearbyHelloExchange.Answer, by serviceName: String) {
        // Gone from the list while it was being asked, or nameless.
        guard asked.contains(serviceName), let name = answer.hello.name else { return }
        let peer = Peer(id: serviceName, heardName: name, fingerprint: answer.fingerprint,
                        publicKey: answer.publicKey, isPeerToPeer: answer.isPeerToPeer,
                        version: answer.hello.version,
                        rememberedName: heard(name, from: answer.publicKey)?.name)
        peers.removeAll { $0.id == serviceName }
        peers.append(peer)
        peers.sort(by: Self.listOrder)
        Log.nearby.info("""
            Found \(name, privacy: .private), key \(answer.fingerprint ?? "none", privacy: .private), \
            \(answer.isPeerToPeer ? "peer-to-peer" : "shared network", privacy: .public)
            """)
    }

    /// A Polka that didn't answer is asked again a little later, a few times, each
    /// pause about twice the last: it may have turned the question away because many
    /// Macs asked at once, which happens when several shelves open together, or been
    /// too busy to answer in time. The pause is random so they don't all ask again at
    /// the same moment. One that closed the connection without a word isn't asked
    /// again: it receives only from remembered Macs.
    private func askAgainLater(_ name: String) {
        let attempts = (unanswered[name] ?? 0) + 1
        unanswered[name] = attempts
        guard attempts < Self.maxAsks else { return }
        let pause = min(Double.random(in: 0.3...1.2) * pow(2, Double(attempts - 1)), 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.endpoints[name] != nil else { return }
                self.asked.remove(name)
                self.askNames()
            }
        }
    }

    private func endExchanges(where shouldEnd: (NearbyHelloExchange) -> Bool) {
        let ending = exchanges.values.filter(shouldEnd)
        ending.forEach { $0.end(because: nil) }
    }

    // MARK: - Helpers

    private func report(_ error: NWError, from part: String) {
        if case let .dns(code) = error, code == Self.policyDenied {
            status = .noLocalNetwork
            Log.nearby.error("\(part, privacy: .public): Local Network access is off")
        } else {
            status = .failed("Polka couldn't reach Macs nearby (\(error.debugDescription)).")
            Log.nearby.error("\(part, privacy: .public): \(error.debugDescription, privacy: .public)")
        }
    }

    /// Mutual TLS 1.3 with this Mac's identity, over any interface including
    /// peer-to-peer Wi-Fi. Not private: the tests' hostile peer starts from it.
    static func parameters(_ identity: NearbyIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, NearbyProtocol.applicationProtocol)
        // The listener asks for the caller's certificate too, so both sides know the
        // other's key.
        sec_protocol_options_set_peer_authentication_required(options, true)
        if let secIdentity = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        // Self-signed, so no authority vouches for the other side's certificate. Any
        // key is let through here, since all N1 learns is a name marked "Not verified";
        // remembering (N4) checks the key against the one it pinned.
        // Off the main thread: it only says yes, and shouldn't wait behind other work.
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) },
                                              DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(NearbyConnection.handshakeTimeout)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Random, so the advertisement says nothing about the Mac or who uses it.
    private static func randomServiceName() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

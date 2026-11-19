import Foundation
import Network
import Security
import SystemConfiguration

/// Nearby Sharing (N1: NS-1 to NS-3, N2: links and text). While the Settings switch is
/// on, Polka advertises `_polka._tcp` under a random name and listens for TLS
/// connections. It browses for other Polkas only while something needs the list (the
/// Settings window, the open shelf), since browsing keeps the Wi-Fi radio hopping to
/// the peer-to-peer channel, which costs battery. Each Polka found is asked its name in
/// a short `hello` exchange.
///
/// Offers that arrive wait in `offers` for the panel to show them, in the order and at
/// the pace `NearbyOfferLine` allows; `send` makes an offer to a Mac found nearby.
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
        let name: String
        let fingerprint: String?
        let isPeerToPeer: Bool
        /// Its protocol version: below `NearbyProtocol.offerVersion`, it can't be sent to.
        var version = NearbyProtocol.version

        var takesOffers: Bool { version >= NearbyProtocol.offerVersion }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var peers: [Peer] = []
    /// When the current look for Macs nearby began, or nil while not looking. Send To
    /// says "Looking for Macs…" at first, and "No Macs Nearby" once it's had a while.
    @Published private(set) var browsingSince: Date?
    /// Offers waiting for an answer, in the order they arrived.
    @Published private(set) var offers: [NearbyIncomingOffer] = []

    /// What an accepted offer brought, once it has all arrived and checked out, with
    /// the name the sender gave.
    var onReceived: ((_ items: [NearbyReceivedItem], _ senderName: String) -> Void)?
    /// An accepted offer that never fully arrived, with the name the sender gave.
    var onReceiveFailed: ((_ senderName: String) -> Void)?

    /// The Mac's name, as in System Settings > General > Sharing, which is what AirDrop
    /// shows too.
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap(NearbyName.clean) ?? "Mac"
    }

    /// The Settings switch.
    var isEnabled: Bool { settings.nearbySharingEnabled }

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
    /// What the listener was started with, so a change restarts it.
    private var advertised: (name: String, receiveFrom: NearbyReceiveFrom)?
    private var browser: NWBrowser?
    private var browseRequests = 0
    private var exchanges: [ObjectIdentifier: NearbyHelloExchange] = [:]
    private var incoming: [UUID: NearbyIncomingSession] = [:]
    private var outgoing: [ObjectIdentifier: NearbyOutgoingSession] = [:]
    /// Accepted offers still arriving.
    private var accepted: Set<UUID> = []
    private var line = NearbyOfferLine()
    /// Where each Mac found nearby can be reached, by its Bonjour name.
    private var endpoints: [String: NWEndpoint] = [:]
    private let answerTimeout: TimeInterval
    /// Lists this Mac among the Macs nearby, so one Mac can send to itself. Only in
    /// the test build (`listsThisMacForTesting`) and in tests.
    private let listsThisMac: Bool
    /// Bonjour names asked for their name since browsing started.
    private var asked: Set<String> = []
    /// How many times each Bonjour name was asked without an answer.
    private var unanswered: [String: Int] = [:]
    private var serviceName = NearbyService.randomServiceName()
    private var defaultsObserver: NSObjectProtocol?

    private static let maxIncoming = 4
    private static let maxOutgoing = 8
    /// How many times a Polka is asked its name before it's left alone.
    private static let maxAsks = 6
    /// What Bonjour reports when Local Network access is turned down
    /// (`kDNSServiceErr_PolicyDenied`).
    private static let policyDenied: Int32 = -65570

    init(settings: ShelfSettings = ShelfSettings(), identityTag: String = NearbyIdentity.standardTag,
         answerTimeout: TimeInterval = NearbyOfferLine.answerTimeout,
         listsThisMac: Bool = NearbyService.listsThisMacForTesting) {
        self.settings = settings
        self.identityTag = identityTag
        self.answerTimeout = answerTimeout
        self.listsThisMac = listsThisMac
    }

    /// The test build's `-NearbyListThisMac YES` launch argument. Ignored by every other
    /// build, the daily Polka included. Remove before merging, with the test build.
    nonisolated static var listsThisMacForTesting: Bool {
        Bundle.main.bundleIdentifier == "com.maksimds.Polka.NearbyTest"
            && UserDefaults.standard.bool(forKey: "NearbyListThisMac")
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
        let wanted = (name: displayName, receiveFrom: settings.nearbyReceiveFrom)
        if listener == nil || advertised?.name != wanted.name || advertised?.receiveFrom != wanted.receiveFrom {
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

    private func startListener(_ identity: NearbyIdentity, as wanted: (name: String, receiveFrom: NearbyReceiveFrom)) {
        listener?.cancel()
        // A new Bonjour name with every change, so Macs browsing see a new service and
        // ask again, and learn the new name.
        serviceName = Self.randomServiceName()
        // Connections already made stay up through a change of name. Not through
        // turning to Remembered Macs Only, which shuts everyone else out at once.
        if advertised?.receiveFrom != wanted.receiveFrom { endIncoming() }
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
            Log.nearby.info("Advertising as \(self.serviceName, privacy: .public), receiving from \(wanted.receiveFrom.rawValue, privacy: .public)")
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
            connection.cancel()
            Log.nearby.info("Turned a connection away: too many at once")
            return
        }
        // Only receiving from remembered Macs: nobody can be remembered yet (N4), so
        // every caller is closed on without hearing this Mac's name.
        let hello = advertised?.receiveFrom == .everyone
            ? NearbyHello(version: NearbyProtocol.version, name: advertised?.name)
            : nil
        let session = NearbyIncomingSession(connection: connection, hello: hello)
        incoming[session.id] = session
        session.onOffer = { [weak self] in self?.offered($0) }
        session.onReceived = { [weak self, weak session] items in
            guard let self, let session else { return }
            self.received(items, by: session)
        }
        session.onEnd = { [weak self] in self?.incomingEnded($0) }
        session.start()
    }

    private func endIncoming() {
        incoming.values.forEach { $0.end(because: nil) }
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

    /// Accept: the offer leaves the line, and its items arrive through `onReceived`.
    func accept(_ id: UUID) {
        guard offers.contains(where: { $0.id == id }), let session = incoming[id] else { return }
        removeOffer(id)
        accepted.insert(id)
        session.answer(accept: true)
        Log.nearby.info("Accepted an offer")
    }

    /// Decline, or Decline and Block, which turns away that Mac's offers until Polka quits.
    func decline(_ id: UUID, block: Bool = false) {
        guard let offer = offers.first(where: { $0.id == id }) else { return }
        if block { line.block(offer.fingerprint) }
        removeOffer(id)
        incoming[id]?.answer(accept: false)
        Log.nearby.info("Declined an offer\(block ? " and blocked its Mac" : "", privacy: .public)")
    }

    private func offered(_ session: NearbyIncomingSession) {
        guard let fingerprint = session.fingerprint, let name = session.senderName,
              let offer = session.offer else {
            session.end(because: "offer without a sender")
            return
        }
        let admission = line.admit(id: session.id, fingerprint: fingerprint)
        guard admission == .admitted else {
            session.answer(accept: false)
            Log.nearby.info("Turned an offer away: \(String(describing: admission), privacy: .public)")
            return
        }
        offers.append(NearbyIncomingOffer(id: session.id, senderName: name, fingerprint: fingerprint, offer: offer))
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
        accepted.remove(session.id)
        Log.nearby.info("Received \(items.count, privacy: .public) item(s)")
        onReceived?(items, session.senderName ?? "")
    }

    private func incomingEnded(_ session: NearbyIncomingSession) {
        incoming[session.id] = nil
        // Withdrawn: the other Mac went away before an answer.
        if offers.contains(where: { $0.id == session.id }) {
            removeOffer(session.id)
            Log.nearby.info("An offer was withdrawn")
        }
        if accepted.remove(session.id) != nil {
            Log.nearby.error("An accepted offer didn't fully arrive")
            onReceiveFailed?(session.senderName ?? "")
        }
    }

    private func removeOffer(_ id: UUID) {
        line.remove(id)
        offers.removeAll { $0.id == id }
    }

    // MARK: - Offers from this Mac

    /// Offers these tiles to a Mac found nearby, leaving out any that can't be sent.
    /// False if nothing could be sent or the Mac is no longer there; otherwise
    /// `onStatus` follows the transfer to its end.
    @discardableResult
    func send(_ items: [ShelfItem], to peerID: String,
              onStatus: @escaping (NearbyOutgoingSession.Status) -> Void) -> Bool {
        guard let identity, let peer = peers.first(where: { $0.id == peerID }), peer.takesOffers,
              let endpoint = endpoints[peerID],
              let transfer = NearbyOutgoingTransfer(items: items) else { return false }
        // A Mac that wants to share says who it is, even while it keeps its name from
        // everyone else (Remembered Macs Only): it chose to show it to this one.
        let hello = NearbyHello(version: NearbyProtocol.version, name: displayName)
        let session = NearbyOutgoingSession(connection: NWConnection(to: endpoint, using: Self.parameters(identity)),
                                            hello: hello, transfer: transfer,
                                            expectedFingerprint: peer.fingerprint)
        let key = ObjectIdentifier(session)
        outgoing[key] = session
        session.onStatus = { [weak self] status in
            if status.isFinished { self?.outgoing[key] = nil }
            Log.nearby.info("Sending: \(String(describing: status), privacy: .public)")
            onStatus(status)
        }
        onStatus(.connecting)
        session.start()
        Log.nearby.info("Offering \(transfer.offer.items.count, privacy: .public) item(s) to \(peer.name, privacy: .private)")
        return true
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
                  name != serviceName || listsThisMac else { continue }
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
        let hello = NearbyHello(version: NearbyProtocol.version,
                                name: settings.nearbyReceiveFrom == .everyone ? displayName : nil)
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
        let peer = Peer(id: serviceName, name: name, fingerprint: answer.fingerprint,
                        isPeerToPeer: answer.isPeerToPeer, version: answer.hello.version)
        peers.removeAll { $0.id == serviceName }
        peers.append(peer)
        peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    /// peer-to-peer Wi-Fi.
    private static func parameters(_ identity: NearbyIdentity) -> NWParameters {
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

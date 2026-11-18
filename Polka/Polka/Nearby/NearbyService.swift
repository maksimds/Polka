import Foundation
import Network
import Security
import SystemConfiguration

/// Nearby Sharing's discovery (N1: NS-1 to NS-3). While the Settings switch is on,
/// Polka advertises `_polka._tcp` under a random name and listens for TLS
/// connections. It browses for other Polkas only while something needs the list (in
/// N1, the Settings window), since browsing keeps the Wi-Fi radio hopping to the
/// peer-to-peer channel, which costs battery. Each Polka found is asked its name in a
/// short `hello` exchange.
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
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var peers: [Peer] = []

    /// The Mac's name, as in System Settings > General > Sharing, which is what AirDrop
    /// shows too.
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap(NearbyName.clean) ?? "Mac"
    }

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
    /// Bonjour names asked for their name since browsing started.
    private var asked: Set<String> = []
    private var serviceName = NearbyService.randomServiceName()
    private var defaultsObserver: NSObjectProtocol?

    private static let maxIncoming = 4
    private static let maxOutgoing = 8
    /// What Bonjour reports when Local Network access is turned down
    /// (`kDNSServiceErr_PolicyDenied`).
    private static let policyDenied: Int32 = -65570

    init(settings: ShelfSettings = ShelfSettings(), identityTag: String = NearbyIdentity.standardTag) {
        self.settings = settings
        self.identityTag = identityTag
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
        advertised = wanted
        endExchanges { $0.isIncoming }
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
        guard exchanges.values.filter(\.isIncoming).count < Self.maxIncoming else {
            connection.cancel()
            Log.nearby.info("Turned a connection away: too many at once")
            return
        }
        // Only receiving from remembered Macs: nobody can be remembered yet (N4), so
        // every caller is closed on without hearing this Mac's name.
        let hello = advertised?.receiveFrom == .everyone
            ? NearbyHello(version: NearbyProtocol.version, name: advertised?.name)
            : nil
        run(NearbyHelloExchange(connection: connection, isIncoming: true, hello: hello, serviceName: nil))
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
        Log.nearby.info("Looking for Macs nearby")
    }

    private func stopBrowser() {
        browser?.cancel()
        browser = nil
        asked = []
        peers = []
        endExchanges { !$0.isIncoming }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var present: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != serviceName else { continue }
            present[name] = result.endpoint
        }
        peers.removeAll { present[$0.id] == nil }
        asked.formIntersection(present.keys)
        guard let identity else { return }
        // A Mac that only shares with remembered Macs asks without telling its name.
        let hello = NearbyHello(version: NearbyProtocol.version,
                                name: settings.nearbyReceiveFrom == .everyone ? displayName : nil)
        for (name, endpoint) in present.sorted(by: { $0.key < $1.key }) where !asked.contains(name) {
            guard exchanges.values.filter({ !$0.isIncoming }).count < Self.maxOutgoing else { break }
            asked.insert(name)
            let connection = NWConnection(to: endpoint, using: Self.parameters(identity))
            run(NearbyHelloExchange(connection: connection, isIncoming: false, hello: hello, serviceName: name))
        }
        Log.nearby.info("\(present.count, privacy: .public) Polka(s) nearby, \(self.peers.count, privacy: .public) named")
    }

    // MARK: - Exchanges

    private func run(_ exchange: NearbyHelloExchange) {
        let id = ObjectIdentifier(exchange)
        exchanges[id] = exchange
        exchange.onEnd = { [weak self] in self?.exchanges[id] = nil }
        exchange.onAnswer = { [weak self, weak exchange] answer in
            guard let self, let exchange, !exchange.isIncoming else { return }
            self.answered(answer, by: exchange.serviceName)
        }
        exchange.start()
    }

    private func answered(_ answer: NearbyHelloExchange.Answer, by serviceName: String?) {
        // Gone from the list while it was being asked, or nameless.
        guard let serviceName, asked.contains(serviceName), let name = answer.hello.name else { return }
        let peer = Peer(id: serviceName, name: name, fingerprint: answer.fingerprint,
                        isPeerToPeer: answer.isPeerToPeer)
        peers.removeAll { $0.id == serviceName }
        peers.append(peer)
        peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Log.nearby.info("""
            Found \(name, privacy: .private), key \(answer.fingerprint ?? "none", privacy: .private), \
            \(answer.isPeerToPeer ? "peer-to-peer" : "shared network", privacy: .public)
            """)
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
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(NearbyHelloExchange.timeout)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Random, so the advertisement says nothing about the Mac or who uses it.
    private static func randomServiceName() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

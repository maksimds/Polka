import Foundation
import Network

/// One remembering between two Macs (NS-11), over its own TLS connection, for either
/// Mac: the one whose person picked the other ("asking"), or the one asked, which gets
/// the connection handed over from a `NearbyIncomingSession`. The steps and checks are
/// `NearbyRememberExchange`'s; this ties them to the connection and reports the code
/// and the end.
@MainActor
final class NearbyRememberSession {
    enum Outcome: Equatable {
        /// Both people confirmed the code: remember this key, under this name.
        case remembered(key: Data, name: String)
        /// The person here cancelled.
        case cancelledHere
        case failed(NearbyRememberFailure)
    }

    let askedByThem: Bool
    /// The key the Mac being asked had when it was found, checked against the one that
    /// answers. Nil for the asked side.
    let expectedKey: Data?
    /// The code to compare, once both numbers are in.
    var onCode: ((String) -> Void)?
    /// Once, at the end.
    var onEnd: ((Outcome) -> Void)?

    private let connection: NearbyConnection
    private let hello: NearbyHello?
    private let ownKey: Data
    private var exchange: NearbyRememberExchange
    /// What the asked side sends first: its commitment.
    private var firstMessage: NearbyMessage?
    private var theirKey: Data?
    private var hasEnded = false

    /// Long enough for two people to read their codes out and press a button.
    static let comparingTimeout: TimeInterval = 120

    /// Asks the Mac at the other end of `connection` to remember this one.
    init(asking connection: NWConnection, hello: NearbyHello, ownKey: Data, expectedKey: Data?) {
        self.connection = NearbyConnection(connection, isIncoming: false)
        self.hello = hello
        self.ownKey = ownKey
        self.expectedKey = expectedKey
        askedByThem = false
        exchange = .asking()
    }

    /// Takes a connection whose hellos and request are in. Nil if the TLS session gives
    /// nothing to bind the code to.
    init?(asked connection: NearbyConnection, by name: String, ownKey: Data) {
        guard let binding = Self.binding(of: connection, ownKey: ownKey) else { return nil }
        self.connection = connection
        hello = nil
        self.ownKey = ownKey
        expectedKey = nil
        askedByThem = true
        theirKey = binding.theirKey
        let (exchange, first) = NearbyRememberExchange.asked(by: name, binding: binding)
        self.exchange = exchange
        firstMessage = first
    }

    func start() {
        connection.onMessage = { [weak self] message in
            try self?.read(message)
        }
        connection.onPiece = nil
        connection.onEnd = { [weak self] _ in
            guard let self else { return }
            self.finish(.failed(self.connection.timedOut ? .timedOut : .unreachable))
        }
        if let firstMessage {
            connection.setTimeout(Self.comparingTimeout)
            connection.send([firstMessage])
        } else {
            connection.onReady = { [weak self] in self?.ready() }
            connection.start()
        }
    }

    /// The person here pressed Codes Match.
    func confirm() {
        guard !hasEnded, let step = exchange.confirm() else { return }
        if step.event == .remembered {
            remembered()
            // The connection, not this session, is kept until the last word has gone:
            // the service lets go of the session as soon as it's remembered.
            connection.send(step.send) { [connection] in connection.end(because: nil) }
        } else {
            connection.send(step.send)
        }
    }

    /// The person here pressed Cancel, or closed the sheet. Tells the other Mac, if
    /// there's anything to tell.
    func cancel() {
        guard !hasEnded else { return }
        finish(.cancelledHere)
        if let message = exchange.cancel() {
            connection.send([message]) { [connection] in connection.end(because: "cancelled here") }
            connection.setTimeout(2)
        } else {
            connection.end(because: "cancelled here")
        }
    }

    // MARK: - Private

    private func ready() {
        guard let binding = Self.binding(of: connection, ownKey: ownKey) else {
            fail(.notVerified, because: "no key or exporter to bind the code to")
            return
        }
        if let expectedKey, binding.theirKey != expectedKey {
            fail(.notVerified, because: "another key answered")
            return
        }
        theirKey = binding.theirKey
        exchange.connected(binding)
        connection.setTimeout(Self.comparingTimeout)
        if let hello { connection.send([.hello(hello)]) }
    }

    private func read(_ message: NearbyMessage) throws {
        let step: (event: NearbyRememberExchange.Event, send: [NearbyMessage])
        do {
            step = try exchange.read(message)
        } catch let failure as NearbyRememberExchange.Failure {
            finish(.failed(Self.reason(for: failure)))
            throw failure
        }
        if !step.send.isEmpty { connection.send(step.send) }
        switch step.event {
        case .nothing:
            break
        case let .code(code):
            onCode?(code)
        case .remembered:
            remembered()
            connection.end(because: nil)
        }
    }

    private func remembered() {
        guard let theirKey, let name = exchange.theirName else {
            finish(.failed(.notVerified))
            return
        }
        finish(.remembered(key: theirKey, name: name))
    }

    private func fail(_ reason: NearbyRememberFailure, because why: String) {
        finish(.failed(reason))
        connection.end(because: why)
    }

    private func finish(_ outcome: Outcome) {
        guard !hasEnded else { return }
        hasEnded = true
        onEnd?(outcome)
        onEnd = nil
        onCode = nil
    }

    private static func reason(for failure: NearbyRememberExchange.Failure) -> NearbyRememberFailure {
        switch failure {
        case .tooOld: return .tooOld
        case .notReady: return .notReady
        case .cancelled: return .cancelledByThem
        case .outOfTurn, .nameless, .brokenPromise, .unbound: return .notVerified
        }
    }

    /// The session's exporter and both keys, if the handshake gave a P-256 key.
    private static func binding(of connection: NearbyConnection, ownKey: Data) -> NearbyRememberExchange.Binding? {
        guard let theirKey = connection.peerPublicKey, NearbyRememberedMac.isValidKey(theirKey),
              let exporter = connection.exportedSecret(label: NearbyRememberCode.exporterLabel,
                                                       count: NearbyRememberCode.exporterBytes),
              exporter.count == NearbyRememberCode.exporterBytes else { return nil }
        return NearbyRememberExchange.Binding(exporter: exporter, ownKey: ownKey, theirKey: theirKey)
    }
}

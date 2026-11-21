import Foundation
import Network
import Security
import Testing
@testable import Polka

/// A Mac that breaks every rule (N6): it connects to a real Nearby Sharing service
/// over loopback, the way a modified Polka nearby could, and sends whatever bytes it
/// likes in whatever order. It has a throwaway Keychain key of its own, made per test.
@MainActor
final class NearbyHostilePeer {
    enum Transport: Equatable {
        /// As a real Polka connects: mutual TLS 1.3 with Polka's protocol name.
        case polka
        /// No encryption at all.
        case plainTCP
        /// TLS 1.3, but without a certificate of its own.
        case noCertificate
        /// TLS 1.2 at most.
        case tls12
        /// TLS 1.3 with a certificate, naming another application protocol.
        case otherProtocol
    }

    let tag = "com.maksimds.Polka.tests.hostile.\(UUID().uuidString)"
    private(set) var identity: NearbyIdentity?
    private var connection: NWConnection?
    private var reader = NearbyFrameReader()
    /// The messages the service sent back, in order.
    private(set) var messages: [NearbyMessage] = []
    /// The TLS handshake finished on this side.
    private(set) var isReady = false
    /// The connection ended, however.
    private(set) var isClosed = false

    init(withKey: Bool = true) throws {
        if withKey { identity = try NearbyIdentity.loadOrCreate(tag: tag) }
    }

    var publicKey: Data? { identity?.publicKey }

    /// The service's own hello, if it sent one.
    var hello: NearbyHello? {
        for message in messages {
            if case let .hello(hello) = message { return hello }
        }
        return nil
    }

    /// Connects as a Polka until the service says hello, trying again a few times, a
    /// little later each time, when it's turned away, as a real Polka does: while the
    /// whole test suite runs, other tests' services keep asking every service its name,
    /// and those calls fill the four connections strangers share. False if it never got in.
    func connectUntilGreeted(to port: NWEndpoint.Port) async throws -> Bool {
        for attempt in 0..<6 {
            connect(to: port)
            if try await nearbyEventually(10, { self.hello != nil || self.isClosed }), hello != nil { return true }
            try await Task.sleep(for: .milliseconds(200 * (1 << attempt)))
        }
        return false
    }

    func connect(to port: NWEndpoint.Port, as transport: Transport = .polka) {
        connection?.cancel()
        reader = NearbyFrameReader()
        messages = []
        isReady = false
        isClosed = false
        let connection = NWConnection(host: "127.0.0.1", port: port,
                                      using: Self.parameters(transport, identity: identity))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.receive()
                case .waiting:
                    // Refused, or not reachable: given up on, rather than tried again.
                    self.isClosed = true
                    connection.cancel()
                case .failed, .cancelled:
                    self.isClosed = true
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func send(_ messages: NearbyMessage...) {
        for message in messages {
            // Every message a test sends is one Polka can write.
            send(try! message.frame())
        }
    }

    func sendPiece(_ bytes: Data) {
        send(NearbyFrame.pieceFrame(bytes))
    }

    func close() {
        connection?.cancel()
    }

    func cleanUp() {
        connection?.cancel()
        NearbyIdentity.delete(tag: tag)
    }

    // MARK: - Private

    private func receive() {
        let connection = self.connection
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                // An earlier connection's last words.
                guard let self, connection === self.connection else { return }
                if let data, !data.isEmpty, let frames = try? self.reader.append(data) {
                    for frame in frames {
                        if let payload = frame.message, let message = try? NearbyMessage.decode(payload) {
                            self.messages.append(message)
                        }
                    }
                }
                if error != nil || isComplete {
                    self.isClosed = true
                } else {
                    self.receive()
                }
            }
        }
    }

    private static func parameters(_ transport: Transport, identity: NearbyIdentity?) -> NWParameters {
        if transport == .polka, let identity { return NearbyService.parameters(identity) }
        if transport == .plainTCP { return .tcp }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let version: tls_protocol_version_t = transport == .tls12 ? .TLSv12 : .TLSv13
        sec_protocol_options_set_min_tls_protocol_version(options, version)
        sec_protocol_options_set_max_tls_protocol_version(options, version)
        sec_protocol_options_add_tls_application_protocol(
            options, transport == .otherProtocol ? "http/1.1" : NearbyProtocol.applicationProtocol)
        if transport != .noCertificate, let identity, let secIdentity = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) },
                                              DispatchQueue.global(qos: .userInitiated))
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

/// A service listening, for a hostile peer to reach directly by its port.
@MainActor
func nearbyListeningSide(named name: String = "Target \(Int.random(in: 1000...9999))",
                         receiveFrom: NearbyReceiveFrom = .everyone) async throws -> (NearbyTestSide, NWEndpoint.Port) {
    let side = try NearbyTestSide()
    side.settings.nearbyName = name
    side.settings.nearbyReceiveFrom = receiveFrom
    side.settings.nearbySharingEnabled = true
    side.service.start()
    let listening = try await nearbyEventually(20) {
        side.service.status == .on && side.service.listeningPort != nil
    }
    try #require(listening)
    return (side, try #require(side.service.listeningPort))
}

import Foundation
import Network

/// One short connection that swaps `hello` messages with another Polka and closes.
/// Browsing makes one to each Polka it finds, to learn its name; the listener answers
/// each one that arrives. Names only ever cross inside TLS, never in the public Bonjour
/// advertisement.
@MainActor
final class NearbyHelloExchange {
    /// What the other side said, from an exchange this Mac started.
    struct Answer {
        let hello: NearbyHello
        /// Their key's fingerprint, from the TLS session.
        let fingerprint: String?
        /// Over peer-to-peer Wi-Fi (AWDL) rather than a shared network.
        let isPeerToPeer: Bool
    }

    let isIncoming: Bool
    /// The other Polka's Bonjour name, for one this Mac started.
    let serviceName: String?
    var onAnswer: ((Answer) -> Void)?
    var onEnd: (() -> Void)?

    private let connection: NWConnection
    /// What this side sends, or nil to close without a word: a listener that only
    /// receives from remembered Macs (none can be remembered before N4).
    private let hello: NearbyHello?
    private var reader = NearbyFrameReader()
    private var hasSent = false
    private var hasReceived = false
    private var hasEnded = false

    /// Long enough for a slow handshake over the air, short enough that a connection
    /// that never speaks can't hold a place.
    static let timeout: TimeInterval = 10

    init(connection: NWConnection, isIncoming: Bool, hello: NearbyHello?, serviceName: String?) {
        self.connection = connection
        self.isIncoming = isIncoming
        self.hello = hello
        self.serviceName = serviceName
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated { self?.end(because: "it timed out") }
        }
    }

    /// Closes the connection, once. A graceful close: what was sent still arrives.
    func end(because reason: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        if let reason {
            Log.nearby.info("Hello \(self.isIncoming ? "in" : "out", privacy: .public) ended: \(reason, privacy: .public)")
        }
        connection.cancel()
        onEnd?()
    }

    // MARK: - Private

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let hello else {
                end(because: "this Mac doesn't share its name")
                return
            }
            send(hello)
            receive()
        case let .waiting(error), let .failed(error):
            end(because: "\(error.debugDescription)")
        case .cancelled:
            end(because: nil)
        default:
            break
        }
    }

    private func send(_ hello: NearbyHello) {
        let frame: Data
        do {
            frame = try NearbyMessage.hello(hello).frame()
        } catch {
            end(because: "hello couldn't be written")
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil {
                    self.end(because: "sending failed")
                } else {
                    self.hasSent = true
                    self.finishIfDone()
                }
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                if let data, !data.isEmpty {
                    do {
                        for payload in try self.reader.append(data) {
                            try self.read(payload)
                        }
                    } catch {
                        self.end(because: "refused what arrived: \(error)")
                        return
                    }
                }
                if self.hasReceived {
                    self.finishIfDone()
                } else if error != nil || isComplete {
                    self.end(because: "closed before saying hello")
                } else {
                    self.receive()
                }
            }
        }
    }

    private func read(_ payload: Data) throws {
        switch try NearbyMessage.decode(payload) {
        case let .hello(hello):
            // One hello per connection; a second is a peer misbehaving.
            guard !hasReceived else { throw NearbyMessage.Failure.unreadable }
            hasReceived = true
            onAnswer?(Answer(hello: hello, fingerprint: peerFingerprint(), isPeerToPeer: isPeerToPeer))
        }
    }

    private func finishIfDone() {
        if hasSent && hasReceived { end(because: nil) }
    }

    private func peerFingerprint() -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var key: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard key == nil else { return }
            key = NearbyIdentity.publicKey(of: sec_certificate_copy_ref(certificate).takeRetainedValue())
        }
        return key.map(NearbyIdentity.fingerprint(of:))
    }

    /// AWDL's interfaces are `awdl0` and its low-latency twin `llw0`.
    private var isPeerToPeer: Bool {
        connection.currentPath?.availableInterfaces.contains {
            $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw")
        } ?? false
    }
}

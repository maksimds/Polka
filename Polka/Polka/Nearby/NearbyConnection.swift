import Foundation
import Network

/// One TLS connection to another Polka, as whole messages: it frames what's sent, cuts
/// what arrives into messages (`NearbyFrameReader`), keeps a deadline, and ends once.
/// What the messages mean is up to whoever owns it.
@MainActor
final class NearbyConnection {
    let isIncoming: Bool
    /// The connection is up and the TLS handshake is done.
    var onReady: (() -> Void)?
    /// A message arrived. Throwing refuses it, which ends the connection.
    var onMessage: ((NearbyMessage) throws -> Void)?
    /// A piece of a file arrived. Throwing refuses it, as for a message. With no
    /// handler, any piece is refused.
    var onPiece: ((Data) throws -> Void)?
    /// It ended, with why if it went wrong. Nil when the other side closed, or this
    /// side ended it without a reason.
    var onEnd: ((String?) -> Void)?

    private let connection: NWConnection
    private var reader = NearbyFrameReader()
    private var hasEnded = false
    private var deadline: DispatchWorkItem?
    /// It ended because nothing came in time.
    private(set) var timedOut = false

    /// Long enough for a slow handshake over the air, short enough that a connection
    /// that never speaks can't hold a place.
    static let handshakeTimeout: TimeInterval = 10

    init(_ connection: NWConnection, isIncoming: Bool) {
        self.connection = connection
        self.isIncoming = isIncoming
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
        setTimeout(Self.handshakeTimeout)
    }

    /// Ends the connection `seconds` from now unless it's set again before then.
    func setTimeout(_ seconds: TimeInterval) {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                self.timedOut = true
                self.end(because: "it timed out")
            }
        }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Sends the messages in order, then calls `completion` once they've gone. A
    /// message that can't be written, or a send that fails, ends the connection.
    func send(_ messages: [NearbyMessage], completion: (() -> Void)? = nil) {
        guard !hasEnded else { return }
        var data = Data()
        do {
            for message in messages {
                let frame = try message.frame()
                guard frame.count - 4 <= NearbyProtocol.maxMessageBytes else {
                    end(because: "a message was too large to send")
                    return
                }
                data.append(frame)
            }
        } catch {
            end(because: "a message couldn't be written")
            return
        }
        write(data, completion: completion)
    }

    /// Sends one piece of a file, after whatever was sent before it.
    func sendPiece(_ bytes: Data, completion: (() -> Void)? = nil) {
        guard !hasEnded else { return }
        guard !bytes.isEmpty, bytes.count <= NearbyProtocol.maxPieceBytes else {
            end(because: "a piece was too large to send")
            return
        }
        write(NearbyFrame.pieceFrame(bytes), completion: completion)
    }

    private func write(_ data: Data, completion: (() -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                if error != nil {
                    self.end(because: "sending failed")
                } else {
                    completion?()
                }
            }
        })
    }

    /// Closes the connection, once. A graceful close: what was sent still arrives.
    func end(because reason: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        deadline?.cancel()
        deadline = nil
        if let reason {
            Log.nearby.info("Connection \(self.isIncoming ? "in" : "out", privacy: .public) ended: \(reason, privacy: .public)")
        }
        connection.cancel()
        onEnd?(reason)
        onEnd = nil
        onMessage = nil
        onPiece = nil
        onReady = nil
    }

    /// The other side's public key, from its certificate in the TLS session.
    var peerPublicKey: Data? {
        guard let metadata = tlsMetadata else { return nil }
        var key: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard key == nil else { return }
            key = NearbyIdentity.publicKey(of: sec_certificate_copy_ref(certificate).takeRetainedValue())
        }
        return key
    }

    /// The other side's key fingerprint, from the TLS session.
    var peerFingerprint: String? {
        peerPublicKey.map(NearbyIdentity.fingerprint(of:))
    }

    /// A secret only the two ends of this TLS session can work out (TLS 1.3's exporter),
    /// the same on both, different on every session.
    func exportedSecret(label: String, count: Int) -> Data? {
        guard let metadata = tlsMetadata else { return nil }
        let secret = label.withCString {
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, count)
        }
        return secret.map { Data($0 as DispatchData) }
    }

    private var tlsMetadata: NWProtocolTLS.Metadata? {
        connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
    }

    /// Over peer-to-peer Wi-Fi (AWDL) rather than a shared network. AWDL's interfaces
    /// are `awdl0` and its low-latency twin `llw0`.
    var isPeerToPeer: Bool {
        connection.currentPath?.availableInterfaces.contains {
            $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw")
        } ?? false
    }

    // MARK: - Private

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
            receive()
        case let .waiting(error), let .failed(error):
            end(because: error.debugDescription)
        case .cancelled:
            end(because: nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.reader.append(data) {
                            switch frame {
                            case let .message(payload):
                                try self.onMessage?(try NearbyMessage.decode(payload))
                            case let .piece(bytes):
                                guard let onPiece = self.onPiece else { throw NearbyMessage.Failure.unreadable }
                                try onPiece(bytes)
                            }
                            // The message may have ended the connection.
                            guard !self.hasEnded else { return }
                        }
                    } catch {
                        self.end(because: "refused what arrived: \(error)")
                        return
                    }
                }
                if let error {
                    self.end(because: error.debugDescription)
                } else if isComplete {
                    self.end(because: nil)
                } else {
                    self.receive()
                }
            }
        }
    }
}

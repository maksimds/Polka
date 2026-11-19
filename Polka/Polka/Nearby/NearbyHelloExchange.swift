import Foundation
import Network

/// One short connection that asks another Polka its name and closes. Browsing makes
/// one to each Polka it finds; the other side answers in its `NearbyIncomingSession`.
/// Names only ever cross inside TLS, never in the public Bonjour advertisement.
@MainActor
final class NearbyHelloExchange {
    /// What the other side said.
    struct Answer {
        let hello: NearbyHello
        /// Their key's fingerprint, from the TLS session.
        let fingerprint: String?
        /// Over peer-to-peer Wi-Fi (AWDL) rather than a shared network.
        let isPeerToPeer: Bool
    }

    /// The other Polka's Bonjour name.
    let serviceName: String
    var onAnswer: ((Answer) -> Void)?
    /// It ended, saying whether the other side answered, and whether it closed the
    /// connection itself without a word, which a Mac receiving only from remembered
    /// Macs does. Anything else unanswered (turned away because many Macs asked at
    /// once, or too slow to answer in time) is worth asking again.
    var onEnd: ((_ answered: Bool, _ closedByThem: Bool) -> Void)?

    private let connection: NearbyConnection
    private let hello: NearbyHello
    private var hasSent = false
    private var hasReceived = false

    init(connection: NWConnection, hello: NearbyHello, serviceName: String) {
        self.connection = NearbyConnection(connection, isIncoming: false)
        self.hello = hello
        self.serviceName = serviceName
    }

    func start() {
        connection.onReady = { [weak self] in
            guard let self else { return }
            self.connection.send([.hello(self.hello)]) { [weak self] in
                self?.hasSent = true
                self?.finishIfDone()
            }
        }
        connection.onMessage = { [weak self] message in
            guard let self else { return }
            // One hello, and nothing else, from a Mac this side only asked its name.
            guard case let .hello(hello) = message, !self.hasReceived else {
                throw NearbyMessage.Failure.unreadable
            }
            self.hasReceived = true
            self.onAnswer?(Answer(hello: hello, fingerprint: self.connection.peerFingerprint,
                                  isPeerToPeer: self.connection.isPeerToPeer))
            self.finishIfDone()
        }
        connection.onEnd = { [weak self] reason in
            guard let self else { return }
            self.onEnd?(self.hasReceived, reason == nil)
        }
        connection.start()
    }

    func end(because reason: String?) {
        connection.end(because: reason)
    }

    private func finishIfDone() {
        if hasSent && hasReceived { connection.end(because: nil) }
    }
}

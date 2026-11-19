import Foundation
import Network

/// A connection another Polka made to this one. It answers with this Mac's hello,
/// which is all a Mac that's browsing wants before it closes. A Mac that wants to share
/// then makes its offer, and the connection waits for the person here to answer.
/// The rules for what may arrive are `NearbyIncomingTransfer`'s.
@MainActor
final class NearbyIncomingSession {
    let id = UUID()
    /// An offer arrived and checks out.
    var onOffer: ((NearbyIncomingSession) -> Void)?
    /// Everything accepted arrived and checks out. Store it now: the other Mac is told
    /// it's on the shelf right after this returns.
    var onReceived: (([NearbyReceivedItem]) -> Void)?
    var onEnd: ((NearbyIncomingSession) -> Void)?

    /// The sending Mac's key, known once its offer arrives.
    private(set) var fingerprint: String?
    var senderName: String? { rules.senderName }
    var offer: NearbyOffer? { rules.offer }

    private let connection: NearbyConnection
    /// What this side says, or nil to close without a word: a Mac that only receives
    /// from remembered Macs (none can be remembered before N4).
    private let hello: NearbyHello?
    private var rules = NearbyIncomingTransfer()

    /// How long to wait for the next text after Accept.
    static let dataTimeout: TimeInterval = 30

    init(connection: NWConnection, hello: NearbyHello?) {
        self.connection = NearbyConnection(connection, isIncoming: true)
        self.hello = hello
    }

    func start() {
        connection.onReady = { [weak self] in
            guard let self else { return }
            guard let hello = self.hello else {
                self.connection.end(because: "this Mac receives only from remembered Macs")
                return
            }
            self.connection.send([.hello(hello)])
        }
        connection.onMessage = { [weak self] message in
            try self?.read(message)
        }
        connection.onEnd = { [weak self] _ in
            guard let self else { return }
            self.onEnd?(self)
        }
        connection.start()
    }

    /// The person here answered. Accept waits for the texts; Decline closes.
    func answer(accept: Bool) {
        guard let reply = rules.answer(accept: accept) else { return }
        if accept {
            connection.setTimeout(Self.dataTimeout)
            connection.send([reply])
        } else {
            connection.send([reply]) { [weak self] in self?.connection.end(because: nil) }
        }
    }

    func end(because reason: String?) {
        connection.end(because: reason)
    }

    private func read(_ message: NearbyMessage) throws {
        switch try rules.read(message) {
        case .nothing:
            if rules.stage == .texts { connection.setTimeout(Self.dataTimeout) }
        case .offered:
            // Mutual TLS asks for a certificate, so there's always one; refused if not.
            guard let fingerprint = connection.peerFingerprint else {
                throw NearbyIncomingTransfer.Failure.outOfTurn
            }
            self.fingerprint = fingerprint
            // The offer line declines it after `answerTimeout`; this only catches a
            // line that somehow never does.
            connection.setTimeout(NearbyOfferLine.answerTimeout + 10)
            onOffer?(self)
        case let .received(items):
            onReceived?(items)
            connection.send([.done]) { [weak self] in self?.connection.end(because: nil) }
        }
    }
}

/// A connection this Polka makes to share tiles with another. The rules for what's
/// said are `NearbyOutgoingTransfer`'s; this reports how it's going.
@MainActor
final class NearbyOutgoingSession {
    enum Status: Equatable {
        case connecting
        /// The offer is on the other Mac's screen, or waiting to be.
        case waiting
        case sending
        /// The other Mac says it's all on its shelf.
        case sent
        /// Declined, or not answered in time.
        case declined
        case failed(Failure)

        var isFinished: Bool {
            switch self {
            case .sent, .declined, .failed: return true
            case .connecting, .waiting, .sending: return false
            }
        }
    }

    enum Failure: Equatable {
        /// It couldn't be reached, didn't answer, or closed without a word (a Mac
        /// that receives only from remembered Macs does that).
        case unreachable
        /// Its Polka is too old to take offers.
        case tooOld
        /// Something else answered with a different key than the Mac that was found.
        case wrongMac
    }

    var onStatus: ((Status) -> Void)?
    private(set) var status: Status = .connecting

    private let connection: NearbyConnection
    private let hello: NearbyHello
    private var transfer: NearbyOutgoingTransfer
    private let expectedFingerprint: String?

    /// How long to wait for an answer: the other Mac declines on its own after its
    /// `answerTimeout`, so this only covers one that never says.
    static let answerTimeout = NearbyOfferLine.answerTimeout + 15
    static let deliveryTimeout: TimeInterval = 30

    init(connection: NWConnection, hello: NearbyHello, transfer: NearbyOutgoingTransfer,
         expectedFingerprint: String?) {
        self.connection = NearbyConnection(connection, isIncoming: false)
        self.hello = hello
        self.transfer = transfer
        self.expectedFingerprint = expectedFingerprint
    }

    func start() {
        connection.onReady = { [weak self] in
            guard let self else { return }
            self.connection.send([.hello(self.hello)])
        }
        connection.onMessage = { [weak self] message in
            try self?.read(message)
        }
        connection.onEnd = { [weak self] _ in
            self?.finish(.failed(.unreachable))
        }
        connection.start()
    }

    func cancel() {
        finish(.failed(.unreachable))
        connection.end(because: "cancelled")
    }

    private func read(_ message: NearbyMessage) throws {
        if transfer.stage == .hello, let expectedFingerprint,
           connection.peerFingerprint != expectedFingerprint {
            finish(.failed(.wrongMac))
            throw NearbyOutgoingTransfer.Failure.outOfTurn
        }
        let step: (event: NearbyOutgoingTransfer.Event, send: [NearbyMessage])
        do {
            step = try transfer.read(message)
        } catch NearbyOutgoingTransfer.Failure.tooOld {
            finish(.failed(.tooOld))
            throw NearbyOutgoingTransfer.Failure.tooOld
        }
        switch step.event {
        case .nothing:
            break
        case .offered:
            connection.setTimeout(Self.answerTimeout)
            update(.waiting)
        case .accepted:
            connection.setTimeout(Self.deliveryTimeout)
            update(.sending)
        case .declined:
            finish(.declined)
            connection.end(because: nil)
        case .delivered:
            finish(.sent)
            connection.end(because: nil)
        }
        if !step.send.isEmpty { connection.send(step.send) }
    }

    private func update(_ new: Status) {
        guard !status.isFinished, status != new else { return }
        status = new
        onStatus?(new)
    }

    private func finish(_ final: Status) {
        guard !status.isFinished else { return }
        status = final
        onStatus?(final)
    }
}

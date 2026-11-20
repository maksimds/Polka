import Foundation
import Network

/// A connection another Polka made to this one. It answers with this Mac's hello,
/// which is all a Mac that's browsing wants before it closes. A Mac that wants to share
/// then makes its offer, sends the pictures it announced, and the connection waits for
/// the person here to answer. After Accept, texts and files arrive; files are written
/// by a `NearbyFileSink`. The rules for what may arrive are `NearbyIncomingTransfer`'s.
/// A Mac that wants to remember this one asks instead of offering, and the connection
/// is handed to a `NearbyRememberSession`.
@MainActor
final class NearbyIncomingSession {
    /// How it ended, for what the panel says.
    enum Ending: Equatable {
        /// Everything arrived, or it was declined, or it was only a hello.
        case finished
        /// The other Mac stopped it.
        case cancelledByThem
        /// The person here stopped it.
        case cancelledHere
        /// Anything else: the connection dropped, something didn't check out, the disk
        /// refused.
        case failed
    }

    let id = UUID()
    /// An offer arrived, with all its pictures, and checks out.
    var onOffer: ((NearbyIncomingSession) -> Void)?
    /// It asks to remember this Mac. Answer at once with `handOver` or
    /// `refuseRemembering`.
    var onRememberRequest: ((NearbyIncomingSession) -> Void)?
    /// Bytes of files in so far, of how many, after Accept.
    var onProgress: ((_ done: Int64, _ total: Int64) -> Void)?
    /// Everything accepted arrived and checks out. Store it now: the other Mac is told
    /// it's on the shelf right after this returns.
    var onReceived: (([NearbyReceivedItem]) -> Void)?
    var onEnd: ((NearbyIncomingSession) -> Void)?

    /// The sending Mac's key, known once its offer arrives.
    private(set) var fingerprint: String?
    private(set) var ending: Ending = .finished
    var senderName: String? { rules.senderName }
    var offer: NearbyOffer? { rules.offer }
    /// The other Mac's whole public key, once the TLS handshake is done.
    var peerKey: Data? { connection.peerPublicKey }
    /// The offer's pictures, by place, undecoded.
    private(set) var previews: [Int: Data] = [:]

    private let connection: NearbyConnection
    /// What this side says to the Mac with this key, once the handshake shows it, or
    /// nil to close without a word: a Mac that only receives from remembered Macs does
    /// that to everyone else.
    private let hello: (Data?) -> NearbyHello?
    private var rules = NearbyIncomingTransfer()
    private var sink: NearbyFileSink?
    private var hasEnded = false
    /// The last whole percent reported, so progress isn't reported for every piece.
    private var reportedPercent = -1

    /// How long to wait for the next text, picture or piece.
    static let dataTimeout: TimeInterval = 30

    init(connection: NWConnection, hello: @escaping (Data?) -> NearbyHello?) {
        self.connection = NearbyConnection(connection, isIncoming: true)
        self.hello = hello
    }

    func start() {
        connection.onReady = { [weak self] in
            guard let self else { return }
            guard let hello = self.hello(self.connection.peerPublicKey) else {
                self.connection.end(because: "this Mac receives only from remembered Macs")
                return
            }
            self.connection.send([.hello(hello)])
        }
        connection.onMessage = { [weak self] message in
            try self?.read(message)
        }
        connection.onPiece = { [weak self] bytes in
            try self?.readPiece(bytes)
        }
        connection.onEnd = { [weak self] reason in
            guard let self else { return }
            self.hasEnded = true
            if self.ending == .finished && reason != nil && self.rules.stage != .finished {
                self.ending = .failed
            }
            // Accepted and not all in, without a word: a failure too.
            if self.ending == .finished && self.rules.stage == .receiving {
                self.ending = .failed
            }
            if self.ending != .finished { self.sink?.discard() }
            self.onEnd?(self)
        }
        connection.start()
    }

    /// The person here answered. Accept waits for what was offered, files written into
    /// `copies`; Decline closes.
    func answer(accept: Bool, copies: ShelfCopies?) {
        if accept, let offer = rules.offer, offer.hasFiles {
            guard let copies else {
                answer(accept: false, copies: nil)
                return
            }
            var names: [Int: String] = [:]
            for (index, item) in offer.items.enumerated() {
                if case let .file(name, _) = item { names[index] = name }
            }
            let sink = NearbyFileSink(copies: copies, names: names)
            sink.onFailure = { [weak self] _ in
                guard let self else { return }
                self.ending = .failed
                self.connection.end(because: "a received file couldn't be kept")
            }
            self.sink = sink
        }
        guard let reply = rules.answer(accept: accept) else { return }
        if accept {
            connection.setTimeout(Self.dataTimeout)
            connection.send([reply])
            reportProgress()
        } else {
            connection.send([reply]) { [weak self] in self?.connection.end(because: nil) }
        }
    }

    /// The person here stopped it after Accept.
    func cancel() {
        guard !hasEnded else { return }
        ending = .cancelledHere
        if let message = rules.cancel() {
            connection.send([message]) { [weak self] in self?.connection.end(because: "cancelled here") }
            // Ends anyway if the message can't go.
            connection.setTimeout(2)
        } else {
            connection.end(because: "cancelled here")
        }
    }

    func end(because reason: String?) {
        connection.end(because: reason)
    }

    /// Gives the connection to remembering. This session hears nothing more of it, and
    /// doesn't report its end.
    func handOver() -> NearbyConnection {
        hasEnded = true
        connection.onMessage = nil
        connection.onPiece = nil
        connection.onEnd = nil
        onEnd = nil
        return connection
    }

    /// Nobody here is waiting to remember a Mac, or remembering is busy with another.
    func refuseRemembering() {
        connection.send([.decline]) { [weak self] in self?.connection.end(because: nil) }
        connection.setTimeout(2)
    }

    private func read(_ message: NearbyMessage) throws {
        let event: NearbyIncomingTransfer.Event
        do {
            event = try rules.read(message)
        } catch NearbyIncomingTransfer.Failure.cancelled {
            ending = .cancelledByThem
            throw NearbyIncomingTransfer.Failure.cancelled
        }
        switch event {
        case .rememberRequested:
            onRememberRequest?(self)
        case .nothing:
            if rules.stage == .previews || rules.stage == .receiving {
                connection.setTimeout(Self.dataTimeout)
            }
        case let .offered(_, previews):
            // Mutual TLS asks for a certificate, so there's always one; refused if not.
            guard let fingerprint = connection.peerFingerprint else {
                throw NearbyIncomingTransfer.Failure.outOfTurn
            }
            self.fingerprint = fingerprint
            self.previews = previews
            // The offer line declines it after `answerTimeout`; this only catches a
            // line that somehow never does.
            connection.setTimeout(NearbyOfferLine.answerTimeout + 10)
            onOffer?(self)
        case .piece:
            break
        case let .fileEnded(index, sha256):
            connection.setTimeout(Self.dataTimeout)
            sink?.end(index, sha256: sha256)
        case let .complete(links, texts):
            connection.setTimeout(Self.dataTimeout)
            guard let offer = rules.offer else { throw NearbyIncomingTransfer.Failure.outOfTurn }
            let deliver: ([Int: URL]) -> Void = { [weak self] files in
                guard let self, !self.hasEnded else { return }
                var items: [NearbyReceivedItem] = []
                for index in offer.items.indices {
                    if let url = links[index] {
                        items.append(.link(url))
                    } else if let text = texts[index] {
                        items.append(.text(text))
                    } else if let file = files[index] {
                        items.append(.file(file))
                    }
                }
                self.onReceived?(items)
                self.connection.send([.done]) { [weak self] in self?.connection.end(because: nil) }
            }
            guard let sink else {
                deliver([:])
                return
            }
            sink.handOver { [weak self] files in
                guard let self else { return }
                guard let files else {
                    self.ending = .failed
                    self.connection.end(because: "received files didn't check out")
                    return
                }
                deliver(files)
            }
        }
    }

    private func readPiece(_ bytes: Data) throws {
        guard case let .piece(index) = try rules.readPiece(count: bytes.count), let sink else {
            throw NearbyIncomingTransfer.Failure.outOfTurn
        }
        connection.setTimeout(Self.dataTimeout)
        sink.write(bytes, to: index)
        reportProgress()
    }

    private func reportProgress() {
        let total = rules.totalBytes
        let percent = total > 0 ? Int(rules.receivedBytes * 100 / total) : 100
        guard percent != reportedPercent else { return }
        reportedPercent = percent
        onProgress?(rules.receivedBytes, total)
    }
}

/// A connection this Polka makes to share tiles with another. The rules for what's
/// said are `NearbyOutgoingTransfer`'s; this sends the files after Accept, a piece at
/// a time, and reports how it's going.
@MainActor
final class NearbyOutgoingSession {
    enum Status: Equatable {
        case connecting
        /// The offer is on the other Mac's screen, or waiting to be.
        case waiting
        /// Accepted, and this much of it sent, from 0 to 1.
        case sending(Double)
        /// The other Mac says it's all on its shelf.
        case sent
        /// Declined, or not answered in time.
        case declined
        /// Stopped, by either side.
        case cancelled
        case failed(Failure)

        var isFinished: Bool {
            switch self {
            case .sent, .declined, .cancelled, .failed: return true
            case .connecting, .waiting, .sending: return false
            }
        }
    }

    enum Failure: Equatable {
        /// It couldn't be reached, didn't answer, or closed without a word (a Mac
        /// that receives only from remembered Macs does that).
        case unreachable
        /// Its Polka is too old to take offers, or files.
        case tooOld
        /// Something else answered with a different key than the Mac that was found.
        case wrongMac
        /// The files add up to more than `NearbyOffer.maxTotalBytes`.
        case tooLarge
        /// A file couldn't be read, or got shorter while it was sent.
        case unreadable
        /// Nothing chosen can be sent.
        case nothingToSend
    }

    var onStatus: ((Status) -> Void)?
    private(set) var status: Status = .connecting
    /// The other Mac said something.
    private(set) var heardBack = false
    /// It ended before the other Mac said anything, because its handshake failed: the
    /// other Mac turns connections away like that while it's busy with others, so it's
    /// worth trying again. Not one that timed out (the Mac has gone), nor one closed
    /// cleanly (a Mac receiving only from remembered Macs does that on purpose).
    private(set) var wasTurnedAway = false

    private let connection: NearbyConnection
    private let hello: NearbyHello
    private var transfer: NearbyOutgoingTransfer
    private let expectedFingerprint: String?

    // Sending files.
    private var fileQueue: [(index: Int, url: URL, size: Int64)] = []
    private var source: NearbyFileSource?
    private var sourceIndex = 0
    private var isReading = false
    private var piecesInFlight = 0
    private var sentBytes: Int64 = 0
    private var doneSent = false
    private var reportedPercent = -1

    /// How long to wait for an answer: the other Mac declines on its own after its
    /// `answerTimeout`, so this only covers one that never says.
    static let answerTimeout = NearbyOfferLine.answerTimeout + 15
    static let deliveryTimeout: TimeInterval = 30
    /// Pieces handed to the network at once, so it always has the next one ready.
    static let piecesAhead = 4

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
        connection.onEnd = { [weak self] reason in
            guard let self else { return }
            self.wasTurnedAway = !self.heardBack && reason != nil && !self.connection.timedOut
            self.source?.close()
            self.finish(.failed(.unreachable))
        }
        connection.start()
    }

    /// The person here stopped it.
    func cancel() {
        guard !status.isFinished else { return }
        source?.close()
        finish(.cancelled)
        stop(because: "cancelled")
    }

    private func read(_ message: NearbyMessage) throws {
        heardBack = true
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
        } catch NearbyOutgoingTransfer.Failure.cancelled {
            source?.close()
            finish(.cancelled)
            throw NearbyOutgoingTransfer.Failure.cancelled
        }
        if !step.send.isEmpty { connection.send(step.send) }
        switch step.event {
        case .nothing:
            break
        case .offered:
            connection.setTimeout(Self.answerTimeout)
            update(.waiting)
        case .accepted:
            connection.setTimeout(Self.deliveryTimeout)
            fileQueue = transfer.files
            update(.sending(0))
            pump()
        case .declined:
            finish(.declined)
            connection.end(because: nil)
        case .delivered:
            finish(.sent)
            connection.end(because: nil)
        }
    }

    /// Keeps up to `piecesAhead` pieces with the network, reading one at a time, then
    /// each file's end, and `done` after the last.
    private func pump() {
        guard !status.isFinished, !isReading, !doneSent, piecesInFlight < Self.piecesAhead else { return }
        guard sourceIndex < fileQueue.count else {
            doneSent = true
            connection.send([.done])
            connection.setTimeout(Self.deliveryTimeout)
            return
        }
        let file = fileQueue[sourceIndex]
        if source == nil { source = NearbyFileSource(url: file.url, size: file.size) }
        isReading = true
        source?.next { [weak self] result in
            guard let self, !self.status.isFinished else { return }
            self.isReading = false
            switch result {
            case let .success(.piece(bytes)):
                self.piecesInFlight += 1
                self.connection.sendPiece(bytes) { [weak self] in
                    guard let self else { return }
                    self.piecesInFlight -= 1
                    self.sentBytes += Int64(bytes.count)
                    self.connection.setTimeout(Self.deliveryTimeout)
                    self.reportProgress()
                    self.pump()
                }
            case let .success(.end(sha256)):
                self.connection.send([.fileEnd(NearbyFileEnd(index: file.index, sha256: sha256))])
                self.source = nil
                self.sourceIndex += 1
            case .failure:
                Log.nearby.error("A file to send couldn't be read")
                self.finish(.failed(.unreadable))
                self.stop(because: "a file couldn't be read")
                return
            }
            self.pump()
        }
    }

    /// Tells the other Mac it's stopped, if its version listens, then closes.
    private func stop(because reason: String) {
        if let message = transfer.cancel() {
            connection.send([message]) { [weak self] in self?.connection.end(because: reason) }
            // Ends anyway if the message can't go.
            connection.setTimeout(2)
        } else {
            connection.end(because: reason)
        }
    }

    private func reportProgress() {
        let total = transfer.totalBytes
        guard total > 0 else { return }
        let percent = Int(sentBytes * 100 / total)
        guard percent != reportedPercent else { return }
        reportedPercent = percent
        update(.sending(Double(sentBytes) / Double(total)))
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

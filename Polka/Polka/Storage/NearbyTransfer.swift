import Foundation

/// One thing that arrived from another Mac and was accepted.
enum NearbyReceivedItem: Equatable {
    case link(URL)
    case text(String)
    /// A file, already written, checked and quarantined in a copy folder of its own.
    case file(URL)

    /// The new tile, named by this Mac as anything new is, and marked with who sent it.
    /// A file is a copy with no original, like a file an app hands over by promise.
    func draft(from senderName: String) -> ShelfItem.Draft {
        var draft: ShelfItem.Draft
        switch self {
        case let .link(url): draft = ShelfItem.Draft(linkURL: url)
        case let .text(text): draft = ShelfItem.Draft(text: text)
        case let .file(url): draft = ShelfItem.Draft(fileURL: url, storageMode: .copy)
        }
        draft.receivedFrom = senderName
        return draft
    }
}

/// The receiving side of a transfer, step by step: what may arrive next, and what it
/// means. Anything out of turn is refused and the connection closes. Plain Swift, so
/// every hostile order of messages can be tested without a network. It counts a file's
/// bytes but doesn't keep them: whoever owns it writes them (`NearbyFileSink`) and
/// checks each file's hash.
///
/// A caller that's only asking this Mac's name (browsing) says hello and closes; one
/// that wants to share says hello, then makes its offer and sends the pictures it
/// announced, and waits for the answer. One that wants to remember this Mac asks
/// instead of offering, and from there `NearbyRememberExchange` takes over.
struct NearbyIncomingTransfer {
    enum Stage: Equatable {
        case hello
        case offer
        /// The offer is in; its pictures are on their way.
        case previews
        /// Everything to show is in; the person at this Mac decides.
        case answer
        /// Accepted: texts and files are on their way.
        case receiving
        case finished
    }

    enum Failure: Error, Equatable {
        /// A message the protocol doesn't allow at this point.
        case outOfTurn
        /// An offer from a Mac that didn't say who it is.
        case nameless
        /// An offer from a version that doesn't make them, or of files or pictures from
        /// one that doesn't send those.
        case tooOld
        /// A text, picture or file that isn't what the offer said, or a second one for
        /// an item.
        case notWhatWasOffered
        /// The other Mac stopped it.
        case cancelled
    }

    enum Event: Equatable {
        case nothing
        /// Show this to the person at this Mac, with the pictures that came with it,
        /// still undecoded.
        case offered(NearbyOffer, previews: [Int: Data])
        /// Bytes for the file at this place in the offer: write them on.
        case piece(index: Int)
        /// That file's last byte is in, and this is the hash the sender worked out.
        case fileEnded(index: Int, sha256: Data)
        /// Everything accepted has arrived. Links and texts are here; each file is
        /// where its writer put it, in the order of `fileIndices`.
        case complete(links: [Int: URL], texts: [Int: String])
        /// It asks to remember this Mac: hand the connection to remembering.
        case rememberRequested
    }

    private(set) var stage: Stage = .hello
    /// The name the other Mac gave. Not verified.
    private(set) var senderName: String?
    private(set) var offer: NearbyOffer?
    private var senderVersion = 0
    private var texts: [Int: String] = [:]
    private var previews: [Int: Data] = [:]
    /// The file being received, by its place among the offer's files.
    private var fileCursor = 0
    /// Bytes of that file in so far.
    private var fileBytes: Int64 = 0
    /// Bytes of every file in so far.
    private(set) var receivedBytes: Int64 = 0

    /// The places of the offer's files, in the order they're sent.
    var fileIndices: [Int] {
        guard let offer else { return [] }
        return offer.items.indices.filter { if case .file = offer.items[$0] { return true } else { return false } }
    }

    var totalBytes: Int64 { offer?.totalFileBytes ?? 0 }

    mutating func read(_ message: NearbyMessage) throws -> Event {
        if case .cancel = message, [.previews, .answer, .receiving].contains(stage) {
            stage = .finished
            throw Failure.cancelled
        }
        switch (stage, message) {
        case let (.hello, .hello(hello)):
            senderName = hello.name
            senderVersion = hello.version
            stage = .offer
            return .nothing
        case let (.offer, .offer(offer)):
            guard senderVersion >= NearbyProtocol.offerVersion else { throw Failure.tooOld }
            guard senderName != nil else { throw Failure.nameless }
            if offer.hasFiles || !offer.previews.isEmpty {
                guard senderVersion >= NearbyProtocol.fileVersion else { throw Failure.tooOld }
            }
            self.offer = offer
            stage = .previews
            return previewsIfAllIn()
        case (.offer, .remember):
            guard senderVersion >= NearbyProtocol.rememberVersion else { throw Failure.tooOld }
            guard senderName != nil else { throw Failure.nameless }
            stage = .finished
            return .rememberRequested
        case let (.previews, .preview(preview)):
            guard let offer, offer.previews.contains(preview.index), previews[preview.index] == nil else {
                throw Failure.notWhatWasOffered
            }
            previews[preview.index] = preview.png
            return previewsIfAllIn()
        case let (.receiving, .text(text)):
            guard let offer, offer.items.indices.contains(text.index),
                  case let .text(excerpt, length) = offer.items[text.index],
                  texts[text.index] == nil,
                  // Checked against the length before it's turned into a string: never
                  // more than 3 UTF-8 bytes per UTF-16 unit.
                  text.data.count <= length * 3,
                  let string = String(data: text.data, encoding: .utf8),
                  NearbyOffer.text(string, matchesExcerpt: excerpt, length: length) else {
                throw Failure.notWhatWasOffered
            }
            texts[text.index] = string
            return .nothing
        case let (.receiving, .fileEnd(end)):
            let files = fileIndices
            guard let offer, fileCursor < files.count, files[fileCursor] == end.index,
                  case let .file(_, size) = offer.items[end.index], fileBytes == size else {
                throw Failure.notWhatWasOffered
            }
            fileCursor += 1
            fileBytes = 0
            return .fileEnded(index: end.index, sha256: end.sha256)
        case (.receiving, .done):
            guard let offer, fileCursor == fileIndices.count else { throw Failure.notWhatWasOffered }
            var links: [Int: URL] = [:]
            for (index, item) in offer.items.enumerated() {
                switch item {
                case let .link(url):
                    links[index] = url
                case .text:
                    guard texts[index] != nil else { throw Failure.notWhatWasOffered }
                case .file:
                    break
                }
            }
            stage = .finished
            return .complete(links: links, texts: texts)
        default:
            throw Failure.outOfTurn
        }
    }

    /// A piece of a file arrived: which file it belongs to. Refused before Accept, with
    /// no file left to send, or past the size the offer gave, at the first byte over.
    mutating func readPiece(count: Int) throws -> Event {
        let files = fileIndices
        guard stage == .receiving, let offer, fileCursor < files.count,
              case let .file(_, size) = offer.items[files[fileCursor]] else {
            throw Failure.outOfTurn
        }
        guard count > 0, fileBytes + Int64(count) <= size else { throw Failure.notWhatWasOffered }
        fileBytes += Int64(count)
        receivedBytes += Int64(count)
        return .piece(index: files[fileCursor])
    }

    /// The person answered the offer: what to send back, or nil if there's no offer
    /// waiting for an answer.
    mutating func answer(accept: Bool) -> NearbyMessage? {
        guard stage == .answer else { return nil }
        stage = accept ? .receiving : .finished
        return accept ? .accept : .decline
    }

    /// This side stopped it: what to tell the other Mac, if it's still a time to.
    mutating func cancel() -> NearbyMessage? {
        guard [.previews, .answer, .receiving].contains(stage) else { return nil }
        stage = .finished
        return senderVersion >= NearbyProtocol.fileVersion ? .cancel : nil
    }

    private mutating func previewsIfAllIn() -> Event {
        guard let offer, previews.count == offer.previews.count else { return .nothing }
        stage = .answer
        return .offered(offer, previews: previews)
    }
}

/// What a tile is to a transfer going out: a link or text as it is, a file as the file
/// Polka opens for it, with the name and size it has now.
enum NearbyOutgoingItem: Equatable {
    case link(URL)
    case text(String)
    case file(url: URL, name: String, size: Int64)

    enum Failure: Error, Equatable {
        /// The files add up to more than `NearbyOffer.maxTotalBytes`.
        case tooLarge
        /// Nothing chosen can be sent.
        case nothing
    }

    /// The items for these tiles, each with the tile it came from, leaving out any that
    /// can't be sent: folders, packages (an app is a folder too), missing files, and
    /// links that aren't web addresses. At most `NearbyOffer.maxItems`. Reads the disk,
    /// so not on the main thread.
    static func prepare(_ items: [ShelfItem]) throws -> [(source: ShelfItem, item: NearbyOutgoingItem)] {
        var prepared: [(source: ShelfItem, item: NearbyOutgoingItem)] = []
        for shelfItem in items where prepared.count < NearbyOffer.maxItems {
            guard let item = outgoing(for: shelfItem) else { continue }
            prepared.append((shelfItem, item))
        }
        guard !prepared.isEmpty else { throw Failure.nothing }
        let total = prepared.reduce(Int64(0)) { total, pair in
            if case let .file(_, _, size) = pair.item { return total + size }
            return total
        }
        guard total <= NearbyOffer.maxTotalBytes else { throw Failure.tooLarge }
        return prepared
    }

    private static func outgoing(for shelfItem: ShelfItem) -> NearbyOutgoingItem? {
        switch shelfItem.source {
        case let .text(text):
            return NearbyOffer.item(for: shelfItem) == nil ? nil : .text(text)
        case .link:
            guard case let .link(url) = NearbyOffer.item(for: shelfItem) else { return nil }
            return .link(url)
        case .file:
            guard shelfItem.kind == .file else { return nil }
            let url = shelfItem.urlToOpen()
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return nil }
            return .file(url: url, name: url.lastPathComponent, size: Int64(size))
        case .shelfFolder:
            return nil
        }
    }

    var offerItem: NearbyOffer.Item {
        switch self {
        case let .link(url): return .link(url)
        case let .text(text): return .text(excerpt: NearbyOffer.excerpt(of: text), length: text.utf16.count)
        case let .file(_, name, size): return .file(name: name, size: size)
        }
    }
}

/// The sending side of a transfer, step by step. Both sides say hello first; once the
/// other Mac's hello shows it takes offers, the offer goes with its pictures, then on
/// Accept the texts. The files follow, each as pieces and a `fileEnd`, which whoever
/// owns this sends (`NearbyFileSource` reads them), then `done`, and the other Mac's
/// own `done` means it's all on its shelf.
struct NearbyOutgoingTransfer {
    enum Stage: Equatable {
        case hello
        case answer
        case sending
        case finished
    }

    enum Failure: Error, Equatable {
        case outOfTurn
        /// The other Mac's Polka is too old to take offers, or files.
        case tooOld
        /// The other Mac stopped it.
        case cancelled
    }

    enum Event: Equatable {
        case nothing
        /// The offer has gone; waiting for an answer.
        case offered
        /// Accepted: the texts are going; send the files next.
        case accepted
        case declined
        /// The other Mac says everything is on its shelf.
        case delivered
    }

    let items: [NearbyOutgoingItem]
    /// Pictures for some of the items, by place, each a PNG `NearbyPreviewImage` takes.
    let previews: [Int: Data]
    private(set) var stage: Stage = .hello
    /// The offer as it went, which depends on the other Mac's version.
    private(set) var offer: NearbyOffer?
    private var peerVersion = 0

    var totalBytes: Int64 {
        items.reduce(0) { total, item in
            if case let .file(_, _, size) = item { return total + size }
            return total
        }
    }

    /// The files to send after Accept, with their places in the offer.
    var files: [(index: Int, url: URL, size: Int64)] {
        items.enumerated().compactMap { index, item in
            guard case let .file(url, _, size) = item else { return nil }
            return (index, url, size)
        }
    }

    init(items: [NearbyOutgoingItem], previews: [Int: Data] = [:]) {
        self.items = items
        // Text never has one: the other Mac draws its page from the text itself.
        self.previews = previews.filter { index, png in
            guard items.indices.contains(index), NearbyPreviewImage.isAcceptable(png) else { return false }
            if case .text = items[index] { return false }
            return true
        }
    }

    /// Reads one message from the other Mac, and returns what to send back.
    mutating func read(_ message: NearbyMessage) throws -> (event: Event, send: [NearbyMessage]) {
        if case .cancel = message, [.answer, .sending].contains(stage) {
            stage = .finished
            throw Failure.cancelled
        }
        switch (stage, message) {
        case let (.hello, .hello(hello)):
            guard hello.version >= NearbyProtocol.offerVersion else { throw Failure.tooOld }
            peerVersion = hello.version
            let takesFiles = hello.version >= NearbyProtocol.fileVersion
            if !takesFiles && !files.isEmpty { throw Failure.tooOld }
            var offer = NearbyOffer(items: items.map(\.offerItem))
            // Version 2 has no pictures.
            let sentPreviews = takesFiles ? previews : [:]
            offer.previews = Set(sentPreviews.keys)
            self.offer = offer
            stage = .answer
            let pictures = sentPreviews.keys.sorted().map { NearbyMessage.preview(NearbyPreview(index: $0, png: sentPreviews[$0]!)) }
            return (.offered, [.offer(offer)] + pictures)
        case (.answer, .accept):
            stage = .sending
            let textMessages = items.enumerated().compactMap { index, item -> NearbyMessage? in
                guard case let .text(text) = item else { return nil }
                return .text(NearbyText(index: index, data: Data(text.utf8)))
            }
            return (.accepted, textMessages)
        case (.answer, .decline):
            stage = .finished
            return (.declined, [])
        case (.sending, .done):
            stage = .finished
            return (.delivered, [])
        default:
            throw Failure.outOfTurn
        }
    }

    /// This side stopped it: what to tell the other Mac, if it's still a time to.
    mutating func cancel() -> NearbyMessage? {
        guard [.answer, .sending].contains(stage) else { return nil }
        stage = .finished
        return peerVersion >= NearbyProtocol.fileVersion ? .cancel : nil
    }
}

/// Which incoming offer the panel shows, and when (NS-14, NS-17). Only offers from Macs
/// that aren't remembered wait here; a remembered Mac's are accepted without asking.
/// Offers wait in the order they arrived, at most one from each Mac and at most
/// `maxFromStrangers` in all. Every offer is declined `answerTimeout` after it arrived,
/// shown or not (`NearbyService` keeps that time). Plain Swift with the time passed
/// in, so it can be tested.
///
/// A Mac is its key, and a hostile Polka can make a new key for every offer (N6). So
/// what keeps strangers from opening the panel over and over is counted for all of
/// them together: an offer opens it at most once a minute, whichever Mac it's from,
/// and Decline and Block turns away every Mac that isn't remembered for
/// `blockPause`, not only the one blocked, which could come back with a new key.
struct NearbyOfferLine {
    static let maxFromStrangers = 3
    static let strangerOpenInterval: TimeInterval = 60
    static let answerTimeout: TimeInterval = 120
    /// After Decline and Block, how long every Mac that isn't remembered is turned away.
    static let blockPause: TimeInterval = 600

    struct Entry: Equatable {
        let id: UUID
        /// The sending Mac's key, from the TLS session.
        let fingerprint: String
    }

    enum Admission: Equatable {
        case admitted
        /// "Decline and Block" was chosen for this Mac since Polka started.
        case blocked
        /// "Decline and Block" was chosen for some Mac within `blockPause`: every Mac
        /// that isn't remembered is turned away meanwhile.
        case paused
        /// This Mac already has an offer waiting.
        case alreadyWaiting
        case full
    }

    private(set) var entries: [Entry] = []
    /// The offer on screen, if any.
    private(set) var shownID: UUID?
    private(set) var blocked: Set<String> = []
    /// Until when every Mac that isn't remembered is turned away, after a Block.
    private(set) var pausedUntil: Date?
    /// When an offer last opened the panel, whichever Mac it was from.
    private var lastShown: Date?

    mutating func admit(id: UUID, fingerprint: String, at now: Date = Date()) -> Admission {
        if blocked.contains(fingerprint) { return .blocked }
        if let pausedUntil, now < pausedUntil { return .paused }
        if entries.contains(where: { $0.fingerprint == fingerprint }) { return .alreadyWaiting }
        if entries.count >= Self.maxFromStrangers { return .full }
        entries.append(Entry(id: id, fingerprint: fingerprint))
        return .admitted
    }

    /// The offer that may open the panel now, if none is shown: the first in line, once
    /// a minute has passed since an offer last opened it. Otherwise nil, with the time
    /// it will be allowed to, if one is waiting for that.
    func next(at now: Date) -> (id: UUID?, checkAgainAt: Date?) {
        guard shownID == nil, let first = entries.first else { return (nil, nil) }
        if let lastShown {
            let allowed = lastShown.addingTimeInterval(Self.strangerOpenInterval)
            if allowed > now { return (nil, allowed) }
        }
        return (first.id, nil)
    }

    mutating func show(_ id: UUID, at now: Date) {
        guard entries.contains(where: { $0.id == id }) else { return }
        shownID = id
        lastShown = now
    }

    /// Answered, timed out or withdrawn by the other Mac.
    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if shownID == id { shownID = nil }
    }

    /// That Mac until Polka quits, and every Mac that isn't remembered for
    /// `blockPause`. Offers already waiting are left for the caller to decline.
    mutating func block(_ fingerprint: String, at now: Date = Date()) {
        blocked.insert(fingerprint)
        pausedUntil = now.addingTimeInterval(Self.blockPause)
    }
}

/// An offer from another Mac, waiting for an answer, as the panel shows it.
struct NearbyIncomingOffer: Identifiable, Equatable {
    let id: UUID
    /// The name it gave. Not verified.
    let senderName: String
    let fingerprint: String
    let offer: NearbyOffer
    /// Each item as the tile it would be, named by this Mac from what the offer holds:
    /// a link from its address, a text from its start, a file from its cleaned name.
    /// Made once, so the tiles keep their identity, and their pictures stay cached,
    /// while the offer is up.
    let previews: [ShelfItem]
    /// The pictures the other Mac sent, by the preview tile they belong to. Checked by
    /// their bytes (`NearbyPreviewImage`) but not decoded until Show Preview.
    let pictures: [ShelfItem.ID: Data]
    /// It goes by the name of a remembered Mac, or one that looks like it, with another
    /// key: someone claiming to be a Mac this one trusts, or that Mac with a new key.
    let usesRememberedName: Bool

    /// Where an offered file's tile points while it's only an offer: nowhere real,
    /// so nothing reads it, but with the file's name, so its type shows.
    static let placeholderFolder = "/.polka-offered"

    init(id: UUID, senderName: String, fingerprint: String, offer: NearbyOffer,
         pictures: [Int: Data] = [:], usesRememberedName: Bool = false, arrivedAt: Date = Date()) {
        self.id = id
        self.senderName = senderName
        self.usesRememberedName = usesRememberedName
        self.fingerprint = fingerprint
        self.offer = offer
        previews = offer.items.enumerated().map { index, item in
            let draft: ShelfItem.Draft
            switch item {
            case let .link(url): draft = ShelfItem.Draft(linkURL: url)
            case let .text(excerpt, _): draft = ShelfItem.Draft(text: excerpt)
            case let .file(name, _):
                return ShelfItem(id: UUID(), kind: .file, title: name,
                                 source: .file(path: Self.placeholderFolder + "/" + name, bookmark: nil),
                                 storageMode: .copy, createdAt: arrivedAt, sortOrder: index)
            }
            // Names from another Mac lose control and invisible formatting characters
            // (a right-to-left override would make one read as something else).
            let title = NearbyName.clean(draft.title) ?? (item.isText ? "Text" : "Link")
            return ShelfItem(id: UUID(), kind: draft.kind, title: title, source: draft.source,
                             storageMode: .reference, createdAt: arrivedAt, sortOrder: index)
        }
        var byTile: [ShelfItem.ID: Data] = [:]
        for (index, png) in pictures where previews.indices.contains(index) {
            byTile[previews[index].id] = png
        }
        self.pictures = byTile
    }
}

extension NearbyOffer.Item {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

/// An accepted offer still arriving, as the panel shows it.
struct NearbyReceiving: Identifiable, Equatable {
    let id: UUID
    /// The name it gave. Not verified.
    let senderName: String
    let itemCount: Int
    var receivedBytes: Int64
    /// What its files add up to; 0 for links and text alone.
    var totalBytes: Int64

    /// From 0 to 1.
    var fraction: Double {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
    }
}

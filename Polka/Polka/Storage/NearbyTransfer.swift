import Foundation

/// One thing that arrived from another Mac and was accepted.
enum NearbyReceivedItem: Equatable {
    case link(URL)
    case text(String)

    /// The new tile, named by this Mac as anything new is, and marked with who sent it.
    func draft(from senderName: String) -> ShelfItem.Draft {
        var draft: ShelfItem.Draft
        switch self {
        case let .link(url): draft = ShelfItem.Draft(linkURL: url)
        case let .text(text): draft = ShelfItem.Draft(text: text)
        }
        draft.receivedFrom = senderName
        return draft
    }
}

/// The receiving side of a transfer, step by step: what may arrive next, and what it
/// means. Anything out of turn is refused and the connection closes. Plain Swift, so
/// every hostile order of messages can be tested without a network.
///
/// A caller that's only asking this Mac's name (browsing) says hello and closes; one
/// that wants to share says hello, then makes its offer, and waits for the answer.
struct NearbyIncomingTransfer {
    enum Stage: Equatable {
        case hello
        case offer
        /// The offer is in; the person at this Mac decides.
        case answer
        /// Accepted: the text items' texts are on their way.
        case texts
        case finished
    }

    enum Failure: Error, Equatable {
        /// A message the protocol doesn't allow at this point.
        case outOfTurn
        /// An offer from a Mac that didn't say who it is.
        case nameless
        /// An offer from a version that doesn't make them.
        case tooOld
        /// A text that isn't the one the offer showed, or a second one for an item.
        case notWhatWasOffered
    }

    enum Event: Equatable {
        case nothing
        /// Show this to the person at this Mac.
        case offered(NearbyOffer)
        /// Everything accepted has arrived and checks out.
        case received([NearbyReceivedItem])
    }

    private(set) var stage: Stage = .hello
    /// The name the other Mac gave. Not verified.
    private(set) var senderName: String?
    private(set) var offer: NearbyOffer?
    private var senderVersion = 0
    private var texts: [Int: String] = [:]

    mutating func read(_ message: NearbyMessage) throws -> Event {
        switch (stage, message) {
        case let (.hello, .hello(hello)):
            senderName = hello.name
            senderVersion = hello.version
            stage = .offer
            return .nothing
        case let (.offer, .offer(offer)):
            guard senderVersion >= NearbyProtocol.offerVersion else { throw Failure.tooOld }
            guard senderName != nil else { throw Failure.nameless }
            self.offer = offer
            stage = .answer
            return .offered(offer)
        case let (.texts, .text(text)):
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
        case (.texts, .done):
            guard let offer else { throw Failure.outOfTurn }
            var items: [NearbyReceivedItem] = []
            for (index, item) in offer.items.enumerated() {
                switch item {
                case let .link(url):
                    items.append(.link(url))
                case .text:
                    guard let text = texts[index] else { throw Failure.notWhatWasOffered }
                    items.append(.text(text))
                }
            }
            stage = .finished
            return .received(items)
        default:
            throw Failure.outOfTurn
        }
    }

    /// The person answered the offer: what to send back, or nil if there's no offer
    /// waiting for an answer.
    mutating func answer(accept: Bool) -> NearbyMessage? {
        guard stage == .answer else { return nil }
        stage = accept ? .texts : .finished
        return accept ? .accept : .decline
    }
}

/// The sending side of a transfer, step by step. Both sides say hello first; once the
/// other Mac's hello shows it takes offers, the offer goes, then on Accept the texts
/// and `done`, and the other Mac's own `done` means it's all on its shelf.
struct NearbyOutgoingTransfer {
    enum Stage: Equatable {
        case hello
        case answer
        case sending
        case finished
    }

    enum Failure: Error, Equatable {
        case outOfTurn
        /// The other Mac's Polka is too old to take offers.
        case tooOld
    }

    enum Event: Equatable {
        case nothing
        /// The offer has gone; waiting for an answer.
        case offered
        case accepted
        case declined
        /// The other Mac says everything is on its shelf.
        case delivered
    }

    let offer: NearbyOffer
    /// Each text item's whole text, by its place in the offer.
    let texts: [Int: String]
    private(set) var stage: Stage = .hello

    /// The transfer for these tiles, leaving out any that can't be sent, or nil if
    /// none can. At most `NearbyOffer.maxItems`.
    init?(items: [ShelfItem]) {
        var offerItems: [NearbyOffer.Item] = []
        var texts: [Int: String] = [:]
        for shelfItem in items {
            guard offerItems.count < NearbyOffer.maxItems,
                  let item = NearbyOffer.item(for: shelfItem) else { continue }
            if case let .text(text) = shelfItem.source {
                texts[offerItems.count] = text
            }
            offerItems.append(item)
        }
        guard !offerItems.isEmpty else { return nil }
        offer = NearbyOffer(items: offerItems)
        self.texts = texts
    }

    /// Reads one message from the other Mac, and returns what to send back.
    mutating func read(_ message: NearbyMessage) throws -> (event: Event, send: [NearbyMessage]) {
        switch (stage, message) {
        case let (.hello, .hello(hello)):
            guard hello.version >= NearbyProtocol.offerVersion else { throw Failure.tooOld }
            stage = .answer
            return (.offered, [.offer(offer)])
        case (.answer, .accept):
            stage = .sending
            let textMessages = texts.keys.sorted().map { index in
                NearbyMessage.text(NearbyText(index: index, data: Data(texts[index]!.utf8)))
            }
            return (.accepted, textMessages + [.done])
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
}

/// Which incoming offer the panel shows, and when (NS-14, NS-17). Offers wait in the
/// order they arrived. A Mac that isn't remembered (in N2, every Mac) can open the
/// panel at most once a minute, has at most one offer waiting, and at most
/// `maxFromStrangers` wait at once. Every offer is declined `answerTimeout` after it
/// arrived, shown or not (`NearbyService` keeps that time). Plain Swift with the time
/// passed in, so it can be tested.
struct NearbyOfferLine {
    static let maxFromStrangers = 3
    static let strangerOpenInterval: TimeInterval = 60
    static let answerTimeout: TimeInterval = 120

    struct Entry: Equatable {
        let id: UUID
        /// The sending Mac's key, from the TLS session.
        let fingerprint: String
    }

    enum Admission: Equatable {
        case admitted
        /// "Decline and Block" was chosen for this Mac since Polka started.
        case blocked
        /// This Mac already has an offer waiting.
        case alreadyWaiting
        case full
    }

    private(set) var entries: [Entry] = []
    /// The offer on screen, if any.
    private(set) var shownID: UUID?
    private(set) var blocked: Set<String> = []
    /// When each Mac's offer last opened the panel.
    private var lastShown: [String: Date] = [:]

    mutating func admit(id: UUID, fingerprint: String) -> Admission {
        if blocked.contains(fingerprint) { return .blocked }
        if entries.contains(where: { $0.fingerprint == fingerprint }) { return .alreadyWaiting }
        if entries.count >= Self.maxFromStrangers { return .full }
        entries.append(Entry(id: id, fingerprint: fingerprint))
        return .admitted
    }

    /// The offer that may open the panel now, if none is shown: the first in line
    /// whose Mac hasn't opened it within the last minute. Otherwise nil, with the time
    /// one will be allowed to, if any is waiting for that.
    func next(at now: Date) -> (id: UUID?, checkAgainAt: Date?) {
        guard shownID == nil else { return (nil, nil) }
        var soonest: Date?
        for entry in entries {
            guard let last = lastShown[entry.fingerprint] else { return (entry.id, nil) }
            let allowed = last.addingTimeInterval(Self.strangerOpenInterval)
            if allowed <= now { return (entry.id, nil) }
            soonest = min(soonest ?? allowed, allowed)
        }
        return (nil, soonest)
    }

    mutating func show(_ id: UUID, at now: Date) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        shownID = id
        lastShown[entry.fingerprint] = now
    }

    /// Answered, timed out or withdrawn by the other Mac.
    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if shownID == id { shownID = nil }
    }

    /// Until Polka quits. Its waiting offers are left for the caller to decline.
    mutating func block(_ fingerprint: String) {
        blocked.insert(fingerprint)
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
    /// a link from its address, a text from its start. Made once, so the tiles keep
    /// their identity, and their pictures stay cached, while the offer is up.
    let previews: [ShelfItem]

    init(id: UUID, senderName: String, fingerprint: String, offer: NearbyOffer, arrivedAt: Date = Date()) {
        self.id = id
        self.senderName = senderName
        self.fingerprint = fingerprint
        self.offer = offer
        previews = offer.items.enumerated().map { index, item in
            let draft: ShelfItem.Draft
            switch item {
            case let .link(url): draft = ShelfItem.Draft(linkURL: url)
            case let .text(excerpt, _): draft = ShelfItem.Draft(text: excerpt)
            }
            // Names from another Mac lose control and invisible formatting characters
            // (a right-to-left override would make one read as something else).
            let title = NearbyName.clean(draft.title) ?? (item.isText ? "Text" : "Link")
            return ShelfItem(id: UUID(), kind: draft.kind, title: title, source: draft.source,
                             storageMode: .reference, createdAt: arrivedAt, expiresAt: nil, sortOrder: index)
        }
    }
}

extension NearbyOffer.Item {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

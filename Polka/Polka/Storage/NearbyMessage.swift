import Foundation

/// Nearby Sharing's wire format: what two Polkas say to each other inside their TLS
/// connection. Plain Swift with no networking, so every rule about what's accepted can
/// be tested on its own. Everything read here comes from another Mac and counts as
/// hostile until it has passed these checks.
enum NearbyProtocol {
    /// This Polka's protocol version, sent in `hello`. 1 was N1's, which only said hello;
    /// 2 adds offers.
    static let version = 2
    /// The oldest version this Polka talks to. There's no older, weaker one to fall back to.
    static let minimumVersion = 1
    /// The oldest version that takes offers. A Mac on version 1 is found, but can't be
    /// sent to.
    static let offerVersion = 2
    /// The Bonjour service type. It's also listed under `NSBonjourServices` in
    /// `Polka-Info.plist`, without which macOS doesn't let Polka use it.
    static let serviceType = "_polka._tcp"
    /// The TLS application protocol (ALPN), so a connection that isn't Polka's fails
    /// in the handshake, before any message is read.
    static let applicationProtocol = "polka/1"
    /// The largest message, checked from its length before any memory is set aside.
    static let maxMessageBytes = 1_000_000
}

/// One message between two Polkas, sent as a JSON object with a `type`.
enum NearbyMessage: Equatable {
    /// The first thing each side sends: its protocol version and, if it shares one,
    /// its name.
    case hello(NearbyHello)
    /// From the Mac sharing, right after the hellos: what it wants to share.
    case offer(NearbyOffer)
    /// The answer to an offer, from the Mac it was made to.
    case accept
    case decline
    /// From the Mac sharing, after Accept: one text item's whole text.
    case text(NearbyText)
    /// From the Mac sharing: everything has been sent. From the Mac receiving: it's all
    /// on the shelf.
    case done

    enum Failure: Error, Equatable {
        /// Not JSON, or not the shape Polka writes.
        case unreadable
        /// A `type` this version doesn't know.
        case unknownType
        /// Older than `NearbyProtocol.minimumVersion`.
        case tooOld(Int)
        /// A name with nothing left once it's cleaned.
        case badName
        /// An offer that breaks a rule (`NearbyOffer.validated`).
        case badOffer
        /// A text message for an item that can't exist.
        case badText
    }

    /// The message as it goes on the wire: its length in 4 bytes, most significant
    /// first, then the JSON.
    func frame() throws -> Data {
        let payload = try JSONEncoder().encode(Envelope(self))
        let count = UInt32(payload.count)
        var frame = Data([UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
                          UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
        frame.append(payload)
        return frame
    }

    /// Reads one message's JSON, as `NearbyFrameReader` hands it over.
    static func decode(_ payload: Data) throws -> NearbyMessage {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: payload) else {
            throw Failure.unreadable
        }
        switch envelope.type {
        case Envelope.helloType:
            guard var hello = envelope.hello else { throw Failure.unreadable }
            guard hello.version >= NearbyProtocol.minimumVersion else { throw Failure.tooOld(hello.version) }
            if let name = hello.name {
                guard let cleaned = NearbyName.clean(name) else { throw Failure.badName }
                hello.name = cleaned
            }
            return .hello(hello)
        case Envelope.offerType:
            guard let offer = envelope.offer else { throw Failure.unreadable }
            return .offer(try NearbyOffer.validated(offer))
        case Envelope.acceptType:
            return .accept
        case Envelope.declineType:
            return .decline
        case Envelope.textType:
            guard let text = envelope.text else { throw Failure.unreadable }
            guard (0..<NearbyOffer.maxItems).contains(text.index) else { throw Failure.badText }
            return .text(text)
        case Envelope.doneType:
            return .done
        default:
            throw Failure.unknownType
        }
    }

    private struct Envelope: Codable {
        static let helloType = "hello"
        static let offerType = "offer"
        static let acceptType = "accept"
        static let declineType = "decline"
        static let textType = "text"
        static let doneType = "done"

        var type: String
        var hello: NearbyHello?
        var offer: NearbyOffer.Wire?
        var text: NearbyText?

        init(_ message: NearbyMessage) {
            switch message {
            case let .hello(hello):
                type = Self.helloType
                self.hello = hello
            case let .offer(offer):
                type = Self.offerType
                self.offer = offer.wire
            case .accept:
                type = Self.acceptType
            case .decline:
                type = Self.declineType
            case let .text(text):
                type = Self.textType
                self.text = text
            case .done:
                type = Self.doneType
            }
        }
    }
}

/// What a Mac wants to share: links and text in N2, files from N3. A link is just its
/// web address, and a text item only its start and length until the offer is accepted.
/// Nothing a tile was renamed to is sent: the receiving Mac names everything itself, as
/// Polka does for anything new.
struct NearbyOffer: Equatable {
    static let maxItems = 50
    /// The longest web address, in UTF-8 bytes. Browsers take longer ones, but a link
    /// someone means to share is far shorter.
    static let maxLinkBytes = 8_192
    /// How much of a text item the offer shows, in characters as you see them.
    static let maxExcerptLength = 2_000

    enum Item: Equatable {
        case link(URL)
        /// The text's first `maxExcerptLength` characters, or all of it if it's shorter,
        /// and its whole length in UTF-16 units, as `ShelfItem.maxTextLength` counts.
        case text(excerpt: String, length: Int)
    }

    var items: [Item]

    /// What a tile becomes in an offer, or nil for one that can't be sent (files and
    /// folders until N3, and links that aren't web addresses, saved before the rule).
    static func item(for shelfItem: ShelfItem) -> Item? {
        switch shelfItem.source {
        case let .link(url):
            guard LinkInput.isWebAddress(url), url.absoluteString.utf8.count <= maxLinkBytes else { return nil }
            return .link(url)
        case let .text(text):
            guard !text.isEmpty, text.utf16.count <= ShelfItem.maxTextLength else { return nil }
            return .text(excerpt: excerpt(of: text), length: text.utf16.count)
        case .file:
            return nil
        }
    }

    static func excerpt(of text: String) -> String {
        String(text.prefix(maxExcerptLength))
    }

    /// True if `text` is the text an item with this excerpt and length promised: as
    /// long, starting with exactly those bytes, and with the excerpt cut where the
    /// sender's Polka would cut it. So a sender can't show one thing and send another.
    static func text(_ text: String, matchesExcerpt excerpt: String, length: Int) -> Bool {
        text.utf16.count == length
            && text.utf8.starts(with: excerpt.utf8)
            && excerpt.count == min(maxExcerptLength, text.count)
    }

    /// An offer as it goes on the wire, every field optional, so an offer that's
    /// missing one is refused by `validated` rather than by the JSON reader.
    struct Wire: Codable {
        struct Item: Codable {
            static let linkKind = "link"
            static let textKind = "text"

            var kind: String
            var url: String?
            var excerpt: String?
            var length: Int?
        }

        var items: [Item]
    }

    var wire: Wire {
        Wire(items: items.map { item in
            switch item {
            case let .link(url):
                return Wire.Item(kind: Wire.Item.linkKind, url: url.absoluteString)
            case let .text(excerpt, length):
                return Wire.Item(kind: Wire.Item.textKind, excerpt: excerpt, length: length)
            }
        })
    }

    /// The offer from what arrived, if it keeps every rule: 1 to `maxItems` items, each
    /// a kind this version knows; links web addresses only and at most `maxLinkBytes`;
    /// text items at most `ShelfItem.maxTextLength` long, with an excerpt that fits
    /// that length and is the whole text when it's shorter than `maxExcerptLength`.
    static func validated(_ wire: Wire) throws -> NearbyOffer {
        guard (1...maxItems).contains(wire.items.count) else { throw NearbyMessage.Failure.badOffer }
        let items = try wire.items.map { item -> Item in
            switch item.kind {
            case Wire.Item.linkKind:
                guard let string = item.url, string.utf8.count <= maxLinkBytes,
                      let url = URL(string: string), LinkInput.isWebAddress(url) else {
                    throw NearbyMessage.Failure.badOffer
                }
                return .link(url)
            case Wire.Item.textKind:
                guard let excerpt = item.excerpt, let length = item.length,
                      (1...ShelfItem.maxTextLength).contains(length),
                      !excerpt.isEmpty, excerpt.count <= maxExcerptLength,
                      excerpt.utf16.count <= length,
                      excerpt.count == maxExcerptLength || excerpt.utf16.count == length else {
                    throw NearbyMessage.Failure.badOffer
                }
                return .text(excerpt: excerpt, length: length)
            default:
                throw NearbyMessage.Failure.badOffer
            }
        }
        return NearbyOffer(items: items)
    }
}

/// One text item's whole text, sent after Accept as UTF-8 bytes (base64 in the JSON),
/// so its size on the wire is known: at most 3 bytes per UTF-16 unit, about 800 KB for
/// the longest text, under `NearbyProtocol.maxMessageBytes`.
struct NearbyText: Codable, Equatable {
    /// The item's place in the offer.
    var index: Int
    var data: Data
}

struct NearbyHello: Codable, Equatable {
    var version: Int
    /// The name the other Mac shows. Nil when it doesn't share one: a Polka that only
    /// receives from remembered Macs stays nameless to everyone else. Not verified,
    /// since anyone can call themselves anything.
    var name: String?
}

/// Cuts what arrives into whole messages: a 4-byte length, then that many bytes.
struct NearbyFrameReader {
    enum Failure: Error, Equatable {
        /// A length over `NearbyProtocol.maxMessageBytes`. The connection should close.
        case tooLarge(Int)
    }

    private var buffer = Data()

    /// Adds bytes as they arrive and returns every message now complete, in order.
    /// Bytes of a message still arriving stay until the rest comes.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= NearbyProtocol.maxMessageBytes else {
                buffer = Data()
                throw Failure.tooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            payloads.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return payloads
    }
}

/// The name a Mac shows to others, typed in Settings or sent by another Mac.
enum NearbyName {
    /// In characters as you see them, like AirDrop's.
    static let maxLength = 40
    /// Combining marks kept on one character. Real writing needs one or two; piles of
    /// them ("Zalgo" text) draw far above and below the line.
    static let maxMarksPerCharacter = 2

    /// The name as Polka shows it, or nil if nothing's left. Line breaks, tabs and runs
    /// of spaces become one space, and spaces around are trimmed. Control characters
    /// go, and so do invisible formatting characters: right-to-left overrides and
    /// isolates (which make "evil.app" read as something else), zero-width spaces and
    /// joiners, and the like.
    static func clean(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var afterSpace = true
        var marks = 0
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            switch category {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !afterSpace { scalars.append(" ") }
                afterSpace = true
                marks = 0
            case .format, .unassigned, .privateUse, .surrogate:
                continue
            case .nonspacingMark, .enclosingMark:
                guard marks < maxMarksPerCharacter, !afterSpace else { continue }
                marks += 1
                scalars.append(scalar)
            default:
                scalars.append(scalar)
                afterSpace = false
                marks = 0
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        if name.count > maxLength {
            name = String(name.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }
}

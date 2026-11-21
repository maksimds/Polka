import CryptoKit
import Foundation

/// Nearby Sharing's wire format: what two Polkas say to each other inside their TLS
/// connection. Plain Swift with no networking, so every rule about what's accepted can
/// be tested on its own. Everything read here comes from another Mac and counts as
/// hostile until it has passed these checks.
enum NearbyProtocol {
    /// This Polka's protocol version, sent in `hello`. 1 was N1's, which only said hello;
    /// 2 adds offers of links and text; 3 adds files and pictures; 4 adds remembering.
    static let version = 4
    /// The oldest version this Polka talks to. There's no older, weaker one to fall back to.
    static let minimumVersion = 1
    /// The oldest version that takes offers. A Mac on version 1 is found, but can't be
    /// sent to.
    static let offerVersion = 2
    /// The oldest version that takes files, previews, data pieces and `cancel`. A Mac on
    /// version 2 is only ever sent links and text, with no pictures.
    static let fileVersion = 3
    /// The oldest version that remembers Macs (`remember` and what follows it).
    static let rememberVersion = 4
    /// The Bonjour service type. It's also listed under `NSBonjourServices` in
    /// `Polka-Info.plist`, without which macOS doesn't let Polka use it.
    static let serviceType = "_polka._tcp"
    /// The TLS application protocol (ALPN), so a connection that isn't Polka's fails
    /// in the handshake, before any message is read.
    static let applicationProtocol = "polka/1"
    /// The largest message, checked from its length before any memory is set aside.
    static let maxMessageBytes = 1_000_000
    /// The largest piece of a file, sent as raw bytes rather than JSON.
    static let maxPieceBytes = 262_144
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
    /// From the Mac sharing, right after the offer: one item's picture, as the offer
    /// announced it would send.
    case preview(NearbyPreview)
    /// From the Mac sharing, after Accept: one text item's whole text.
    case text(NearbyText)
    /// From the Mac sharing, after a file's last piece: its SHA-256, worked out as it
    /// was read, for the other Mac to check what it wrote against.
    case fileEnd(NearbyFileEnd)
    /// From the Mac sharing: everything has been sent. From the Mac receiving: it's all
    /// on the shelf.
    case done
    /// From either side, once the offer is made, or once remembering has begun: the
    /// person there stopped it.
    case cancel
    /// From a Mac that wants to remember this one, right after the hellos, in place of
    /// an offer. Answered with `rememberCommit`, or `decline`.
    case remember
    /// From the Mac asked to remember: the SHA-256 of its random number, sent before
    /// it sees the other's (`NearbyRememberCode`).
    case rememberCommit(Data)
    /// Each Mac's random number: the asking Mac's first, then the asked Mac's.
    case rememberNonce(Data)
    /// The person at the Mac sending it pressed Codes Match.
    case rememberConfirm

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
        /// A preview or file end for an item that can't exist, or that's malformed.
        case badItem
        /// A commitment or random number that isn't exactly 32 bytes.
        case badRemember
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
        case Envelope.previewType:
            guard let preview = envelope.preview else { throw Failure.unreadable }
            guard (0..<NearbyOffer.maxItems).contains(preview.index),
                  NearbyPreviewImage.isAcceptable(preview.png) else { throw Failure.badItem }
            return .preview(preview)
        case Envelope.fileEndType:
            guard let end = envelope.fileEnd else { throw Failure.unreadable }
            guard (0..<NearbyOffer.maxItems).contains(end.index),
                  end.sha256.count == NearbyFileEnd.hashBytes else { throw Failure.badItem }
            return .fileEnd(end)
        case Envelope.doneType:
            return .done
        case Envelope.cancelType:
            return .cancel
        case Envelope.rememberType:
            return .remember
        case Envelope.rememberCommitType:
            guard let commitment = envelope.commitment else { throw Failure.unreadable }
            guard commitment.count == SHA256Digest.byteCount else { throw Failure.badRemember }
            return .rememberCommit(commitment)
        case Envelope.rememberNonceType:
            guard let nonce = envelope.nonce else { throw Failure.unreadable }
            guard nonce.count == NearbyRememberCode.nonceBytes else { throw Failure.badRemember }
            return .rememberNonce(nonce)
        case Envelope.rememberConfirmType:
            return .rememberConfirm
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
        static let previewType = "preview"
        static let fileEndType = "fileEnd"
        static let doneType = "done"
        static let cancelType = "cancel"
        static let rememberType = "remember"
        static let rememberCommitType = "rememberCommit"
        static let rememberNonceType = "rememberNonce"
        static let rememberConfirmType = "rememberConfirm"

        var type: String
        var hello: NearbyHello?
        var offer: NearbyOffer.Wire?
        var text: NearbyText?
        var preview: NearbyPreview?
        var fileEnd: NearbyFileEnd?
        var commitment: Data?
        var nonce: Data?

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
            case let .preview(preview):
                type = Self.previewType
                self.preview = preview
            case let .fileEnd(end):
                type = Self.fileEndType
                fileEnd = end
            case .done:
                type = Self.doneType
            case .cancel:
                type = Self.cancelType
            case .remember:
                type = Self.rememberType
            case let .rememberCommit(commitment):
                type = Self.rememberCommitType
                self.commitment = commitment
            case let .rememberNonce(nonce):
                type = Self.rememberNonceType
                self.nonce = nonce
            case .rememberConfirm:
                type = Self.rememberConfirmType
            }
        }
    }
}

/// What a Mac wants to share: links, text and files. A link is just its web address, a
/// text item only its start and length until the offer is accepted, and a file its name
/// and size. Nothing a tile was renamed to is sent: the receiving Mac names everything
/// itself, as Polka does for anything new.
struct NearbyOffer: Equatable {
    static let maxItems = 50
    /// The most one offer may hold, all files together (NS-5), in bytes as Finder
    /// counts them.
    static let maxTotalBytes: Int64 = 1_000_000_000
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
        /// A file's name, cleaned by `NearbyFileName.clean` on arrival, and its size in
        /// bytes, which is exactly how many will be sent.
        case file(name: String, size: Int64)
    }

    var items: [Item]
    /// The places of the items whose picture follows the offer, each in a `preview`
    /// message. Only files and links have one.
    var previews: Set<Int> = []

    /// What the files add up to.
    var totalFileBytes: Int64 {
        items.reduce(0) { total, item in
            if case let .file(_, size) = item { return total + size }
            return total
        }
    }

    var hasFiles: Bool {
        items.contains { if case .file = $0 { return true } else { return false } }
    }

    /// What a link or text tile becomes in an offer, or nil for one that can't be sent
    /// this way: files, which `NearbyOutgoingItem.prepare` reads from disk, folders, and
    /// links that aren't web addresses, saved before the rule.
    static func item(for shelfItem: ShelfItem) -> Item? {
        switch shelfItem.source {
        case let .link(url):
            guard LinkInput.isWebAddress(url), url.absoluteString.utf8.count <= maxLinkBytes else { return nil }
            return .link(url)
        case let .text(text):
            guard !text.isEmpty, text.utf16.count <= ShelfItem.maxTextLength else { return nil }
            return .text(excerpt: excerpt(of: text), length: text.utf16.count)
        case .file, .shelfFolder:
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
            static let fileKind = "file"

            var kind: String
            var url: String?
            var excerpt: String?
            var length: Int?
            var name: String?
            var size: Int64?
        }

        var items: [Item]
        /// Missing from version 2's offers, which have no pictures.
        var previews: [Int]?
    }

    var wire: Wire {
        Wire(items: items.map { item in
            switch item {
            case let .link(url):
                return Wire.Item(kind: Wire.Item.linkKind, url: url.absoluteString)
            case let .text(excerpt, length):
                return Wire.Item(kind: Wire.Item.textKind, excerpt: excerpt, length: length)
            case let .file(name, size):
                return Wire.Item(kind: Wire.Item.fileKind, name: name, size: size)
            }
        }, previews: previews.isEmpty ? nil : previews.sorted())
    }

    /// The offer from what arrived, if it keeps every rule: 1 to `maxItems` items, each
    /// a kind this version knows; links web addresses only and at most `maxLinkBytes`;
    /// text items at most `ShelfItem.maxTextLength` long, with an excerpt that fits
    /// that length and is the whole text when it's shorter than `maxExcerptLength`;
    /// files named (the name is cleaned here) and all together at most `maxTotalBytes`;
    /// pictures announced only for files and links, each once.
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
            case Wire.Item.fileKind:
                guard let name = item.name, let size = item.size,
                      (0...maxTotalBytes).contains(size) else {
                    throw NearbyMessage.Failure.badOffer
                }
                return .file(name: NearbyFileName.clean(name), size: size)
            default:
                throw NearbyMessage.Failure.badOffer
            }
        }
        var offer = NearbyOffer(items: items)
        guard offer.totalFileBytes <= maxTotalBytes else { throw NearbyMessage.Failure.badOffer }
        let previews = wire.previews ?? []
        guard Set(previews).count == previews.count,
              previews.allSatisfy({ items.indices.contains($0) && !items[$0].isText }) else {
            throw NearbyMessage.Failure.badOffer
        }
        offer.previews = Set(previews)
        return offer
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

/// One item's picture, sent right after the offer: a PNG of at most 256 × 256 px and
/// 128 KB (`NearbyPreviewImage`), checked by its bytes on arrival but not decoded.
struct NearbyPreview: Codable, Equatable {
    var index: Int
    var png: Data
}

/// The end of one file: the SHA-256 of the bytes sent for it.
struct NearbyFileEnd: Codable, Equatable {
    static let hashBytes = 32

    var index: Int
    var sha256: Data
}

struct NearbyHello: Codable, Equatable {
    var version: Int
    /// The name the other Mac shows. Nil when it doesn't share one: a Polka that only
    /// receives from remembered Macs stays nameless to everyone else. Not verified,
    /// since anyone can call themselves anything.
    var name: String?
}

/// What arrives, cut into whole frames.
enum NearbyFrame: Equatable {
    /// A message's JSON, for `NearbyMessage.decode`.
    case message(Data)
    /// A piece of the file being sent, as raw bytes.
    case piece(Data)

    /// The first length byte's top bit marks a piece. A message is never longer than
    /// `NearbyProtocol.maxMessageBytes`, so its length never sets that bit, and a
    /// version 2 Polka, which is never sent a piece, would refuse one as too long.
    static let pieceFlag: UInt32 = 0x8000_0000

    /// A message's JSON, or nil for a piece.
    var message: Data? {
        if case let .message(payload) = self { return payload }
        return nil
    }

    /// A piece as it goes on the wire: its length with the top bit set, then the bytes.
    static func pieceFrame(_ bytes: Data) -> Data {
        let count = UInt32(bytes.count) | pieceFlag
        var frame = Data([UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
                          UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
        frame.append(bytes)
        return frame
    }
}

/// Cuts what arrives into whole frames: a 4-byte length, then that many bytes. A
/// message is JSON; a length with its top bit set is a piece of a file.
struct NearbyFrameReader {
    enum Failure: Error, Equatable {
        /// A length over `NearbyProtocol.maxMessageBytes` (or, for a piece,
        /// `maxPieceBytes`). The connection should close.
        case tooLarge(Int)
    }

    private var buffer = Data()
    /// Where the unread bytes start in `buffer`, so each frame taken doesn't copy
    /// everything after it.
    private var start = 0

    /// Adds bytes as they arrive and returns every frame now complete, in order.
    /// Bytes of a frame still arriving stay until the rest comes.
    mutating func append(_ data: Data) throws -> [NearbyFrame] {
        buffer.append(data)
        var frames: [NearbyFrame] = []
        while buffer.count - start >= 4 {
            let header = buffer[buffer.startIndex + start ..< buffer.startIndex + start + 4]
            let raw = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let isPiece = raw & NearbyFrame.pieceFlag != 0
            let length = Int(raw & ~NearbyFrame.pieceFlag)
            let limit = isPiece ? NearbyProtocol.maxPieceBytes : NearbyProtocol.maxMessageBytes
            guard length <= limit else {
                buffer = Data()
                start = 0
                throw Failure.tooLarge(isPiece ? Int(raw) : length)
            }
            guard buffer.count - start >= 4 + length else { break }
            let bodyStart = buffer.startIndex + start + 4
            let body = Data(buffer[bodyStart ..< bodyStart + length])
            frames.append(isPiece ? .piece(body) : .message(body))
            start += 4 + length
        }
        if start == buffer.count {
            buffer = Data()
            start = 0
        } else if start > 1_048_576 {
            buffer = Data(buffer[(buffer.startIndex + start)...])
            start = 0
        }
        return frames
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

import Foundation

/// Nearby Sharing's wire format: what two Polkas say to each other inside their TLS
/// connection. Plain Swift with no networking, so every rule about what's accepted can
/// be tested on its own. Everything read here comes from another Mac and counts as
/// hostile until it has passed these checks.
enum NearbyProtocol {
    /// This Polka's protocol version, sent in `hello`.
    static let version = 1
    /// The oldest version this Polka talks to. There's no older, weaker one to fall back to.
    static let minimumVersion = 1
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

    enum Failure: Error, Equatable {
        /// Not JSON, or not the shape Polka writes.
        case unreadable
        /// A `type` this version doesn't know.
        case unknownType
        /// Older than `NearbyProtocol.minimumVersion`.
        case tooOld(Int)
        /// A name with nothing left once it's cleaned.
        case badName
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
        default:
            throw Failure.unknownType
        }
    }

    private struct Envelope: Codable {
        static let helloType = "hello"

        var type: String
        var hello: NearbyHello?

        init(_ message: NearbyMessage) {
            switch message {
            case let .hello(hello):
                type = Self.helloType
                self.hello = hello
            }
        }
    }
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

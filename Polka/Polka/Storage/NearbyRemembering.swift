import CryptoKit
import Foundation

/// A Mac remembered for Nearby Sharing (NS-11, NS-13): its tiles arrive without an
/// offer card. It's its public key, never its name; the name is only what it's shown as.
struct NearbyRememberedMac: Codable, Equatable, Identifiable {
    /// The key in X9.63 form, as its TLS certificate carries it, compared whole.
    var publicKey: Data
    /// What this Mac shows it as: the name it had when it was remembered, then any new
    /// name it gives, unless another remembered Mac already goes by that name.
    var name: String
    var rememberedAt: Date

    var id: Data { publicKey }

    /// A P-256 public key, uncompressed: 65 bytes starting with 4, the only kind Polka
    /// makes.
    static func isValidKey(_ key: Data) -> Bool {
        key.count == 65 && key.first == 0x04
    }
}

/// The Macs remembered on this Mac, and the rules for changing the list. Plain Swift,
/// read from and written to `remembered-macs.json` in Polka's folder.
struct NearbyRememberedList: Equatable {
    /// Far more than anyone works with. Remembering one more forgets the oldest.
    static let maxCount = 100
    static let formatVersion = 1

    /// In the order they were remembered.
    private(set) var macs: [NearbyRememberedMac] = []

    init(macs: [NearbyRememberedMac] = []) {
        for mac in macs {
            guard NearbyRememberedMac.isValidKey(mac.publicKey), let name = NearbyName.clean(mac.name),
                  !self.macs.contains(where: { $0.publicKey == mac.publicKey }) else { continue }
            self.macs.append(NearbyRememberedMac(publicKey: mac.publicKey, name: name, rememberedAt: mac.rememberedAt))
        }
        if self.macs.count > Self.maxCount { self.macs.removeFirst(self.macs.count - Self.maxCount) }
    }

    func mac(for key: Data?) -> NearbyRememberedMac? {
        guard let key else { return nil }
        return macs.first { $0.publicKey == key }
    }

    func contains(_ key: Data?) -> Bool {
        mac(for: key) != nil
    }

    /// A remembered Mac, other than `key`'s, whose name looks like `name`.
    func mac(named name: String, except key: Data? = nil) -> NearbyRememberedMac? {
        let wanted = NearbyName.lookalikeKey(name)
        return macs.first { $0.publicKey != key && NearbyName.lookalikeKey($0.name) == wanted }
    }

    /// Remembers a Mac, or remembers it again under the name it gives now.
    mutating func remember(_ key: Data, name: String, at date: Date) {
        guard NearbyRememberedMac.isValidKey(key), let name = NearbyName.clean(name) else { return }
        macs.removeAll { $0.publicKey == key }
        macs.append(NearbyRememberedMac(publicKey: key, name: name, rememberedAt: date))
        if macs.count > Self.maxCount { macs.removeFirst(macs.count - Self.maxCount) }
    }

    @discardableResult
    mutating func forget(_ key: Data) -> Bool {
        let count = macs.count
        macs.removeAll { $0.publicKey == key }
        return macs.count != count
    }

    /// A remembered Mac gave a new name: it's shown by it from now on. Not when another
    /// remembered Mac goes by that name, or one that looks like it, so one colleague
    /// can't rename their Mac after another's and send as them. True if it changed.
    @discardableResult
    mutating func rename(_ key: Data, to newName: String) -> Bool {
        guard let index = macs.firstIndex(where: { $0.publicKey == key }),
              let name = NearbyName.clean(newName), name != macs[index].name,
              mac(named: name, except: key) == nil else { return false }
        macs[index].name = name
        return true
    }

    // MARK: - The file

    private struct File: Codable {
        var version: Int
        var macs: [NearbyRememberedMac]
    }

    /// The list in `url`. A missing or unreadable file is an empty list, and entries
    /// that don't hold a valid key and a name are left out: nothing is trusted that
    /// Polka didn't write.
    static func load(from url: URL) -> NearbyRememberedList {
        guard let data = try? Data(contentsOf: url) else { return NearbyRememberedList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return NearbyRememberedList() }
        return NearbyRememberedList(macs: file.macs)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: Self.formatVersion, macs: macs))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension NearbyName {
    /// What a name reads as, for telling whether two names would be taken for each
    /// other: other scripts written in Latin letters (a Cyrillic "а" is an "a"), without
    /// accents, case or full-width forms.
    static func lookalikeKey(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        return latin.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The 6-digit code two people compare to remember each other's Macs, and the promise
/// that keeps a middleman from choosing it.
///
/// A code made from the TLS session alone could be steered: a middleman answering one
/// of the two connections picks his half of the key exchange after seeing the caller's,
/// and could try new halves until the two screens' codes matched. So each side also
/// adds a random number. The Mac that was asked commits to its number first, sending
/// only its hash; the asking Mac then sends its number; the first Mac then shows its
/// own, and the asking Mac checks it against the hash. Neither side can change its
/// number after seeing the other's, so a middleman gets one guess in a million.
enum NearbyRememberCode {
    static let nonceBytes = 32
    /// What's asked of the TLS session's exporter (RFC 8446, section 7.5).
    static let exporterLabel = "EXPORTER-polka-remember"
    static let exporterBytes = 32

    static func newNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The hash the asked Mac sends in place of its number, bound to its key.
    static func commitment(to nonce: Data, by key: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("polka-remember-commitment".utf8))
        hash.update(data: key)
        hash.update(data: nonce)
        return Data(hash.finalize())
    }

    /// "131 485": from the session's exporter, both keys and both numbers, each in a
    /// fixed place, so both Macs work out the same digits and a middleman, who has two
    /// sessions, gets different ones.
    static func code(exporter: Data, askingKey: Data, askedKey: Data,
                     askingNonce: Data, askedNonce: Data) -> String {
        var hash = SHA256()
        hash.update(data: Data("polka-remember-code".utf8))
        hash.update(data: exporter)
        hash.update(data: askingKey)
        hash.update(data: askedKey)
        hash.update(data: askingNonce)
        hash.update(data: askedNonce)
        let number = Data(hash.finalize()).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        return String(format: "%03d %03d", Int(number / 1000), Int(number % 1000))
    }
}

/// Remembering, step by step, for either Mac (NS-11). Plain Swift, so every hostile
/// order of messages can be tested without a network.
///
/// The asking Mac says hello, hears the other's hello and asks (`remember`). The asked
/// Mac, if its person is waiting for this, answers with its commitment, or declines.
/// Then the numbers cross, the asking Mac's first, and both show the code. Each person
/// presses Codes Match (`rememberConfirm`), and once a Mac has both its own person's
/// and the other's, it remembers the other.
struct NearbyRememberExchange {
    enum Role: Equatable {
        case asking
        case asked
    }

    enum Stage: Equatable {
        /// Asking: waiting for the other Mac's hello.
        case hello
        /// Asking: asked; waiting for the commitment.
        case commitment
        /// Waiting for the other Mac's number.
        case nonce
        /// Both screens show the code; waiting for both people.
        case comparing
        case finished
    }

    enum Failure: Error, Equatable {
        case outOfTurn
        /// Its Polka can't remember Macs.
        case tooOld
        /// It didn't say who it is.
        case nameless
        /// Its person isn't waiting to remember a Mac, or it's busy with another.
        case notReady
        /// Its number doesn't match the hash it sent first.
        case brokenPromise
        /// The TLS session gave no key or exporter to bind the code to.
        case unbound
        /// The person there pressed Cancel.
        case cancelled
    }

    enum Event: Equatable {
        case nothing
        /// Show this code.
        case code(String)
        /// Both people confirmed: remember the other Mac.
        case remembered
    }

    /// What ties the code to this TLS session.
    struct Binding: Equatable {
        let exporter: Data
        let ownKey: Data
        let theirKey: Data
    }

    let role: Role
    private(set) var stage: Stage
    /// The name the other Mac gave. Not verified until the codes match.
    private(set) var theirName: String?
    private(set) var code: String?
    private(set) var confirmedHere = false
    private(set) var confirmedThere = false
    private let nonce: Data
    private var binding: Binding?
    private var theirCommitment: Data?

    private init(role: Role, stage: Stage, nonce: Data, binding: Binding?, theirName: String?) {
        self.role = role
        self.stage = stage
        self.nonce = nonce
        self.binding = binding
        self.theirName = theirName
    }

    /// The asking side, before anything is said. `connected` gives it the session once
    /// the TLS handshake is done.
    static func asking(nonce: Data = NearbyRememberCode.newNonce()) -> NearbyRememberExchange {
        NearbyRememberExchange(role: .asking, stage: .hello, nonce: nonce, binding: nil, theirName: nil)
    }

    /// The asked side, once the hellos and the request are in: what to send first is
    /// the commitment.
    static func asked(by name: String, binding: Binding,
                      nonce: Data = NearbyRememberCode.newNonce()) -> (NearbyRememberExchange, NearbyMessage) {
        let exchange = NearbyRememberExchange(role: .asked, stage: .nonce, nonce: nonce, binding: binding,
                                              theirName: name)
        return (exchange, .rememberCommit(NearbyRememberCode.commitment(to: nonce, by: binding.ownKey)))
    }

    mutating func connected(_ binding: Binding) {
        guard role == .asking, stage == .hello else { return }
        self.binding = binding
    }

    /// Reads one message from the other Mac, and returns what to send back.
    mutating func read(_ message: NearbyMessage) throws -> (event: Event, send: [NearbyMessage]) {
        if case .cancel = message, stage != .hello, stage != .finished {
            stage = .finished
            throw Failure.cancelled
        }
        switch (role, stage, message) {
        case let (.asking, .hello, .hello(hello)):
            guard hello.version >= NearbyProtocol.rememberVersion else { throw finish(.tooOld) }
            guard let name = hello.name else { throw finish(.nameless) }
            theirName = name
            stage = .commitment
            return (.nothing, [.remember])
        case let (.asking, .commitment, .rememberCommit(commitment)):
            theirCommitment = commitment
            stage = .nonce
            return (.nothing, [.rememberNonce(nonce)])
        case (.asking, .commitment, .decline):
            throw finish(.notReady)
        case let (.asking, .nonce, .rememberNonce(theirNonce)):
            guard let binding else { throw finish(.unbound) }
            guard NearbyRememberCode.commitment(to: theirNonce, by: binding.theirKey) == theirCommitment else {
                throw finish(.brokenPromise)
            }
            return (show(NearbyRememberCode.code(exporter: binding.exporter, askingKey: binding.ownKey,
                                                 askedKey: binding.theirKey, askingNonce: nonce,
                                                 askedNonce: theirNonce)), [])
        case let (.asked, .nonce, .rememberNonce(theirNonce)):
            guard let binding else { throw finish(.unbound) }
            let code = NearbyRememberCode.code(exporter: binding.exporter, askingKey: binding.theirKey,
                                               askedKey: binding.ownKey, askingNonce: theirNonce,
                                               askedNonce: nonce)
            return (show(code), [.rememberNonce(nonce)])
        case (_, .comparing, .rememberConfirm):
            guard !confirmedThere else { throw finish(.outOfTurn) }
            confirmedThere = true
            return (bothConfirmed(), [])
        default:
            throw finish(.outOfTurn)
        }
    }

    /// The person here pressed Codes Match: what to send, or nil if there's no code to
    /// confirm.
    mutating func confirm() -> (event: Event, send: [NearbyMessage])? {
        guard stage == .comparing, !confirmedHere else { return nil }
        confirmedHere = true
        return (bothConfirmed(), [.rememberConfirm])
    }

    /// The person here pressed Cancel: what to tell the other Mac, if anything.
    mutating func cancel() -> NearbyMessage? {
        defer { stage = .finished }
        switch stage {
        case .commitment, .nonce, .comparing: return .cancel
        case .hello, .finished: return nil
        }
    }

    private mutating func show(_ code: String) -> Event {
        self.code = code
        stage = .comparing
        return .code(code)
    }

    private mutating func bothConfirmed() -> Event {
        guard confirmedHere && confirmedThere else { return .nothing }
        stage = .finished
        return .remembered
    }

    private mutating func finish(_ failure: Failure) -> Failure {
        stage = .finished
        return failure
    }
}

/// Why remembering a Mac didn't work, as the Remember sheet says it.
enum NearbyRememberFailure: Equatable {
    /// Its Remember window isn't open, or it's busy remembering another Mac.
    case notReady
    /// Its person pressed Cancel.
    case cancelledByThem
    /// It couldn't be reached, or the connection dropped.
    case unreachable
    /// Its Polka is too old to remember Macs.
    case tooOld
    /// Something didn't check out: another key answered, a number that broke its
    /// promise, a message out of turn.
    case notVerified
    /// Not confirmed in time.
    case timedOut
}

/// Where remembering stands, for the Remember sheet. Nil while the sheet is closed.
enum NearbyRememberPhase: Equatable {
    /// Listing the Macs nearby, and taking a request from one of them.
    case looking
    /// The 2 minutes passed; no requests are taken until Try Again.
    case stoppedLooking
    /// Asking a Mac, or asked by one, before the code shows.
    case connecting(name: String, askedByThem: Bool)
    case comparing(name: String, code: String, askedByThem: Bool, confirmedHere: Bool)
    case remembered(name: String)
    case failed(name: String, NearbyRememberFailure)
}

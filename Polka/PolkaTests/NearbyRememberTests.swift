import Foundation
import Testing
@testable import Polka

/// A P-256 public key's shape, filled with one byte.
private func key(_ byte: UInt8) -> Data {
    Data([0x04] + Array(repeating: byte, count: 64))
}

private func nonce(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: NearbyRememberCode.nonceBytes)
}

private func shelfItem(_ source: ShelfItem.Source) -> ShelfItem {
    let kind: ShelfItem.Kind
    switch source {
    case .link: kind = .link
    case .text: kind = .text
    case .file: kind = .file
    case .shelfFolder: kind = .shelfFolder
    }
    return ShelfItem(id: UUID(), kind: kind, title: "Item", source: source, storageMode: .reference,
                     createdAt: Date(), sortOrder: 0)
}

/// The list of remembered Macs, and its file.
struct NearbyRememberedListTests {
    @Test func aRememberedMacIsFoundByItsWholeKey() {
        var list = NearbyRememberedList()
        list.remember(key(1), name: "Alex", at: Date())
        #expect(list.contains(key(1)))
        #expect(!list.contains(key(2)))
        // A key that only starts the same is another Mac.
        var almost = key(1)
        almost[64] = 9
        #expect(!list.contains(almost))
        #expect(!list.contains(nil))
    }

    @Test func rememberingAgainKeepsOneEntryUnderTheNewName() {
        var list = NearbyRememberedList()
        list.remember(key(1), name: "Alex", at: Date(timeIntervalSince1970: 0))
        list.remember(key(1), name: "Alex's MacBook", at: Date(timeIntervalSince1970: 10))
        #expect(list.macs.count == 1)
        #expect(list.macs.first?.name == "Alex's MacBook")
        #expect(list.macs.first?.rememberedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func forgetTakesItOffAtOnce() {
        var list = NearbyRememberedList()
        list.remember(key(1), name: "Alex", at: Date())
        list.remember(key(2), name: "Sam", at: Date())
        let forgot = list.forget(key(1))
        #expect(forgot)
        #expect(!list.contains(key(1)))
        #expect(list.contains(key(2)))
        let forgotAgain = list.forget(key(1))
        #expect(!forgotAgain)
    }

    @Test func onlyRealKeysAndNamesAreKept() {
        var list = NearbyRememberedList()
        list.remember(Data(repeating: 4, count: 64), name: "Short key", at: Date())
        list.remember(Data([0x02] + Array(repeating: 1, count: 64)), name: "Compressed key", at: Date())
        list.remember(key(1), name: " \u{202E} ", at: Date())
        #expect(list.macs.isEmpty)
        list.remember(key(2), name: "  Sam\u{200B}  ", at: Date())
        #expect(list.macs.first?.name == "Sam")
    }

    @Test func theOldestIsForgottenPastTheLimit() {
        var list = NearbyRememberedList()
        for index in 0...NearbyRememberedList.maxCount {
            list.remember(key(UInt8(index)), name: "Mac \(index)", at: Date())
        }
        #expect(list.macs.count == NearbyRememberedList.maxCount)
        #expect(!list.contains(key(0)))
        #expect(list.contains(key(UInt8(NearbyRememberedList.maxCount))))
    }

    @Test func aNewNameIsTakenUnlessAnotherRememberedMacGoesByIt() {
        var list = NearbyRememberedList()
        list.remember(key(1), name: "Alex", at: Date())
        list.remember(key(2), name: "Bob", at: Date())
        let renamed = list.rename(key(2), to: "Bob's MacBook")
        #expect(renamed)
        #expect(list.mac(for: key(2))?.name == "Bob's MacBook")
        // Not Alex's name, in any case, with accents, or in look-alike letters.
        for name in ["Alex", "ALEX", "Àlex", "\u{410}lex"] {
            let taken = list.rename(key(2), to: name)
            #expect(!taken, "\(name)")
        }
        #expect(list.mac(for: key(2))?.name == "Bob's MacBook")
        // The same name, or one with nothing left once cleaned, changes nothing.
        let same = list.rename(key(2), to: "Bob's MacBook")
        let empty = list.rename(key(2), to: "\u{202E}")
        let unknown = list.rename(key(3), to: "Carol")
        #expect(!same && !empty && !unknown)
        // A Mac may change the case of its own name.
        let ownCase = list.rename(key(1), to: "ALEX")
        #expect(ownCase)
    }

    @Test func theListSurvivesItsFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PolkaRemembered-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("remembered-macs.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var list = NearbyRememberedList()
        list.remember(key(1), name: "Алекс", at: Date(timeIntervalSince1970: 1_800_000_000))
        list.remember(key(2), name: "Sam", at: Date(timeIntervalSince1970: 1_800_000_100))
        try list.save(to: file)
        #expect(NearbyRememberedList.load(from: file) == list)
    }

    @Test func aMissingOrDamagedFileIsAnEmptyList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaRemembered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(NearbyRememberedList.load(from: folder.appendingPathComponent("none.json")).macs.isEmpty)
        let damaged = folder.appendingPathComponent("damaged.json")
        try Data("{\"version\":1,\"macs\":[{".utf8).write(to: damaged)
        #expect(NearbyRememberedList.load(from: damaged).macs.isEmpty)
    }

    @Test func entriesPolkaDidntWriteAreLeftOut() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaRemembered-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let good = key(1).base64EncodedString()
        let json = """
            {"version":1,"macs":[
              {"publicKey":"\(good)","name":"Alex","rememberedAt":"2026-11-20T10:00:00Z"},
              {"publicKey":"\(good)","name":"Alex again","rememberedAt":"2026-11-20T10:00:00Z"},
              {"publicKey":"\(Data([1, 2, 3]).base64EncodedString())","name":"Short","rememberedAt":"2026-11-20T10:00:00Z"},
              {"publicKey":"\(key(2).base64EncodedString())","name":"\\u202e","rememberedAt":"2026-11-20T10:00:00Z"}
            ]}
            """
        try Data(json.utf8).write(to: file)
        let list = NearbyRememberedList.load(from: file)
        #expect(list.macs.map(\.name) == ["Alex"])
    }
}

/// The code two people compare, and the promise behind it.
struct NearbyRememberCodeTests {
    private func code(exporter: UInt8 = 1, asking: UInt8 = 2, asked: UInt8 = 3,
                      askingNonce: UInt8 = 4, askedNonce: UInt8 = 5) -> String {
        NearbyRememberCode.code(exporter: Data(repeating: exporter, count: 32), askingKey: key(asking),
                                askedKey: key(asked), askingNonce: nonce(askingNonce), askedNonce: nonce(askedNonce))
    }

    @Test func theCodeIsSixDigitsInTwoGroups() throws {
        let shown = code()
        let regex = try Regex("^[0-9]{3} [0-9]{3}$")
        #expect(shown.wholeMatch(of: regex) != nil)
        #expect(code() == shown)
    }

    @Test func everyPartChangesTheCode() {
        let shown = code()
        #expect(code(exporter: 9) != shown)
        #expect(code(asking: 9) != shown)
        #expect(code(asked: 9) != shown)
        #expect(code(askingNonce: 9) != shown)
        #expect(code(askedNonce: 9) != shown)
        // Each part has its place: swapping the two Macs changes it too.
        #expect(code(asking: 3, asked: 2) != shown)
    }

    @Test func aCommitmentHoldsItsNumberAndKey() {
        let made = NearbyRememberCode.commitment(to: nonce(1), by: key(1))
        #expect(made.count == 32)
        #expect(NearbyRememberCode.commitment(to: nonce(1), by: key(1)) == made)
        #expect(NearbyRememberCode.commitment(to: nonce(2), by: key(1)) != made)
        #expect(NearbyRememberCode.commitment(to: nonce(1), by: key(2)) != made)
    }

    @Test func newNumbersAre32RandomBytes() {
        let first = NearbyRememberCode.newNonce()
        #expect(first.count == 32)
        #expect(NearbyRememberCode.newNonce() != first)
    }
}

/// Remembering step by step, both sides, with messages in every wrong order.
struct NearbyRememberExchangeTests {
    private let exporter = Data(repeating: 7, count: 32)
    private let askingKey = key(1)
    private let askedKey = key(2)
    private let hello = NearbyHello(version: NearbyProtocol.version, name: "Sam")

    /// The asking side, connected and having heard the asked side's hello, with what it
    /// sent back; and the asked side, with its commitment.
    private func started(askedNonce: Data = nonce(5)) throws -> (asking: NearbyRememberExchange,
                                                                 asked: NearbyRememberExchange,
                                                                 commitment: NearbyMessage) {
        var asking = NearbyRememberExchange.asking(nonce: nonce(4))
        asking.connected(.init(exporter: exporter, ownKey: askingKey, theirKey: askedKey))
        let step = try asking.read(.hello(hello))
        #expect(step.send == [.remember])
        let (asked, commitment) = NearbyRememberExchange.asked(
            by: "Alex", binding: .init(exporter: exporter, ownKey: askedKey, theirKey: askingKey), nonce: askedNonce)
        return (asking, asked, commitment)
    }

    /// Both sides through to the code.
    private func comparing() throws -> (asking: NearbyRememberExchange, asked: NearbyRememberExchange) {
        var (asking, asked, commitment) = try started()
        let askingNonce = try asking.read(commitment).send
        #expect(askingNonce == [.rememberNonce(nonce(4))])
        let answer = try asked.read(askingNonce[0])
        #expect(answer.send == [.rememberNonce(nonce(5))])
        let shown = try asking.read(answer.send[0])
        #expect(shown.event == answer.event)
        return (asking, asked)
    }

    @Test func bothSidesShowTheSameCodeAndRememberOnlyOnceBothConfirm() throws {
        var (asking, asked) = try comparing()
        let expected = NearbyRememberCode.code(exporter: exporter, askingKey: askingKey, askedKey: askedKey,
                                               askingNonce: nonce(4), askedNonce: nonce(5))
        #expect(asking.code == expected)
        #expect(asked.code == expected)
        #expect(asking.theirName == "Sam")
        #expect(asked.theirName == "Alex")

        let first = asking.confirm()
        #expect(first?.event == .nothing)
        #expect(first?.send == [.rememberConfirm])
        let again = asking.confirm()
        #expect(again == nil)
        let heard = try asked.read(.rememberConfirm)
        #expect(heard.event == .nothing)
        let second = asked.confirm()
        #expect(second?.event == .remembered)
        let both = try asking.read(.rememberConfirm)
        #expect(both.event == .remembered)
        #expect(asking.stage == .finished)
        #expect(asked.stage == .finished)
    }

    @Test func aNumberThatBreaksItsPromiseIsRefused() throws {
        var (asking, _, commitment) = try started()
        _ = try asking.read(commitment)
        // The asked side, or a middleman, shows another number than it promised.
        #expect(throws: NearbyRememberExchange.Failure.brokenPromise) {
            try asking.read(.rememberNonce(nonce(6)))
        }
        #expect(asking.code == nil)
    }

    @Test func aPromiseMadeWithAnotherKeyIsRefused() throws {
        var (asking, _, _) = try started()
        _ = try asking.read(.rememberCommit(NearbyRememberCode.commitment(to: nonce(5), by: key(9))))
        #expect(throws: NearbyRememberExchange.Failure.brokenPromise) {
            try asking.read(.rememberNonce(nonce(5)))
        }
    }

    @Test func aDeclineMeansTheyreNotReady() throws {
        var (asking, _, _) = try started()
        #expect(throws: NearbyRememberExchange.Failure.notReady) { try asking.read(.decline) }
    }

    @Test func anOlderPolkaOrANamelessOneCantBeAsked() {
        var old = NearbyRememberExchange.asking()
        #expect(throws: NearbyRememberExchange.Failure.tooOld) {
            try old.read(.hello(NearbyHello(version: NearbyProtocol.fileVersion, name: "Sam")))
        }
        var nameless = NearbyRememberExchange.asking()
        #expect(throws: NearbyRememberExchange.Failure.nameless) {
            try nameless.read(.hello(NearbyHello(version: NearbyProtocol.version, name: nil)))
        }
    }

    @Test func withoutTheSessionTheresNoCode() throws {
        var asking = NearbyRememberExchange.asking(nonce: nonce(4))
        _ = try asking.read(.hello(hello))
        _ = try asking.read(.rememberCommit(NearbyRememberCode.commitment(to: nonce(5), by: askedKey)))
        #expect(throws: NearbyRememberExchange.Failure.unbound) { try asking.read(.rememberNonce(nonce(5))) }
    }

    @Test func messagesOutOfTurnAreRefused() throws {
        // The asking side: a number before the promise, a confirm before the code.
        var (asking, asked, _) = try started()
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) { try asking.read(.rememberNonce(nonce(5))) }
        (asking, asked, _) = try started()
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) { try asking.read(.rememberConfirm) }
        // The asked side: a confirm before the numbers, a second promise, an offer.
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) { try asked.read(.rememberConfirm) }
        (_, asked, _) = try started()
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) {
            try asked.read(.rememberCommit(Data(repeating: 1, count: 32)))
        }
        (_, asked, _) = try started()
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) {
            try asked.read(.offer(NearbyOffer(items: [.link(URL(string: "https://example.com/")!)])))
        }
        // Before the hello, nothing but a hello.
        var fresh = NearbyRememberExchange.asking()
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) { try fresh.read(.remember) }
    }

    @Test func confirmingBeforeTheCodeDoesNothing() throws {
        var (asking, asked, _) = try started()
        let early = asking.confirm()
        let earlyThere = asked.confirm()
        #expect(early == nil && earlyThere == nil)
    }

    @Test func aSecondConfirmFromThemIsRefused() throws {
        var (asking, _) = try comparing()
        _ = try asking.read(.rememberConfirm)
        #expect(throws: NearbyRememberExchange.Failure.outOfTurn) { try asking.read(.rememberConfirm) }
    }

    @Test func cancelEndsItAndIsToldToTheOtherSide() throws {
        var (asking, asked) = try comparing()
        let told = asking.cancel()
        #expect(told == .cancel)
        #expect(asking.stage == .finished)
        #expect(throws: NearbyRememberExchange.Failure.cancelled) { try asked.read(.cancel) }
        // Nothing to tell before anything was asked.
        var fresh = NearbyRememberExchange.asking()
        let nothing = fresh.cancel()
        #expect(nothing == nil)
    }

    @Test func theMessagesSurviveTheWire() throws {
        let messages: [NearbyMessage] = [.remember, .rememberCommit(Data(repeating: 1, count: 32)),
                                         .rememberNonce(nonce(2)), .rememberConfirm]
        for message in messages {
            let frame = try message.frame()
            #expect(try NearbyMessage.decode(frame.dropFirst(4)) == message)
        }
    }

    @Test func aPromiseOrNumberOfTheWrongSizeIsRefused() throws {
        for message in [NearbyMessage.rememberCommit(Data(repeating: 1, count: 31)),
                        .rememberCommit(Data(repeating: 1, count: 33)),
                        .rememberNonce(Data(repeating: 1, count: 16)),
                        .rememberNonce(Data())] {
            let frame = try message.frame()
            #expect(throws: NearbyMessage.Failure.badRemember) { try NearbyMessage.decode(frame.dropFirst(4)) }
        }
        #expect(throws: NearbyMessage.Failure.unreadable) {
            try NearbyMessage.decode(Data(#"{"type":"rememberNonce"}"#.utf8))
        }
    }

    @Test func aMacMayAskToRememberInPlaceOfAnOffer() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(.hello(NearbyHello(version: NearbyProtocol.version, name: "Alex")))
        let event = try rules.read(.remember)
        #expect(event == .rememberRequested)
        #expect(rules.stage == .finished)

        var old = NearbyIncomingTransfer()
        _ = try old.read(.hello(NearbyHello(version: NearbyProtocol.fileVersion, name: "Alex")))
        #expect(throws: NearbyIncomingTransfer.Failure.tooOld) { try old.read(.remember) }

        var nameless = NearbyIncomingTransfer()
        _ = try nameless.read(.hello(NearbyHello(version: NearbyProtocol.version, name: nil)))
        #expect(throws: NearbyIncomingTransfer.Failure.nameless) { try nameless.read(.remember) }

        var early = NearbyIncomingTransfer()
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) { try early.read(.remember) }
    }
}

/// Remembering between two services, as between two Macs, and what it changes. One
/// test at a time: each brings up two or three services that all ask each other's
/// names, and a dozen at once fill each other's listeners (4 connections at most)
/// until some give up asking.
@MainActor
@Suite(.serialized)
struct NearbyRememberingTests {
    private static func randomName(_ prefix: String) -> String {
        "\(prefix) \(Int.random(in: 1000...9999))"
    }

    /// Turns both on with names; `looking` browses until it has found `found`.
    private func turnOn(_ sides: [NearbyTestSide], names: [String]) {
        for (side, name) in zip(sides, names) {
            side.settings.nearbyName = name
            side.settings.nearbySharingEnabled = true
            side.service.start()
        }
    }

    private func peerID(of name: String, from side: NearbyTestSide,
                        where condition: (NearbyService.Peer) -> Bool = { _ in true }) async throws -> String {
        let found = try await nearbyEventually(30) {
            side.service.peers.contains { $0.heardName == name && condition($0) }
        }
        try #require(found)
        return try #require(side.service.peers.first { $0.heardName == name }).id
    }

    private func code(_ phase: NearbyRememberPhase?) -> String? {
        if case let .comparing(_, code, _, _) = phase { return code }
        return nil
    }

    private func isRemembered(_ phase: NearbyRememberPhase?) -> Bool {
        if case .remembered = phase { return true }
        return false
    }

    /// Both sheets open; `asking` picks `asked`, both see the code and confirm.
    private func rememberEachOther(_ asking: NearbyTestSide, _ asked: NearbyTestSide, askedName: String) async throws {
        asking.service.startRemembering()
        asked.service.startRemembering()
        asking.service.remember(try await peerID(of: askedName, from: asking))
        #expect(try await nearbyEventually(15) {
            code(asking.service.rememberPhase) != nil && code(asked.service.rememberPhase) != nil
        })
        #expect(code(asking.service.rememberPhase) == code(asked.service.rememberPhase))
        asking.service.confirmRememberCode()
        asked.service.confirmRememberCode()
        #expect(try await nearbyEventually(10) {
            isRemembered(asking.service.rememberPhase) && isRemembered(asked.service.rememberPhase)
        })
        asking.service.stopRemembering()
        asked.service.stopRemembering()
    }

    @Test(.timeLimit(.minutes(1)))
    func twoMacsRememberEachOtherOnlyOnceBothConfirmTheSameCode() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        alex.service.startRemembering()
        sam.service.startRemembering()
        alex.service.remember(try await peerID(of: names[1], from: alex))
        #expect(try await nearbyEventually(15) {
            code(alex.service.rememberPhase) != nil && code(sam.service.rememberPhase) != nil
        })
        #expect(code(alex.service.rememberPhase) == code(sam.service.rememberPhase))
        guard case let .comparing(name, _, askedByThem, _) = sam.service.rememberPhase else {
            Issue.record("Sam's sheet isn't comparing")
            return
        }
        #expect(name == names[0])
        #expect(askedByThem)

        // One confirm isn't enough.
        alex.service.confirmRememberCode()
        try await Task.sleep(for: .milliseconds(500))
        #expect(alex.service.rememberedMacs.isEmpty)
        #expect(sam.service.rememberedMacs.isEmpty)

        sam.service.confirmRememberCode()
        #expect(try await nearbyEventually(10) {
            isRemembered(alex.service.rememberPhase) && isRemembered(sam.service.rememberPhase)
        })
        #expect(alex.service.rememberedMacs.map(\.name) == [names[1]])
        #expect(sam.service.rememberedMacs.map(\.name) == [names[0]])
        #expect(alex.service.peers.first { $0.heardName == names[1] }?.isRemembered == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacWhoseSheetIsClosedIsntReady() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        alex.service.startRemembering()
        alex.service.remember(try await peerID(of: names[1], from: alex))
        #expect(try await nearbyEventually(10) { alex.service.rememberPhase == .failed(name: names[1], .notReady) })
        #expect(alex.service.rememberedMacs.isEmpty)
        #expect(sam.service.rememberedMacs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingRemembersNeither() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        alex.service.startRemembering()
        sam.service.startRemembering()
        alex.service.remember(try await peerID(of: names[1], from: alex))
        #expect(try await nearbyEventually(15) { code(sam.service.rememberPhase) != nil })
        alex.service.confirmRememberCode()
        sam.service.cancelRemembering()
        #expect(sam.service.rememberPhase == .looking)
        #expect(try await nearbyEventually(10) {
            alex.service.rememberPhase == .failed(name: names[1], .cancelledByThem)
        })
        #expect(alex.service.rememberedMacs.isEmpty)
        #expect(sam.service.rememberedMacs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRememberedMacsTilesArriveWithoutAnOfferUntilItsForgotten() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        try await rememberEachOther(alex, sam, askedName: names[1])

        alex.service.beginBrowsing()
        let samID = try await peerID(of: names[1], from: alex) { $0.isRemembered }
        var received: [(items: [NearbyReceivedItem], from: String, withoutAsking: Bool)] = []
        sam.service.onReceived = { received.append(($0, $1, $2)) }
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(alex.service.send([shelfItem(.text("Straight to your shelf"))], to: samID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { statuses.last == .sent })
        #expect(sam.service.offers.isEmpty)
        #expect(received.count == 1)
        #expect(received.first?.items == [.text("Straight to your shelf")])
        #expect(received.first?.from == names[0])
        #expect(received.first?.withoutAsking == true)

        // Forgotten: it asks first again.
        sam.service.forget(try #require(sam.service.rememberedMacs.first).publicKey)
        statuses = []
        #expect(alex.service.send([shelfItem(.text("Asking again"))], to: samID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { !sam.service.offers.isEmpty })
        #expect(statuses.last == .waiting)
        // Forgotten, it's an ordinary stranger: no warning.
        #expect(sam.service.offers.first?.usesRememberedName == false)
        #expect(received.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacWithARememberedNameButAnotherKeyHasToAsk() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        let impostor = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
            impostor.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        try await rememberEachOther(alex, sam, askedName: names[1])

        // Another Mac calls itself Alex.
        turnOn([impostor], names: [names[0]])
        impostor.service.beginBrowsing()
        let samID = try await peerID(of: names[1], from: impostor)
        #expect(impostor.service.peers.first { $0.id == samID }?.isRemembered == false)
        var received = 0
        sam.service.onReceived = { _, _, _ in received += 1 }
        #expect(impostor.service.send([shelfItem(.text("It's me, Alex"))], to: samID) { _ in } != nil)
        #expect(try await nearbyEventually(10) { !sam.service.offers.isEmpty })
        #expect(sam.service.offers.first?.senderName == names[0])
        #expect(sam.service.offers.first?.usesRememberedName == true)
        #expect(received == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHiddenMacCanBeRememberedAndThenOnlyRememberedMacsSeeIt() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        let stranger = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
            stranger.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam"), Self.randomName("Stranger")]
        sam.settings.nearbyReceiveFrom = .remembered
        turnOn([alex, sam, stranger], names: names)
        // Sam is hidden, but shows while the Remember sheet is open.
        try await rememberEachOther(alex, sam, askedName: names[1])

        // The sheet closed: Alex, remembered, still finds Sam and sends at once.
        alex.service.beginBrowsing()
        let samID = try await peerID(of: names[1], from: alex) { $0.isRemembered }
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(alex.service.send([shelfItem(.text("Hi Sam"))], to: samID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { statuses.last == .sent })

        // A stranger doesn't learn Sam's name.
        stranger.service.beginBrowsing()
        #expect(try await nearbyEventually(30) { stranger.service.peers.contains { $0.heardName == names[0] } })
        try await Task.sleep(for: .seconds(2))
        #expect(!stranger.service.peers.contains { $0.heardName == names[1] })
    }

    @Test(.timeLimit(.minutes(1)))
    func aRememberedMacsNewNameIsPickedUp() async throws {
        let alex = try NearbyTestSide()
        let sam = try NearbyTestSide()
        defer {
            alex.cleanUp()
            sam.cleanUp()
        }
        let names = [Self.randomName("Alex"), Self.randomName("Sam")]
        turnOn([alex, sam], names: names)
        try await rememberEachOther(alex, sam, askedName: names[1])

        // Sam renames their Mac; Alex hears the new name next time it looks.
        let newName = Self.randomName("Sam's MacBook")
        sam.settings.nearbyName = newName
        alex.service.beginBrowsing()
        _ = try await peerID(of: newName, from: alex)
        #expect(try await nearbyEventually(5) { alex.service.rememberedMacs.first?.name == newName })
        #expect(alex.service.peers.first { $0.heardName == newName }?.name == newName)
    }
}

/// What the panel does with tiles from a remembered Mac, and how Send To lists Macs.
@MainActor
struct NearbyRememberedPanelTests {
    private let example = URL(string: "https://example.com/page")!

    @Test func tilesSentWithoutAskingSayWhoSentWhat() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.receiveNearby([.text("Meeting notes")], from: "Alex", withoutAsking: true)
        #expect(model.notice == "Alex sent \u{201C}Meeting notes\u{201D}")
        model.dismissNotice()
        model.receiveNearby([.link(example), .text("More notes")], from: "Alex", withoutAsking: true)
        #expect(model.notice == "Alex sent 2 items")
        #expect(store.items.prefix(3).allSatisfy { $0.receivedFrom == "Alex" })
    }

    @Test func anAcceptedOfferNeedsNoMessage() {
        let model = NotchViewModel(store: ShelfStore())
        model.receiveNearby([.text("From a stranger")], from: "Sam")
        #expect(model.notice == nil)
    }

    @Test func theMessageSaysWhatWasAlreadyOnTheShelf() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        store.add([ShelfItem.Draft(linkURL: example)])
        model.receiveNearby([.link(example), .text("New")], from: "Alex", withoutAsking: true)
        #expect(model.notice == "Alex sent 2 items. 1 was already on the shelf")
        model.receiveNearby([.link(example)], from: "Alex", withoutAsking: true)
        #expect(model.notice?.hasPrefix("Alex sent \u{201C}") == true)
        #expect(model.notice?.hasSuffix(", already on the shelf") == true)
        #expect(NotchViewModel.arrivalMessage(from: "Alex", count: 3, added: 0, firstName: "x")
                == "Alex sent 3 items, all already on the shelf")
        #expect(NotchViewModel.arrivalMessage(from: "Alex", count: 3, added: 1, firstName: "x")
                == "Alex sent 3 items. 2 were already on the shelf")
    }

    private func peer(_ name: String, remembered: Bool, version: Int = NearbyProtocol.version) -> NearbyService.Peer {
        NearbyService.Peer(id: name, heardName: name, fingerprint: nil, isPeerToPeer: true, version: version,
                           rememberedName: remembered ? name : nil)
    }

    @Test func sendToListsRememberedMacsFirstUnderTheirOwnHeader() {
        let list = NearbySendTarget.list([peer("Alex", remembered: true), peer("Sam", remembered: false),
                                          peer("Old", remembered: false, version: NearbyProtocol.offerVersion)],
                                         hasFiles: true)
        #expect(list.map(\.title) == ["Remembered", "Alex", "Other Macs", "Sam", "Old (Needs a Newer Polka)"])
        #expect(list.map(\.isHeader) == [true, false, true, false, false])
        #expect(list[2].startsGroup)
        #expect(list.map(\.isEnabled) == [false, true, false, true, false])
    }

    @Test func withoutRememberedMacsThereAreNoHeaders() {
        let strangers = NearbySendTarget.list([peer("Sam", remembered: false)], hasFiles: false)
        #expect(strangers.map(\.title) == ["Sam"])
        let friends = NearbySendTarget.list([peer("Alex", remembered: true)], hasFiles: false)
        #expect(friends.map(\.title) == ["Remembered", "Alex"])
    }
}

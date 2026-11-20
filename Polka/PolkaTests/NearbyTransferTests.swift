import Foundation
import Testing
@testable import Polka

/// Nearby Sharing, N2: offers of links and text, the answer, and what arrives. Files
/// (N3) are in `NearbyFileTransferTests`. In real
/// use everything here comes from another Mac, so most tests send what a hostile one
/// might: messages out of turn, offers that break the rules, texts that aren't what the
/// offer showed.

private func shelfItem(_ source: ShelfItem.Source) -> ShelfItem {
    let kind: ShelfItem.Kind
    switch source {
    case .file: kind = .file
    case .link: kind = .link
    case .text: kind = .text
    }
    return ShelfItem(id: UUID(), kind: kind, title: "Renamed by me", source: source,
                     storageMode: .reference, createdAt: Date(), expiresAt: nil, sortOrder: 0,
                     customName: "Secret label")
}

private func decode(_ json: String) throws -> NearbyMessage {
    try NearbyMessage.decode(Data(json.utf8))
}

private let example = URL(string: "https://example.com/page")!

struct NearbyOfferTests {
    @Test func anOfferSurvivesTheWire() throws {
        let offer = NearbyMessage.offer(NearbyOffer(items: [
            .link(example),
            .text(excerpt: "Привет 👋", length: "Привет 👋".utf16.count),
        ]))
        var reader = NearbyFrameReader()
        let payloads = try reader.append(try offer.frame())
        #expect(try NearbyMessage.decode(try #require(payloads[0].message)) == offer)
    }

    @Test func answersTextsAndDoneSurviveTheWire() throws {
        for message in [NearbyMessage.accept, .decline, .done,
                        .text(NearbyText(index: 3, data: Data("hi".utf8)))] {
            var reader = NearbyFrameReader()
            #expect(try NearbyMessage.decode(try #require(try reader.append(try message.frame())[0].message)) == message)
        }
    }

    @Test func anEmptyOfferIsRefused() {
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[]}}"#)
        }
    }

    @Test func anOfferOfMoreThan50ItemsIsRefused() {
        let item = #"{"kind":"link","url":"https://example.com/"}"#
        let items = Array(repeating: item, count: 51).joined(separator: ",")
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[\#(items)]}}"#)
        }
    }

    @Test func linksThatArentWebAddressesAreRefused() {
        for address in ["smb://server/share", "javascript:alert(1)", "file:///etc/passwd",
                        "x-apple.systempreferences:", "https://", "not a url"] {
            #expect(throws: NearbyMessage.Failure.badOffer) {
                _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"link","url":"\#(address)"}]}}"#)
            }
        }
    }

    @Test func aLinkLongerThan8KBIsRefused() {
        let address = "https://example.com/" + String(repeating: "a", count: NearbyOffer.maxLinkBytes)
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"link","url":"\#(address)"}]}}"#)
        }
    }

    @Test func aKindThisVersionDoesntKnowIsRefused() {
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"folder","url":"/etc"}]}}"#)
        }
    }

    @Test func anItemMissingItsFieldsIsRefused() {
        for item in [#"{"kind":"link"}"#, #"{"kind":"text","excerpt":"hi"}"#, #"{"kind":"text","length":2}"#] {
            #expect(throws: NearbyMessage.Failure.badOffer) {
                _ = try decode(#"{"type":"offer","offer":{"items":[\#(item)]}}"#)
            }
        }
    }

    @Test func textLongerThanTheShelfKeepsIsRefused() {
        let length = ShelfItem.maxTextLength + 1
        let excerpt = String(repeating: "a", count: NearbyOffer.maxExcerptLength)
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"text","excerpt":"\#(excerpt)","length":\#(length)}]}}"#)
        }
    }

    @Test func anExcerptLongerThanItsTextIsRefused() {
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"text","excerpt":"hello","length":2}]}}"#)
        }
    }

    @Test func aShortExcerptMustBeTheWholeText() {
        // "hi" is under 2,000 characters, so it can't be the start of a longer text.
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"text","excerpt":"hi","length":500}]}}"#)
        }
    }

    @Test func anExcerptOver2000CharactersIsRefused() {
        let excerpt = String(repeating: "a", count: NearbyOffer.maxExcerptLength + 1)
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"text","excerpt":"\#(excerpt)","length":5000}]}}"#)
        }
    }

    @Test func aTextForAPlaceNoOfferHasIsRefused() {
        #expect(throws: NearbyMessage.Failure.badText) {
            _ = try decode(#"{"type":"text","text":{"index":50,"data":""}}"#)
        }
        #expect(throws: NearbyMessage.Failure.badText) {
            _ = try decode(#"{"type":"text","text":{"index":-1,"data":""}}"#)
        }
    }

    @Test func filesAreLeftToPrepareAndOldLinksArentOffered() {
        #expect(NearbyOffer.item(for: shelfItem(.file(path: "/tmp/a.pdf", bookmark: nil))) == nil)
        #expect(NearbyOffer.item(for: shelfItem(.link(URL(string: "smb://server/share")!))) == nil)
    }

    @Test func aLinkIsOfferedAsJustItsAddress() {
        // Not the tile's given name: the other Mac names it itself.
        #expect(NearbyOffer.item(for: shelfItem(.link(example))) == .link(example))
    }

    @Test func aLongTextIsOfferedAsItsStartAndLength() throws {
        let text = String(repeating: "ab", count: 3_000)
        let item = try #require(NearbyOffer.item(for: shelfItem(.text(text))))
        #expect(item == .text(excerpt: String(repeating: "ab", count: 1_000), length: 6_000))
    }

    @Test func theWholeTextMustMatchWhatWasShown() {
        let text = String(repeating: "x", count: 2_500)
        let excerpt = NearbyOffer.excerpt(of: text)
        #expect(NearbyOffer.text(text, matchesExcerpt: excerpt, length: 2_500))
        // Longer or shorter than offered.
        #expect(!NearbyOffer.text(text + "y", matchesExcerpt: excerpt, length: 2_500))
        // Starting differently.
        #expect(!NearbyOffer.text("y" + text.dropFirst(), matchesExcerpt: excerpt, length: 2_500))
        // Cut short where the sender's Polka wouldn't have cut it.
        #expect(!NearbyOffer.text(text, matchesExcerpt: String(excerpt.dropLast()), length: 2_500))
    }

    @Test func lookalikeCharactersDontCountAsTheSame() {
        // "é" as one character, and as "e" plus an accent: equal as Swift strings,
        // different bytes.
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(!NearbyOffer.text(decomposed, matchesExcerpt: composed, length: decomposed.utf16.count))
    }
}

struct NearbyIncomingTransferTests {
    private let hello = NearbyMessage.hello(NearbyHello(version: NearbyProtocol.version, name: "Alex"))
    private let text = "Line one\nLine two"
    private var offer: NearbyMessage {
        .offer(NearbyOffer(items: [.link(example), .text(excerpt: text, length: text.utf16.count)]))
    }

    @Test func anAcceptedOfferArrivesWhole() throws {
        var rules = NearbyIncomingTransfer()
        #expect(try rules.read(hello) == .nothing)
        guard case .offered = try rules.read(offer) else { Issue.record("no offer"); return }
        #expect(rules.senderName == "Alex")
        #expect(rules.answer(accept: true) == .accept)
        #expect(try rules.read(.text(NearbyText(index: 1, data: Data(text.utf8)))) == .nothing)
        #expect(try rules.read(.done) == .complete(links: [0: example], texts: [1: text]))
        #expect(rules.stage == .finished)
    }

    @Test func anOfferBeforeHelloIsRefused() {
        var rules = NearbyIncomingTransfer()
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) { _ = try rules.read(offer) }
    }

    @Test func aNamelessMacCantOffer() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(.hello(NearbyHello(version: NearbyProtocol.version, name: nil)))
        #expect(throws: NearbyIncomingTransfer.Failure.nameless) { _ = try rules.read(offer) }
    }

    @Test func aVersionThatDoesntMakeOffersCantOffer() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(.hello(NearbyHello(version: 1, name: "Old")))
        #expect(throws: NearbyIncomingTransfer.Failure.tooOld) { _ = try rules.read(offer) }
    }

    @Test func aSecondOfferIsRefused() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        _ = try rules.read(offer)
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) { _ = try rules.read(offer) }
    }

    @Test func textBeforeAcceptIsRefused() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        _ = try rules.read(offer)
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) {
            _ = try rules.read(.text(NearbyText(index: 1, data: Data(text.utf8))))
        }
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) { _ = try rules.read(.done) }
    }

    private func accepted() throws -> NearbyIncomingTransfer {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        _ = try rules.read(offer)
        _ = rules.answer(accept: true)
        return rules
    }

    @Test func textForALinkIsRefused() throws {
        var rules = try accepted()
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.text(NearbyText(index: 0, data: Data("https://evil.example".utf8))))
        }
    }

    @Test func aTextSentTwiceIsRefused() throws {
        var rules = try accepted()
        _ = try rules.read(.text(NearbyText(index: 1, data: Data(text.utf8))))
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.text(NearbyText(index: 1, data: Data(text.utf8))))
        }
    }

    @Test func aDifferentTextThanShownIsRefused() throws {
        var rules = try accepted()
        let swapped = "Line one\nLine 2!!"
        #expect(swapped.utf16.count == text.utf16.count)
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.text(NearbyText(index: 1, data: Data(swapped.utf8))))
        }
    }

    @Test func bytesThatArentUTF8AreRefused() throws {
        var rules = try accepted()
        var bytes = Data(text.utf8)
        bytes[0] = 0xFF
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.text(NearbyText(index: 1, data: bytes)))
        }
    }

    @Test func moreBytesThanTheLengthAllowsAreRefusedUnread() throws {
        var rules = try accepted()
        let bytes = Data(count: text.utf16.count * 3 + 1)
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.text(NearbyText(index: 1, data: bytes)))
        }
    }

    @Test func doneBeforeEveryTextIsRefused() throws {
        var rules = try accepted()
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) { _ = try rules.read(.done) }
    }

    @Test func nothingIsTakenAfterDecline() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        _ = try rules.read(offer)
        #expect(rules.answer(accept: false) == .decline)
        #expect(rules.answer(accept: true) == nil)
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) {
            _ = try rules.read(.text(NearbyText(index: 1, data: Data(text.utf8))))
        }
    }

    @Test func thereIsNothingToAnswerBeforeAnOffer() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        #expect(rules.answer(accept: true) == nil)
    }

    @Test func aReceivedItemSaysWhoSentIt() {
        let draft = NearbyReceivedItem.text("Hello").draft(from: "Alex")
        #expect(draft.receivedFrom == "Alex")
        #expect(draft.title == "Hello")
        #expect(NearbyReceivedItem.link(example).draft(from: "Alex").title == LinkNaming.title(for: example, siteName: nil))
    }
}

struct NearbyOutgoingTransferTests {
    @Test func missingFilesStayBehind() throws {
        let prepared = try NearbyOutgoingItem.prepare([
            shelfItem(.file(path: "/tmp/polka-never-there-\(UUID().uuidString).pdf", bookmark: nil)),
            shelfItem(.link(example)),
            shelfItem(.text("Hi")),
        ])
        #expect(prepared.map(\.item) == [.link(example), .text("Hi")])
    }

    @Test func nothingSendableMeansNoTransfer() {
        #expect(throws: NearbyOutgoingItem.Failure.nothing) {
            _ = try NearbyOutgoingItem.prepare([shelfItem(.file(path: "/tmp/polka-never-there.pdf", bookmark: nil))])
        }
        #expect(throws: NearbyOutgoingItem.Failure.nothing) { _ = try NearbyOutgoingItem.prepare([]) }
    }

    @Test func atMost50ItemsGo() throws {
        let items = (0..<60).map { shelfItem(.text("Text \($0)")) }
        #expect(try NearbyOutgoingItem.prepare(items).count == NearbyOffer.maxItems)
    }

    @Test func theOfferGoesAfterTheirHelloAndTheTextsAfterAccept() throws {
        var transfer = NearbyOutgoingTransfer(items: [.link(example), .text("Hi")])
        let first = try transfer.read(.hello(NearbyHello(version: NearbyProtocol.version, name: "Sam")))
        #expect(first.event == .offered)
        #expect(first.send == [.offer(NearbyOffer(items: [.link(example), .text(excerpt: "Hi", length: 2)]))])
        let second = try transfer.read(.accept)
        #expect(second.event == .accepted)
        // `done` follows once the files, if any, have gone.
        #expect(second.send == [.text(NearbyText(index: 1, data: Data("Hi".utf8)))])
        #expect(try transfer.read(.done).event == .delivered)
    }

    @Test func aDeclineEndsIt() throws {
        var transfer = NearbyOutgoingTransfer(items: [.link(example)])
        _ = try transfer.read(.hello(NearbyHello(version: NearbyProtocol.version, name: "Sam")))
        #expect(try transfer.read(.decline).event == .declined)
        #expect(throws: NearbyOutgoingTransfer.Failure.outOfTurn) { _ = try transfer.read(.accept) }
    }

    @Test func aMacTooOldForOffersGetsNone() throws {
        var transfer = NearbyOutgoingTransfer(items: [.link(example)])
        #expect(throws: NearbyOutgoingTransfer.Failure.tooOld) {
            _ = try transfer.read(.hello(NearbyHello(version: 1, name: "Old")))
        }
    }

    @Test func anAcceptBeforeTheOfferIsRefused() throws {
        var transfer = NearbyOutgoingTransfer(items: [.link(example)])
        #expect(throws: NearbyOutgoingTransfer.Failure.outOfTurn) { _ = try transfer.read(.accept) }
    }
}

struct NearbyOfferLineTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func atMostThreeWaitOneFromEachMac() {
        var line = NearbyOfferLine()
        #expect(line.admit(id: UUID(), fingerprint: "A") == .admitted)
        #expect(line.admit(id: UUID(), fingerprint: "A") == .alreadyWaiting)
        #expect(line.admit(id: UUID(), fingerprint: "B") == .admitted)
        #expect(line.admit(id: UUID(), fingerprint: "C") == .admitted)
        #expect(line.admit(id: UUID(), fingerprint: "D") == .full)
    }

    @Test func aBlockedMacIsTurnedAway() {
        var line = NearbyOfferLine()
        line.block("A")
        #expect(line.admit(id: UUID(), fingerprint: "A") == .blocked)
    }

    @Test func offersShowOneAtATimeInTheOrderTheyArrived() {
        var line = NearbyOfferLine()
        let first = UUID(), second = UUID()
        _ = line.admit(id: first, fingerprint: "A")
        _ = line.admit(id: second, fingerprint: "B")
        #expect(line.next(at: start).id == first)
        line.show(first, at: start)
        #expect(line.next(at: start).id == nil)
        line.remove(first)
        // The next waits for the minute, whichever Mac it's from.
        #expect(line.next(at: start).id == nil)
        #expect(line.next(at: start.addingTimeInterval(NearbyOfferLine.strangerOpenInterval)).id == second)
    }

    /// A hostile Polka can make a new key for every offer, so the minute is for every
    /// Mac that isn't remembered together, not for each key (N6).
    @Test func offersOpenThePanelAtMostOnceAMinuteWhicheverMacTheyreFrom() {
        var line = NearbyOfferLine()
        let first = UUID(), again = UUID(), other = UUID()
        _ = line.admit(id: first, fingerprint: "A")
        line.show(first, at: start)
        line.remove(first)

        _ = line.admit(id: again, fingerprint: "A")
        _ = line.admit(id: other, fingerprint: "B")
        let tooSoon = line.next(at: start.addingTimeInterval(10))
        #expect(tooSoon.id == nil)
        #expect(tooSoon.checkAgainAt == start.addingTimeInterval(NearbyOfferLine.strangerOpenInterval))

        // Once the minute is up, the first in line.
        #expect(line.next(at: start.addingTimeInterval(60)).id == again)
    }

    /// Decline and Block turns that Mac away until Polka quits, and every Mac that
    /// isn't remembered for ten minutes, since it could come back with a new key.
    @Test func blockingTurnsAwayEveryStrangerForTenMinutes() {
        var line = NearbyOfferLine()
        line.block("A", at: start)
        #expect(line.admit(id: UUID(), fingerprint: "B", at: start.addingTimeInterval(60)) == .paused)
        #expect(line.admit(id: UUID(), fingerprint: "C",
                           at: start.addingTimeInterval(NearbyOfferLine.blockPause - 1)) == .paused)
        let later = start.addingTimeInterval(NearbyOfferLine.blockPause + 1)
        #expect(line.admit(id: UUID(), fingerprint: "B", at: later) == .admitted)
        #expect(line.admit(id: UUID(), fingerprint: "A", at: later) == .blocked)
    }
}

struct NearbyShelfTests {
    @Test func whoSentAnItemIsKeptInShelfJSON() throws {
        var item = shelfItem(.text("Hi"))
        item.receivedFrom = "Alex"
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(ShelfItem.self, from: data).receivedFrom == "Alex")
    }

    @Test func anItemSavedBeforeNearbySharingStillLoads() throws {
        let json = #"""
            {"id":"6F9C1B9E-1D7B-4C1A-9A44-1C3E2C2C7E11","kind":"text","title":"Hi",
             "source":{"text":{"_0":"Hi"}},"storageMode":"reference","createdAt":0,"sortOrder":0}
            """#
        let item = try JSONDecoder().decode(ShelfItem.self, from: Data(json.utf8))
        #expect(item.receivedFrom == nil)
    }
}

/// One side of a test between Nearby Sharing services in this one process, talking
/// over the network as two Macs would (here over loopback or Wi-Fi), with its own
/// settings and its own throwaway Keychain key.
@MainActor
struct NearbyTestSide {
    let suite: String
    let defaults: UserDefaults
    let tag: String
    let service: NearbyService
    /// Its own Copies folder, where received files go.
    let copies: ShelfCopies

    var settings: ShelfSettings { ShelfSettings(defaults: defaults) }

    init(answerTimeout: TimeInterval = NearbyOfferLine.answerTimeout,
         freeSpace: @escaping (URL) -> Int64? = { _ in 500_000_000_000 }) throws {
        suite = "PolkaTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        tag = "com.maksimds.Polka.tests.nearby.\(UUID().uuidString)"
        copies = ShelfCopies(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("PolkaNearbyTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Copies", isDirectory: true))
        service = NearbyService(settings: ShelfSettings(defaults: defaults), identityTag: tag,
                                answerTimeout: answerTimeout, freeSpace: freeSpace)
        service.copies = copies
    }

    func cleanUp() {
        service.stop()
        NearbyIdentity.delete(tag: tag)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: copies.folder.deletingLastPathComponent())
    }
}

/// Waits up to `seconds` for `condition`, checking every tenth of a second.
@MainActor
func nearbyEventually(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

/// Offers between two services, as between two Macs.
@MainActor
struct NearbySendingTests {
    /// Turns both on, with names, and waits until `sender` has found `receiver`.
    private func found(_ receiver: NearbyTestSide, from sender: NearbyTestSide, named name: String) async throws -> String {
        receiver.settings.nearbyName = name
        sender.settings.nearbyName = "Sender \(Int.random(in: 1000...9999))"
        receiver.settings.nearbySharingEnabled = true
        sender.settings.nearbySharingEnabled = true
        receiver.service.start()
        sender.service.start()
        sender.service.beginBrowsing()
        let found = try await nearbyEventually(30) { sender.service.peers.contains { $0.name == name } }
        try #require(found)
        return try #require(sender.service.peers.first { $0.name == name }).id
    }

    @Test(.timeLimit(.minutes(1)))
    func anAcceptedOfferArrivesAndADeclineAndBlockTurnsTheNextOneAway() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
        }
        let peerID = try await found(receiver, from: sender, named: "Receiver \(Int.random(in: 1000...9999))")
        var received: [(items: [NearbyReceivedItem], from: String)] = []
        receiver.service.onReceived = { items, from, _ in received.append((items, from)) }
        let longText = String(repeating: "Привет, мир! 👋 ", count: 300)

        // Accepted: both items arrive, and the sender hears they did.
        var statuses: [NearbyOutgoingSession.Status] = []
        let items = [shelfItem(.link(example)), shelfItem(.text(longText)),
                     shelfItem(.file(path: "/tmp/never-sent.pdf", bookmark: nil))]
        #expect(sender.service.send(items, to: peerID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { !receiver.service.offers.isEmpty })
        let offer = try #require(receiver.service.offers.first)
        #expect(offer.senderName == sender.settings.nearbyName)
        #expect(offer.offer.items.count == 2)
        #expect(statuses.last == .waiting)
        #expect(receiver.service.nextOfferToShow().id == offer.id)
        receiver.service.showingOffer(offer.id)
        receiver.service.accept(offer.id)
        #expect(try await nearbyEventually(10) { statuses.last == .sent })
        #expect(received.count == 1)
        #expect(received.first?.items == [.link(example), .text(longText)])
        #expect(received.first?.from == sender.settings.nearbyName)
        #expect(receiver.service.offers.isEmpty)

        // Declined and blocked.
        statuses = []
        #expect(sender.service.send([shelfItem(.text("Again"))], to: peerID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { !receiver.service.offers.isEmpty })
        receiver.service.decline(try #require(receiver.service.offers.first).id, block: true)
        #expect(try await nearbyEventually(10) { statuses.last == .declined })

        // Turned away at once from now on, without reaching the line.
        statuses = []
        #expect(sender.service.send([shelfItem(.text("Once more"))], to: peerID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { statuses.last == .declined })
        #expect(receiver.service.offers.isEmpty)
        #expect(received.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func anOfferNobodyAnswersIsDeclined() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide(answerTimeout: 1)
        defer {
            sender.cleanUp()
            receiver.cleanUp()
        }
        let peerID = try await found(receiver, from: sender, named: "Away \(Int.random(in: 1000...9999))")
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(sender.service.send([shelfItem(.link(example))], to: peerID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { !receiver.service.offers.isEmpty })
        #expect(try await nearbyEventually(10) { statuses.last == .declined })
        #expect(receiver.service.offers.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacReceivingOnlyFromRememberedMacsCantBeSentTo() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
        }
        let peerID = try await found(receiver, from: sender, named: "Hidden \(Int.random(in: 1000...9999))")
        receiver.settings.nearbyReceiveFrom = .remembered
        // Its listener restarts under a new Bonjour name; the old endpoint is gone or
        // closes without a word.
        try await Task.sleep(for: .seconds(1))
        var statuses: [NearbyOutgoingSession.Status] = []
        if sender.service.send([shelfItem(.text("Hi"))], to: peerID, onStatus: { statuses.append($0) }) != nil {
            #expect(try await nearbyEventually(15) { statuses.last == .failed(.unreachable) })
        }
        #expect(receiver.service.offers.isEmpty)
    }
}

/// What the panel does with an offer: its preview tiles, the answer, and what arrives.
@MainActor
struct NearbyOfferPanelTests {
    private func offer(_ items: [NearbyOffer.Item], from name: String = "Alex") -> NearbyIncomingOffer {
        NearbyIncomingOffer(id: UUID(), senderName: name, fingerprint: "AAAA", offer: NearbyOffer(items: items))
    }

    @Test func previewsAreNamedHereFromWhatTheOfferHolds() {
        let text = "  First line\nSecond"
        let shown = offer([.link(example), .text(excerpt: text, length: text.utf16.count)])
        #expect(shown.previews.map(\.kind) == [.link, .text])
        #expect(shown.previews[0].title == LinkNaming.title(for: example, siteName: nil))
        #expect(shown.previews[1].title == "First line")
        #expect(shown.previews.allSatisfy { $0.customName == nil && $0.receivedFrom == nil })
    }

    @Test func aPreviewNameLosesInvisibleCharacters() {
        // A right-to-left override would make "txt.exe" read as "exe.txt".
        let text = "invoice\u{202E}txt.exe"
        let shown = offer([.text(excerpt: text, length: text.utf16.count)])
        #expect(shown.previews[0].title == "invoicetxt.exe")
    }

    @Test func aLookalikeAddressShowsItsEncodedHost() throws {
        // "аpple.com" with a Cyrillic "а".
        let url = try #require(URL(string: "https://\u{430}pple.com/"))
        let shown = offer([.link(url)])
        #expect(shown.previews[0].title.lowercased().contains("xn--pple-43d"))
    }

    @Test func answeringOnlyWorksWhileTheOfferShows() {
        let model = NotchViewModel(store: ShelfStore())
        var answers: [NotchViewModel.OfferAnswer] = []
        model.onOfferAnswered = { _, answer in answers.append(answer) }
        model.shownOffer = offer([.link(example)])
        model.answerOffer(.accept)
        #expect(answers.isEmpty)
        model.state = .offer
        model.answerOffer(.decline)
        #expect(answers == [.decline])
        #expect(model.shownOffer == nil)
        // Only once.
        model.answerOffer(.accept)
        #expect(answers == [.decline])
    }

    @Test func receivedItemsLandAtTheTopMarkedWithTheirSender() throws {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        store.add([ShelfItem.Draft(text: "Already here")])
        model.receiveNearby([.link(example), .text("From Alex")], from: "Alex")
        #expect(store.items.count == 3)
        #expect(store.items.prefix(2).allSatisfy { $0.receivedFrom == "Alex" })
        #expect(store.items[2].receivedFrom == nil)
        // Permanent, like every new item.
        #expect(store.items.allSatisfy { !$0.isTemporary })
    }

    @Test func aReceivedDuplicateIsNotAddedTwice() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        store.add([ShelfItem.Draft(linkURL: example)])
        model.receiveNearby([.link(example)], from: "Alex")
        #expect(store.items.count == 1)
        #expect(model.notice != nil)
    }
}

/// What Send To offers from the shelf, and what the sending tiles say.
@MainActor
struct NearbySendToTests {
    private func shelf() -> (NotchViewModel, ShelfStore, [ShelfItem.ID]) {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(text: "Note"),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.pdf")),
                   ShelfItem.Draft(linkURL: example)])
        return (NotchViewModel(store: store), store, store.items.map(\.id))
    }

    @Test func aTileAloneIsSentAlone() {
        let (model, _, ids) = shelf()
        #expect(model.itemsToSend(from: ids[2]).map(\.id) == [ids[2]])
    }

    @Test func aSelectionSendsItsFilesLinksAndTextWithTheTileFirst() {
        let (model, _, ids) = shelf()
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)
        model.click(ids[2], .toggle)
        #expect(model.sendableSelectionCount == 3)
        #expect(model.itemsToSend(from: ids[2]).map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func foldersAndMissingFilesStayBehind() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaSendTo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShelfStore()
        store.add([ShelfItem.Draft(text: "Note"),
                   ShelfItem.Draft(fileURL: folder),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/polka-gone-\(UUID().uuidString).pdf"))])
        store.refreshReferences()
        let model = NotchViewModel(store: store)
        let ids = store.items.map(\.id)
        ids.forEach { model.click($0, .toggle) }
        #expect(model.sendableSelectionCount == 1)
        #expect(model.itemsToSend(from: ids[0]).map(\.kind) == [.text])
    }

    @Test func stopSendingStopsTheSendItsTileIsIn() {
        let (model, _, ids) = shelf()
        var stopped: [UUID] = []
        model.onStopSending = { stopped.append($0) }
        let transfer = UUID()
        model.showSending("Sending 40%", isFinished: false, on: [ids[0], ids[1]], transfer: transfer)
        #expect(model.activeSends == [ids[0]: transfer, ids[1]: transfer])
        model.stopSending(ids[1])
        #expect(stopped == [transfer])
        // Once it's finished, there's nothing to stop.
        model.showSending("Cancelled", isFinished: true, on: [ids[0], ids[1]], transfer: transfer)
        #expect(model.activeSends.isEmpty)
        #expect(model.sendingLabels[ids[0]] == "Cancelled")
        model.stopSending(ids[0])
        #expect(stopped == [transfer])
    }

    @Test func aTileOutsideTheSelectionIsSentAlone() {
        let (model, _, ids) = shelf()
        model.click(ids[0], .only)
        #expect(model.itemsToSend(from: ids[2]).map(\.id) == [ids[2]])
    }

    @Test func aNewerSendToKeepsItsLabel() {
        let (model, _, ids) = shelf()
        model.showSending("Waiting for Alex…", isFinished: false, on: [ids[0]], transfer: UUID())
        #expect(model.sendingLabels[ids[0]] == "Waiting for Alex…")
        model.showSending("Waiting for Sam…", isFinished: false, on: [ids[0]], transfer: UUID())
        #expect(model.sendingLabels[ids[0]] == "Waiting for Sam…")
    }
}

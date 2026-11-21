import CryptoKit
import Foundation
import Network
import Testing
@testable import Polka

/// N6: a real Nearby Sharing service against a peer that breaks every rule, over
/// loopback. One test at a time, as with the remembering tests: each brings up a
/// service and several peers, each with a Keychain key.
@MainActor
@Suite(.serialized)
struct NearbyHostileTests {
    /// Every regular file under `folder`, hidden ones included.
    private func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// A peer that's said hello as a Polka would, under `name`.
    private func greeted(_ port: NWEndpoint.Port, as name: String = "Evil \(Int.random(in: 1000...9999))") async throws -> NearbyHostilePeer {
        let peer = try NearbyHostilePeer()
        try #require(try await peer.connectUntilGreeted(to: port))
        peer.send(.hello(NearbyHello(version: NearbyProtocol.version, name: name)))
        return peer
    }

    /// A peer whose offer of one file of `size` bytes is waiting on `side`.
    private func offering(_ size: Int64, named name: String = "data.bin", to side: NearbyTestSide,
                          at port: NWEndpoint.Port) async throws -> (NearbyHostilePeer, UUID) {
        let peer = try await greeted(port)
        peer.send(.offer(NearbyOffer(items: [.file(name: name, size: size)])))
        try #require(try await nearbyEventually(10) { !side.service.offers.isEmpty })
        return (peer, try #require(side.service.offers.first).id)
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    // MARK: - The connection

    /// Only mutual TLS 1.3 with Polka's protocol name gets as far as a hello.
    @Test(.timeLimit(.minutes(1)))
    func onlyMutualTLS13WithPolkasProtocolNameGetsAHello() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let polka = try NearbyHostilePeer()
        defer { polka.cleanUp() }
        #expect(try await polka.connectUntilGreeted(to: port))

        for transport in [NearbyHostilePeer.Transport.noCertificate, .tls12, .otherProtocol] {
            let peer = try NearbyHostilePeer()
            defer { peer.cleanUp() }
            peer.connect(to: port, as: transport)
            #expect(try await nearbyEventually(10) { peer.isClosed }, "\(transport)")
            #expect(peer.hello == nil, "\(transport)")
        }

        // Unencrypted, a hello is read as a broken TLS greeting.
        let plain = try NearbyHostilePeer(withKey: false)
        plain.connect(to: port, as: .plainTCP)
        try #require(try await nearbyEventually(10) { plain.isReady })
        plain.send(.hello(NearbyHello(version: NearbyProtocol.version, name: "Plain")))
        #expect(try await nearbyEventually(15) { plain.isClosed })
        #expect(plain.messages.isEmpty)
    }

    /// Bytes that aren't a message end that connection, and the Mac carries on.
    @Test(.timeLimit(.minutes(1)))
    func garbageAfterHelloEndsItAndTheMacCarriesOn() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let garbage = try await greeted(port)
        defer { garbage.cleanUp() }
        garbage.send(Data([0, 0, 0, 8]) + Data("not json".utf8))
        #expect(try await nearbyEventually(5) { garbage.isClosed })

        let huge = try await greeted(port)
        defer { huge.cleanUp() }
        // 2 GB declared: refused from the length alone, before any memory is set aside.
        huge.send(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        #expect(try await nearbyEventually(5) { huge.isClosed })

        let unknown = try await greeted(port)
        defer { unknown.cleanUp() }
        // There's no message that asks for anything; one this version doesn't know is refused.
        let ask = Data(#"{"type":"list"}"#.utf8)
        unknown.send(Data([0, 0, 0, UInt8(ask.count)]) + ask)
        #expect(try await nearbyEventually(5) { unknown.isClosed })
        #expect(side.service.offers.isEmpty)

        // Still taking offers.
        let (honest, _) = try await offering(10, to: side, at: port)
        defer { honest.cleanUp() }
        #expect(side.service.offers.count == 1)
    }

    // MARK: - Files

    @Test(.timeLimit(.minutes(1)))
    func piecesBeforeAcceptAreRefusedAndNothingIsWritten() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let (peer, _) = try await offering(10, to: side, at: port)
        defer { peer.cleanUp() }
        peer.sendPiece(randomBytes(10))
        #expect(try await nearbyEventually(5) { peer.isClosed })
        #expect(try await nearbyEventually(5) { side.service.offers.isEmpty })
        #expect(files(in: side.copies.folder).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFileLargerThanOfferedIsCutOffAndNothingIsKept() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        var failures = 0
        side.service.onReceiveFailed = { _, _ in failures += 1 }
        let (peer, id) = try await offering(10, to: side, at: port)
        defer { peer.cleanUp() }
        #expect(side.service.accept(id) == .accepted)
        try #require(try await nearbyEventually(5) { peer.messages.contains(.accept) })
        peer.sendPiece(randomBytes(11))
        #expect(try await nearbyEventually(5) { peer.isClosed })
        #expect(try await nearbyEventually(5) { failures == 1 })
        #expect(files(in: side.copies.folder).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFileThatIsntWhatItsHashSaysIsThrownAway() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        var failures = 0
        var received = 0
        side.service.onReceiveFailed = { _, _ in failures += 1 }
        side.service.onReceived = { _, _, _ in received += 1 }
        let (peer, id) = try await offering(10, to: side, at: port)
        defer { peer.cleanUp() }
        side.service.accept(id)
        try #require(try await nearbyEventually(5) { peer.messages.contains(.accept) })
        peer.sendPiece(randomBytes(10))
        peer.send(.fileEnd(NearbyFileEnd(index: 0, sha256: Data(SHA256.hash(data: randomBytes(10))))), .done)
        #expect(try await nearbyEventually(5) { failures == 1 })
        #expect(received == 0)
        #expect(!peer.messages.contains(.done))
        #expect(files(in: side.copies.folder).isEmpty)
    }

    /// A name that tries to climb out of its folder lands inside it, as a plain name.
    @Test(.timeLimit(.minutes(1)))
    func aNameThatClimbsOutStaysInItsOwnFolder() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        var arrived: [NearbyReceivedItem] = []
        side.service.onReceived = { items, _, _ in arrived = items }
        let bytes = randomBytes(5)
        let (peer, id) = try await offering(5, named: "../../../Library/LaunchAgents/evil.plist", to: side, at: port)
        defer { peer.cleanUp() }
        side.service.accept(id)
        try #require(try await nearbyEventually(5) { peer.messages.contains(.accept) })
        peer.sendPiece(bytes)
        peer.send(.fileEnd(NearbyFileEnd(index: 0, sha256: Data(SHA256.hash(data: bytes)))), .done)
        #expect(try await nearbyEventually(5) { peer.messages.contains(.done) })
        guard case let .file(url) = try #require(arrived.first) else {
            Issue.record("Not a file")
            return
        }
        let folder = side.copies.folder.standardizedFileURL.path + "/"
        #expect(url.standardizedFileURL.path.hasPrefix(folder))
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.path.contains(".."))
        // Nothing beside the Copies folder.
        let parent = side.copies.folder.deletingLastPathComponent()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) == ["Copies"])
    }

    // MARK: - Asking for things

    @Test(.timeLimit(.minutes(1)))
    func aRememberRequestWithNoSheetOpenIsDeclined() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let peer = try await greeted(port)
        defer { peer.cleanUp() }
        peer.send(.remember)
        #expect(try await nearbyEventually(5) { peer.messages.contains(.decline) })
        #expect(try await nearbyEventually(5) { peer.isClosed })
        #expect(side.service.rememberPhase == nil)
    }

    /// A hidden Mac shows its name while its Remember sheet is open, but takes only
    /// remember requests then, no offers.
    @Test(.timeLimit(.minutes(1)))
    func aHiddenMacTakesNoOffersWhileItsSheetIsOpen() async throws {
        let (side, hiddenPort) = try await nearbyListeningSide(receiveFrom: .remembered)
        defer { side.cleanUp() }
        side.service.startRemembering()
        // Showing itself, it listens anew, under a new name and port.
        try #require(try await nearbyEventually(10) {
            side.service.listeningPort != nil && side.service.listeningPort != hiddenPort
        })
        let peer = try await greeted(try #require(side.service.listeningPort))
        defer { peer.cleanUp() }
        peer.send(.offer(NearbyOffer(items: [.text(excerpt: "Hi", length: 2)])))
        #expect(try await nearbyEventually(5) { peer.messages.contains(.decline) })
        #expect(side.service.offers.isEmpty)
    }

    // MARK: - Floods

    /// Strangers share four connections; a remembered Mac still gets through (N6).
    @Test(.timeLimit(.minutes(1)))
    func strangersCantCrowdOutARememberedMac() async throws {
        let friend = try NearbyHostilePeer()
        defer { friend.cleanUp() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaHostile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var list = NearbyRememberedList()
        list.remember(try #require(friend.publicKey), name: "Friend", at: Date())
        try list.save(to: file)

        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        side.service.rememberedFile = file

        // Four strangers connect and say nothing.
        var strangers: [NearbyHostilePeer] = []
        defer { strangers.forEach { $0.cleanUp() } }
        for _ in 0..<4 {
            let stranger = try NearbyHostilePeer()
            strangers.append(stranger)
            try #require(try await stranger.connectUntilGreeted(to: port))
        }
        // A fifth is turned away once its key shows it's a stranger.
        let fifth = try NearbyHostilePeer()
        defer { fifth.cleanUp() }
        fifth.connect(to: port)
        #expect(try await nearbyEventually(10) { fifth.isClosed })
        #expect(fifth.hello == nil)
        // The remembered Mac gets through. It may try again, as Polka does, when other
        // tests' services fill all eight connections for a moment; strangers alone
        // can't keep it out.
        #expect(try await friend.connectUntilGreeted(to: port))
    }

    /// After Decline and Block, a new key doesn't get a new chance (N6).
    @Test(.timeLimit(.minutes(1)))
    func aNewKeyAfterDeclineAndBlockIsStillTurnedAway() async throws {
        let (side, port) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let first = try await greeted(port)
        defer { first.cleanUp() }
        first.send(.offer(NearbyOffer(items: [.text(excerpt: "Hi", length: 2)])))
        try #require(try await nearbyEventually(10) { side.service.offers.count == 1 })
        let waiting = try await greeted(port)
        defer { waiting.cleanUp() }
        waiting.send(.offer(NearbyOffer(items: [.text(excerpt: "Me too", length: 6)])))
        try #require(try await nearbyEventually(10) { side.service.offers.count == 2 })

        side.service.decline(try #require(side.service.offers.first).id, block: true)
        #expect(try await nearbyEventually(5) { first.messages.contains(.decline) })
        // The one waiting goes too.
        #expect(try await nearbyEventually(5) { waiting.messages.contains(.decline) })

        let again = try await greeted(port, as: "Evil again")
        defer { again.cleanUp() }
        again.send(.offer(NearbyOffer(items: [.text(excerpt: "Hi", length: 2)])))
        #expect(try await nearbyEventually(5) { again.messages.contains(.decline) })
        #expect(side.service.offers.isEmpty)
    }

    /// Files from a remembered Mac are checked against free space like anyone's.
    @Test(.timeLimit(.minutes(1)))
    func aRememberedMacsFilesMustFitToo() async throws {
        let friend = try NearbyHostilePeer()
        defer { friend.cleanUp() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaHostile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var list = NearbyRememberedList()
        list.remember(try #require(friend.publicKey), name: "Friend", at: Date())
        try list.save(to: file)

        let side = try NearbyTestSide(freeSpace: { _ in 1_000_000_000 })
        defer { side.cleanUp() }
        side.service.rememberedFile = file
        side.settings.nearbySharingEnabled = true
        side.service.start()
        try #require(try await nearbyEventually(20) { side.service.listeningPort != nil && side.service.status == .on })
        var tooLarge: [String] = []
        side.service.onRememberedOfferTooLarge = { tooLarge.append($0) }

        try #require(try await friend.connectUntilGreeted(to: try #require(side.service.listeningPort)))
        friend.send(.hello(NearbyHello(version: NearbyProtocol.version, name: "Friend")),
                    .offer(NearbyOffer(items: [.file(name: "big.mov", size: 500_000_000)])))
        #expect(try await nearbyEventually(5) { friend.messages.contains(.decline) })
        #expect(tooLarge == ["Friend"])
        #expect(side.service.offers.isEmpty)
    }

    // MARK: - What others learn

    /// The advertisement carries nothing but a random name, new with every change.
    @Test(.timeLimit(.minutes(1)))
    func theAdvertisementIsARandomNameAndNothingElse() async throws {
        let (side, _) = try await nearbyListeningSide()
        defer { side.cleanUp() }
        let name = try #require(side.service.advertisedName)
        #expect(name.wholeMatch(of: try Regex("[0-9a-f]{12}")) != nil)

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NearbyProtocol.serviceType, domain: nil), using: parameters)
        var found: NWBrowser.Result?
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                found = results.first { result in
                    if case let .service(serviceName, _, _, _) = result.endpoint { return serviceName == name }
                    return false
                }
            }
        }
        browser.start(queue: .main)
        defer { browser.cancel() }
        #expect(try await nearbyEventually(15) { found != nil })
        if case let .bonjour(record) = found?.metadata {
            #expect(record.dictionary.isEmpty)
        }

        // A new name for the Mac means a new advertised name.
        side.settings.nearbyName = "Renamed \(Int.random(in: 1000...9999))"
        #expect(try await nearbyEventually(5) { side.service.advertisedName != nil && side.service.advertisedName != name })
    }

    /// A tile's given name stays on this Mac: an offer carries the real file name, the
    /// address or the text, never the label.
    @Test func aTilesGivenNameIsNeverSent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaHostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: url)
        let label = "Secret label for the boss"
        var items = [ShelfItem.Draft(fileURL: url), ShelfItem.Draft(text: "Hello"),
                     ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!)].map { draft in
            ShelfItem(id: UUID(), kind: draft.kind, title: draft.title, source: draft.source,
                      storageMode: .reference, createdAt: Date(), sortOrder: 0)
        }
        for index in items.indices { items[index].customName = label }
        let prepared = try NearbyOutgoingItem.prepare(items).map(\.item)
        let offer = NearbyOffer(items: prepared.map(\.offerItem))
        let wire = String(decoding: try NearbyMessage.offer(offer).frame().dropFirst(4), as: UTF8.self)
        #expect(!wire.contains("Secret"))
        #expect(wire.contains("report.pdf"))
    }
}

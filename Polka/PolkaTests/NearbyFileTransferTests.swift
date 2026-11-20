import CoreGraphics
import CryptoKit
import Foundation
import Security
import Testing
@testable import Polka

/// Nearby Sharing, N3: files and the pictures that come with an offer. As in
/// `NearbyTransferTests`, most of these send what a hostile Mac might: names that try
/// to leave their folder, more bytes than offered, a file that isn't what was read,
/// pictures that aren't what they claim.

private func fileItem(_ url: URL, kind: ShelfItem.Kind = .file) -> ShelfItem {
    ShelfItem(id: UUID(), kind: kind, title: url.lastPathComponent,
              source: .file(path: url.path, bookmark: nil), storageMode: .reference,
              createdAt: Date(), expiresAt: nil, sortOrder: 0)
}

private func decode(_ json: String) throws -> NearbyMessage {
    try NearbyMessage.decode(Data(json.utf8))
}

/// A folder of its own for one test, deleted with `remove`.
private struct Scratch {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("PolkaNearbyFileTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var copies: ShelfCopies { ShelfCopies(folder: folder.appendingPathComponent("Copies", isDirectory: true)) }

    func file(_ name: String, bytes: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A file that says it's `size` bytes long without taking the space: APFS keeps it
    /// sparse.
    func sparseFile(_ name: String, size: Int64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Made in one go: byte by byte, 40 MB holds the main thread for seconds in a debug
/// build, and the services of tests running alongside pile up connections meanwhile.
private func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}

private func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

/// A real PNG of this size, as Core Graphics writes one.
private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = try #require(NearbyPreviewMaker.png(image))
    return data
}

private func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
}

// MARK: - Names

struct NearbyFileNameTests {
    @Test func aNameCantLeaveItsFolder() {
        #expect(NearbyFileName.clean("../../Library/LaunchAgents/x.plist") == "x.plist")
        #expect(NearbyFileName.clean("/etc/passwd") == "passwd")
        #expect(NearbyFileName.clean("a/b/") == "b")
        #expect(NearbyFileName.clean("..") == NearbyFileName.fallback)
        #expect(NearbyFileName.clean(".") == NearbyFileName.fallback)
        #expect(NearbyFileName.clean("/") == NearbyFileName.fallback)
        #expect(NearbyFileName.clean("") == NearbyFileName.fallback)
    }

    @Test func colonsAndInvisibleCharactersGo() {
        #expect(NearbyFileName.clean("a:b.txt") == "a-b.txt")
        // A right-to-left override would make "invoice\u{202E}fdp.app" read as "invoiceppa.pdf".
        #expect(NearbyFileName.clean("invoice\u{202E}fdp.app") == "invoicefdp.app")
        #expect(NearbyFileName.clean("a\u{0}b\nc.txt") == "abc.txt")
        #expect(NearbyFileName.clean("zero\u{200B}width.txt") == "zerowidth.txt")
    }

    @Test func aNameIsNeverHidden() {
        #expect(NearbyFileName.clean(".zshrc") == "zshrc")
        #expect(NearbyFileName.clean("  ...secret") == "secret")
    }

    @Test func aLongNameIsCutBeforeItsExtension() {
        let long = String(repeating: "я", count: 300) + ".pdf"
        let cleaned = NearbyFileName.clean(long)
        #expect(cleaned.utf8.count <= NearbyFileName.maxBytes)
        #expect(cleaned.hasSuffix(".pdf"))
    }

    @Test func appsScriptsAndInstallersAreMarked() {
        for name in ["Tool.app", "run.command", "a.sh", "Setup.pkg", "Disk.dmg", "x.terminal", "a.jar", "s.scpt"] {
            #expect(NearbyFileName.mayRun(name), "\(name)")
        }
        for name in ["report.pdf", "notes.txt", "photo.jpg", "README", "sheet.xlsx"] {
            #expect(!NearbyFileName.mayRun(name), "\(name)")
        }
    }
}

// MARK: - The wire

struct NearbyFileWireTests {
    @Test func aFileOfferWithPicturesSurvivesTheWire() throws {
        var offer = NearbyOffer(items: [.file(name: "report.pdf", size: 1234), .link(URL(string: "https://example.com/")!)])
        offer.previews = [0, 1]
        var reader = NearbyFrameReader()
        let frames = try reader.append(try NearbyMessage.offer(offer).frame())
        guard case let .message(payload) = frames.first else { Issue.record("no message"); return }
        #expect(try NearbyMessage.decode(payload) == .offer(offer))
    }

    @Test func aFileNameIsCleanedOnArrival() throws {
        let message = try decode(#"{"type":"offer","offer":{"items":[{"kind":"file","name":"../../.ssh/id_rsa","size":5}]}}"#)
        #expect(message == .offer(NearbyOffer(items: [.file(name: "id_rsa", size: 5)])))
    }

    @Test func filesOverOneGigabyteAreRefused() {
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"file","name":"a","size":600000000},{"kind":"file","name":"b","size":600000000}]}}"#)
        }
        #expect(throws: NearbyMessage.Failure.badOffer) {
            _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"file","name":"a","size":1000000001}]}}"#)
        }
    }

    @Test func aFileWithoutANameOrSizeOrWithANegativeOneIsRefused() {
        for item in [#"{"kind":"file","name":"a"}"#, #"{"kind":"file","size":3}"#, #"{"kind":"file","name":"a","size":-1}"#] {
            #expect(throws: NearbyMessage.Failure.badOffer) {
                _ = try decode(#"{"type":"offer","offer":{"items":[\#(item)]}}"#)
            }
        }
    }

    @Test func picturesAreAnnouncedOnlyForFilesAndLinksOnce() {
        for previews in ["[1]", "[0,0]", "[5]", "[-1]"] {
            #expect(throws: NearbyMessage.Failure.badOffer) {
                _ = try decode(#"{"type":"offer","offer":{"items":[{"kind":"file","name":"a","size":1},{"kind":"text","excerpt":"hi","length":2}],"previews":\#(previews)}}"#)
            }
        }
    }

    @Test func aPictureMustBeASmallPNG() throws {
        let good = try png(width: 64, height: 64)
        #expect(NearbyPreviewImage.size(of: good).map { $0.width == 64 && $0.height == 64 } == true)
        #expect(try decode(#"{"type":"preview","preview":{"index":0,"png":"\#(good.base64EncodedString())"}}"#)
            == .preview(NearbyPreview(index: 0, png: good)))

        // Not a PNG, too wide, too many bytes.
        let jpegish = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 100)
        var wide = good
        wide.replaceSubrange(16..<20, with: [0, 0, 2, 0])
        let heavy = good + Data(count: NearbyPreviewImage.maxBytes)
        for bad in [jpegish, wide, heavy, Data()] {
            #expect(!NearbyPreviewImage.isAcceptable(bad))
            #expect(throws: NearbyMessage.Failure.badItem) {
                _ = try decode(#"{"type":"preview","preview":{"index":0,"png":"\#(bad.base64EncodedString())"}}"#)
            }
        }
    }

    @Test func aFileEndMustCarryAWholeHash() {
        let short = Data(count: 16).base64EncodedString()
        #expect(throws: NearbyMessage.Failure.badItem) {
            _ = try decode(#"{"type":"fileEnd","fileEnd":{"index":0,"sha256":"\#(short)"}}"#)
        }
    }

    @Test func piecesAndMessagesArriveInOrder() throws {
        let bytes = randomBytes(70_000)
        var wire = try NearbyMessage.accept.frame()
        wire.append(NearbyFrame.pieceFrame(bytes))
        wire.append(try NearbyMessage.done.frame())
        var reader = NearbyFrameReader()
        var frames: [NearbyFrame] = []
        // In odd-sized bits, as a network hands them over.
        var offset = 0
        while offset < wire.count {
            let end = min(offset + 9_999, wire.count)
            frames += try reader.append(wire.subdata(in: offset..<end))
            offset = end
        }
        #expect(frames.count == 3)
        #expect(frames[1] == .piece(bytes))
        guard case let .message(last) = frames[2] else { Issue.record("no done"); return }
        #expect(try NearbyMessage.decode(last) == .done)
    }

    @Test func aPieceOverTheLimitIsRefusedBeforeItsRead() {
        var reader = NearbyFrameReader()
        let length = UInt32(NearbyProtocol.maxPieceBytes + 1) | NearbyFrame.pieceFlag
        let header = Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        #expect(throws: NearbyFrameReader.Failure.self) { _ = try reader.append(header) }
    }
}

// MARK: - The rules

struct NearbyIncomingFileTests {
    private let hello = NearbyMessage.hello(NearbyHello(version: NearbyProtocol.version, name: "Alex"))
    private let bytes = Data("Hello, file!".utf8)
    private var offer: NearbyOffer {
        var offer = NearbyOffer(items: [.file(name: "a.txt", size: Int64(bytes.count)), .file(name: "empty", size: 0)])
        offer.previews = [0]
        return offer
    }

    private func offered() throws -> NearbyIncomingTransfer {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        #expect(try rules.read(.offer(offer)) == .nothing)
        let picture = try png(width: 8, height: 8)
        #expect(try rules.read(.preview(NearbyPreview(index: 0, png: picture))) == .offered(offer, previews: [0: picture]))
        return rules
    }

    private func accepted() throws -> NearbyIncomingTransfer {
        var rules = try offered()
        _ = rules.answer(accept: true)
        return rules
    }

    @Test func filesArriveInOrderAndInFull() throws {
        var rules = try accepted()
        #expect(try rules.readPiece(count: 5) == .piece(index: 0))
        #expect(try rules.readPiece(count: bytes.count - 5) == .piece(index: 0))
        #expect(rules.receivedBytes == Int64(bytes.count))
        let hash = sha256(bytes)
        #expect(try rules.read(.fileEnd(NearbyFileEnd(index: 0, sha256: hash))) == .fileEnded(index: 0, sha256: hash))
        // A file with no bytes only ends.
        let empty = sha256(Data())
        #expect(try rules.read(.fileEnd(NearbyFileEnd(index: 1, sha256: empty))) == .fileEnded(index: 1, sha256: empty))
        #expect(try rules.read(.done) == .complete(links: [:], texts: [:]))
    }

    @Test func theOfferWaitsForEveryAnnouncedPicture() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        #expect(try rules.read(.offer(offer)) == .nothing)
        #expect(rules.stage == .previews)
        #expect(rules.answer(accept: true) == nil)
    }

    @Test func aPictureNobodyAnnouncedOrSentTwiceIsRefused() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(hello)
        _ = try rules.read(.offer(offer))
        let picture = try png(width: 8, height: 8)
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.preview(NearbyPreview(index: 1, png: picture)))
        }
        var later = try offered()
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) {
            _ = try later.read(.preview(NearbyPreview(index: 0, png: picture)))
        }
    }

    @Test func piecesBeforeAcceptAreRefused() throws {
        var rules = try offered()
        #expect(throws: NearbyIncomingTransfer.Failure.outOfTurn) { _ = try rules.readPiece(count: 1) }
    }

    @Test func oneByteMoreThanOfferedIsRefused() throws {
        var rules = try accepted()
        _ = try rules.readPiece(count: bytes.count)
        // The next file has no bytes, so this belongs to nothing.
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) { _ = try rules.readPiece(count: 1) }
        var again = try accepted()
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) { _ = try again.readPiece(count: bytes.count + 1) }
    }

    @Test func aFileCantEndEarlyOrOutOfOrder() throws {
        var rules = try accepted()
        _ = try rules.readPiece(count: 3)
        let hash = sha256(bytes)
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try rules.read(.fileEnd(NearbyFileEnd(index: 0, sha256: hash)))
        }
        var other = try accepted()
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) {
            _ = try other.read(.fileEnd(NearbyFileEnd(index: 1, sha256: hash)))
        }
    }

    @Test func doneBeforeEveryFileIsRefused() throws {
        var rules = try accepted()
        #expect(throws: NearbyIncomingTransfer.Failure.notWhatWasOffered) { _ = try rules.read(.done) }
    }

    @Test func aVersionWithoutFilesCantOfferThem() throws {
        var rules = NearbyIncomingTransfer()
        _ = try rules.read(.hello(NearbyHello(version: 2, name: "Old")))
        #expect(throws: NearbyIncomingTransfer.Failure.tooOld) { _ = try rules.read(.offer(offer)) }
    }

    @Test func theSenderCanStopIt() throws {
        var rules = try accepted()
        _ = try rules.readPiece(count: 2)
        #expect(throws: NearbyIncomingTransfer.Failure.cancelled) { _ = try rules.read(.cancel) }
        #expect(rules.stage == .finished)
    }

    @Test func stoppingHereTellsTheSender() throws {
        var rules = try accepted()
        #expect(rules.cancel() == .cancel)
        #expect(rules.cancel() == nil)
    }
}

struct NearbyOutgoingFileTests {
    @Test func aFileIsSentAsItsNameAndSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let url = try scratch.file("report.pdf", bytes: randomBytes(1_000))
        let folder = scratch.folder.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prepared = try NearbyOutgoingItem.prepare([fileItem(url), fileItem(folder, kind: .folder)])
        #expect(prepared.map(\.item) == [.file(url: url, name: "report.pdf", size: 1_000)])
    }

    @Test func aKeptCopySendsItsOriginalWhileItsThere() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let original = try scratch.file("original.txt", bytes: Data("real".utf8))
        let copy = try scratch.file("copy.txt", bytes: Data("old copy".utf8))
        var item = fileItem(copy)
        item.storageMode = .copy
        item.original = ShelfItem.Original(path: original.path, bookmark: nil)
        let prepared = try NearbyOutgoingItem.prepare([item])
        #expect(prepared.map(\.item) == [.file(url: original, name: "original.txt", size: 4)])
    }

    @Test func moreThanOneGigabyteIsTooLarge() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let big = try scratch.sparseFile("big.mov", size: 700_000_000)
        let other = try scratch.sparseFile("other.mov", size: 400_000_000)
        #expect(throws: NearbyOutgoingItem.Failure.tooLarge) {
            _ = try NearbyOutgoingItem.prepare([fileItem(big), fileItem(other)])
        }
        #expect(try NearbyOutgoingItem.prepare([fileItem(big)]).count == 1)
    }

    @Test func picturesGoRightAfterTheOffer() throws {
        let picture = try png(width: 16, height: 16)
        var transfer = NearbyOutgoingTransfer(items: [.file(url: URL(fileURLWithPath: "/tmp/a"), name: "a", size: 3), .text("Hi")],
                                              previews: [0: picture, 1: picture])
        let step = try transfer.read(.hello(NearbyHello(version: NearbyProtocol.version, name: "Sam")))
        var offer = NearbyOffer(items: [.file(name: "a", size: 3), .text(excerpt: "Hi", length: 2)])
        // Text never has a picture: the other Mac draws its page.
        offer.previews = [0]
        #expect(step.send == [.offer(offer), .preview(NearbyPreview(index: 0, png: picture))])
    }

    @Test func aMacOnVersionTwoGetsNoFilesOrPictures() throws {
        let picture = try png(width: 16, height: 16)
        var files = NearbyOutgoingTransfer(items: [.file(url: URL(fileURLWithPath: "/tmp/a"), name: "a", size: 3)])
        #expect(throws: NearbyOutgoingTransfer.Failure.tooOld) {
            _ = try files.read(.hello(NearbyHello(version: 2, name: "Old")))
        }
        var links = NearbyOutgoingTransfer(items: [.link(URL(string: "https://example.com/")!)], previews: [0: picture])
        let step = try links.read(.hello(NearbyHello(version: 2, name: "Old")))
        #expect(step.send == [.offer(NearbyOffer(items: [.link(URL(string: "https://example.com/")!)]))])
        _ = try links.read(.accept)
        // Version 2 doesn't know `cancel`; the connection just closes.
        #expect(links.cancel() == nil)
    }

    @Test func aLargePictureIsDrawnSmallerToFit() throws {
        let context = try #require(CGContext(data: nil, width: 512, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = try #require(NearbyPreviewMaker.png(image))
        let size = try #require(NearbyPreviewImage.size(of: data))
        #expect(size.width == 256 && size.height == 150)
    }
}

// MARK: - Disk

@MainActor
struct NearbyFileDiskTests {
    @Test func aCheckedFileIsQuarantinedAndNamed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let bytes = randomBytes(600_000)
        let sink = NearbyFileSink(copies: scratch.copies, names: [2: "report.pdf"])
        sink.write(bytes.prefix(300_000), to: 2)
        sink.write(bytes.dropFirst(300_000), to: 2)
        sink.end(2, sha256: sha256(bytes))
        let files = try #require(await withCheckedContinuation { continuation in
            sink.handOver { continuation.resume(returning: $0) }
        })
        let url = try #require(files[2])
        #expect(url.lastPathComponent == "report.pdf")
        #expect(scratch.copies.folderName(containing: url.path) != nil)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(hasQuarantine(url))
        // No `.partial` left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["report.pdf"])
    }

    @Test func aFileThatDoesntMatchItsHashIsThrownAway() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sink = NearbyFileSink(copies: scratch.copies, names: [0: "a.txt"])
        var failures: [NearbyFileSink.Failure] = []
        sink.onFailure = { failures.append($0) }
        sink.write(Data("not what was read".utf8), to: 0)
        sink.end(0, sha256: sha256(Data("what was read".utf8)))
        let files = await withCheckedContinuation { continuation in
            sink.handOver { continuation.resume(returning: $0) }
        }
        #expect(files == nil)
        #expect(try await nearbyEventually(2) { failures == [.hashMismatch] })
        sink.discard()
        #expect(try await nearbyEventually(2) { scratch.copies.folderNames().isEmpty })
    }

    @Test func discardingRemovesWhatWasWritten() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sink = NearbyFileSink(copies: scratch.copies, names: [0: "a.bin"])
        sink.write(randomBytes(1_000), to: 0)
        #expect(try await nearbyEventually(2) { scratch.copies.folderNames().count == 1 })
        sink.discard()
        #expect(try await nearbyEventually(2) { scratch.copies.folderNames().isEmpty })
    }

    @Test func aSourceHashesExactlyWhatItSends() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let bytes = randomBytes(NearbyProtocol.maxPieceBytes * 2 + 123)
        let url = try scratch.file("a.bin", bytes: bytes)
        // Says it's shorter than it is: only that much goes.
        let declared = bytes.count - 100
        let source = NearbyFileSource(url: url, size: Int64(declared))
        var sent = Data()
        while true {
            let chunk = await withCheckedContinuation { continuation in
                source.next { continuation.resume(returning: $0) }
            }
            switch chunk {
            case let .success(.piece(piece)):
                #expect(piece.count <= NearbyProtocol.maxPieceBytes)
                sent.append(piece)
            case let .success(.end(hash)):
                #expect(sent == bytes.prefix(declared))
                #expect(hash == sha256(bytes.prefix(declared)))
                return
            case .failure:
                Issue.record("couldn't read")
                return
            }
        }
    }

    @Test func aFileThatShrankFails() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let url = try scratch.file("a.bin", bytes: randomBytes(10))
        let source = NearbyFileSource(url: url, size: 20)
        var result: Result<NearbyFileSource.Chunk, NearbyFileSource.Failure>?
        repeat {
            result = await withCheckedContinuation { continuation in
                source.next { continuation.resume(returning: $0) }
            }
        } while (try? result?.get()).map { if case .piece = $0 { return true } else { return false } } == true
        #expect(result == .failure(.changed))
    }
}

// MARK: - Between two services

@MainActor
struct NearbyFileSendingTests {
    private func found(_ receiver: NearbyTestSide, from sender: NearbyTestSide) async throws -> String {
        let name = "Receiver \(Int.random(in: 1000...9999))"
        receiver.settings.nearbyName = name
        sender.settings.nearbyName = "Sender \(Int.random(in: 1000...9999))"
        receiver.settings.nearbySharingEnabled = true
        sender.settings.nearbySharingEnabled = true
        receiver.service.start()
        sender.service.start()
        sender.service.beginBrowsing()
        try #require(try await nearbyEventually(30) { sender.service.peers.contains { $0.name == name } })
        return try #require(sender.service.peers.first { $0.name == name }).id
    }

    private func waitForOffer(_ receiver: NearbyTestSide) async throws -> NearbyIncomingOffer {
        try #require(try await nearbyEventually(15) { !receiver.service.offers.isEmpty })
        return try #require(receiver.service.offers.first)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFileCrossesWholeQuarantinedAndWithItsPicture() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide()
        let scratch = try Scratch()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
            scratch.remove()
        }
        let peerID = try await found(receiver, from: sender)
        var received: [NearbyReceivedItem] = []
        receiver.service.onReceived = { items, _, _ in received = items }
        var progress: [Double] = []
        let observer = receiver.service.$receiving.sink { progress += $0.map(\.fraction) }
        defer { observer.cancel() }

        let bytes = randomBytes(3_000_000)
        let file = try scratch.file("Report: final.bin", bytes: bytes)
        let picture = try scratch.file("Picture.png", bytes: try png(width: 200, height: 120))
        var statuses: [NearbyOutgoingSession.Status] = []
        let items = [fileItem(file), shelfItemText("Notes"), fileItem(picture)]
        #expect(sender.service.send(items, to: peerID) { statuses.append($0) } != nil)

        let offer = try await waitForOffer(receiver)
        #expect(offer.offer.items == [.file(name: "Report- final.bin", size: 3_000_000),
                                      .text(excerpt: "Notes", length: 5),
                                      .file(name: "Picture.png", size: Int64(try Data(contentsOf: picture).count))])
        // Quick Look drew the picture file; whatever it gives must pass the checks.
        for data in offer.pictures.values { #expect(NearbyPreviewImage.isAcceptable(data)) }
        #expect(receiver.service.accept(offer.id) == .accepted)
        #expect(try await nearbyEventually(30) { statuses.last == .sent })
        #expect(statuses.contains { if case .sending = $0 { return true } else { return false } })
        #expect(received.count == 3)
        guard case let .file(url) = received.first else { Issue.record("no file"); return }
        #expect(url.lastPathComponent == "Report- final.bin")
        #expect(receiver.copies.folderName(containing: url.path) != nil)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(hasQuarantine(url))
        #expect(received[1] == .text("Notes"))
        #expect(receiver.service.receiving.isEmpty)
        #expect(progress.contains { $0 > 0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingOnEitherSideLeavesNothingBehind() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide()
        let scratch = try Scratch()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
            scratch.remove()
        }
        let peerID = try await found(receiver, from: sender)
        var failures: [Bool] = []
        receiver.service.onReceiveFailed = { _, byThem in failures.append(byThem) }
        var received = 0
        receiver.service.onReceived = { _, _, _ in received += 1 }
        let file = try scratch.file("big.bin", bytes: randomBytes(40_000_000))

        // The receiver stops it: no message for them, nothing kept.
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(sender.service.send([fileItem(file)], to: peerID) { statuses.append($0) } != nil)
        var offer = try await waitForOffer(receiver)
        #expect(receiver.service.accept(offer.id) == .accepted)
        receiver.service.cancelReceiving(offer.id)
        #expect(try await nearbyEventually(15) { statuses.last?.isFinished == true })
        #expect(statuses.last == .cancelled || statuses.last == .failed(.unreachable))
        #expect(try await nearbyEventually(5) { receiver.copies.folderNames().isEmpty })
        #expect(failures.isEmpty)

        // The sender stops it as soon as it starts sending, since over loopback it's
        // done in a blink: the receiver says so, and keeps nothing.
        statuses = []
        var sendID: UUID?
        sendID = sender.service.send([fileItem(file)], to: peerID) { status in
            statuses.append(status)
            if case .sending = status, let sendID { sender.service.cancelSending(sendID) }
        }
        #expect(sendID != nil)
        offer = try await waitForOffer(receiver)
        #expect(receiver.service.accept(offer.id) == .accepted)
        #expect(try await nearbyEventually(10) { statuses.last == .cancelled })
        #expect(try await nearbyEventually(15) { !failures.isEmpty })
        #expect(failures == [true])
        #expect(try await nearbyEventually(5) { receiver.copies.folderNames().isEmpty })
        #expect(received == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func filesThatDontFitOnTheDiskAreDeclined() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide(freeSpace: { _ in 2_000_000_100 })
        let scratch = try Scratch()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
            scratch.remove()
        }
        let peerID = try await found(receiver, from: sender)
        let file = try scratch.file("a.bin", bytes: randomBytes(1_000))
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(sender.service.send([fileItem(file)], to: peerID) { statuses.append($0) } != nil)
        let offer = try await waitForOffer(receiver)
        #expect(receiver.service.accept(offer.id) == .notEnoughSpace)
        #expect(try await nearbyEventually(10) { statuses.last == .declined })
    }

    @Test(.timeLimit(.minutes(1)))
    func moreThanOneGigabyteNeverLeaves() async throws {
        let sender = try NearbyTestSide()
        let receiver = try NearbyTestSide()
        let scratch = try Scratch()
        defer {
            sender.cleanUp()
            receiver.cleanUp()
            scratch.remove()
        }
        let peerID = try await found(receiver, from: sender)
        let big = try scratch.sparseFile("big.mov", size: 1_100_000_000)
        var statuses: [NearbyOutgoingSession.Status] = []
        #expect(sender.service.send([fileItem(big)], to: peerID) { statuses.append($0) } != nil)
        #expect(try await nearbyEventually(10) { statuses.last == .failed(.tooLarge) })
        try await Task.sleep(for: .milliseconds(500))
        #expect(receiver.service.offers.isEmpty)
    }
}

private func shelfItemText(_ text: String) -> ShelfItem {
    ShelfItem(id: UUID(), kind: .text, title: text, source: .text(text), storageMode: .reference,
              createdAt: Date(), expiresAt: nil, sortOrder: 0)
}

// MARK: - The panel

@MainActor
struct NearbyFileOfferPanelTests {
    @Test func aPictureIsDecodedOnlyIfItsReallyASmallPNG() throws {
        let good = try png(width: 40, height: 30)
        let image = try #require(NearbyPreviewImage.decode(good))
        #expect(image.width == 40 && image.height == 30)
        // A header that claims another size than the picture has.
        var lying = good
        lying.replaceSubrange(16..<20, with: [0, 0, 0, 41])
        #expect(NearbyPreviewImage.decode(lying) == nil)
        #expect(NearbyPreviewImage.decode(Data("GIF89a".utf8) + Data(count: 40)) == nil)
    }

    @Test func anOfferedFileIsATileNamedHereThatPointsNowhere() {
        var offer = NearbyOffer(items: [.file(name: "Report.pdf", size: 10), .text(excerpt: "Hi", length: 2)])
        offer.previews = [0]
        let incoming = NearbyIncomingOffer(id: UUID(), senderName: "Alex", fingerprint: "A", offer: offer,
                                           pictures: [0: Data([1, 2, 3])])
        let tile = incoming.previews[0]
        #expect(tile.kind == .file)
        #expect(tile.displayName == "Report.pdf")
        #expect(tile.typeLabel == "PDF")
        #expect(tile.url.path.hasPrefix(NearbyIncomingOffer.placeholderFolder))
        #expect(!FileManager.default.fileExists(atPath: tile.url.path))
        // Pictures follow their tiles.
        #expect(incoming.pictures == [tile.id: Data([1, 2, 3])])
    }

    @Test func aReceivedFileBecomesACopyWithNoOriginal() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let url = try scratch.file("Report.pdf", bytes: Data("pdf".utf8))
        let draft = NearbyReceivedItem.file(url).draft(from: "Alex")
        #expect(draft.kind == .file)
        #expect(draft.storageMode == .copy)
        #expect(draft.receivedFrom == "Alex")
        #expect(draft.title == "Report.pdf")
    }

    @Test func theReceivingMessagesCrossStopsIt() {
        let model = NotchViewModel(store: ShelfStore())
        var stopped: [UUID] = []
        model.onCancelReceiving = { stopped.append($0) }
        let id = UUID()
        model.nearbyReceiving = [NearbyReceiving(id: id, senderName: "Alex", itemCount: 2, receivedBytes: 5, totalBytes: 10)]
        model.cancelReceiving(id)
        #expect(stopped == [id])
        #expect(model.nearbyReceiving.first?.fraction == 0.5)
    }

    @Test func whySomethingDidntArriveIsSaid() {
        let model = NotchViewModel(store: ShelfStore())
        model.receiveNearbyFailed(from: "Alex", cancelledByThem: true)
        #expect(model.notice == "Alex stopped sending")
        model.receiveNearbyFailed(from: "Alex", cancelledByThem: false)
        #expect(model.notice == "Couldn't receive what Alex shared")
    }
}

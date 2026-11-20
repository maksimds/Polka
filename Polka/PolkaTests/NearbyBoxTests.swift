import AppKit
import Foundation
import Testing
@testable import Polka

/// N5: what a drag can send to a Mac, and what the Send To box shows.
@MainActor
struct NearbyBoxTests {
    private let example = URL(string: "https://example.com/page")!

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkaBox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func filesLinksAndTextCanBeSentButFoldersAndOtherAddressesCant() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: file)
        let sub = folder.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let sentFile = try #require(DroppedItem.file(file).itemToSend)
        #expect(sentFile.kind == .file)
        #expect(sentFile.title == "report.pdf")
        #expect(sentFile.urlToOpen().standardizedFileURL == file.standardizedFileURL)
        #expect(DroppedItem.file(sub).itemToSend == nil)
        #expect(DroppedItem.file(folder.appendingPathComponent("gone.pdf")).itemToSend == nil)
        #expect(DroppedItem.link(example).itemToSend?.kind == .link)
        #expect(DroppedItem.text("Hello").itemToSend?.kind == .text)
        #expect(DroppedItem.refusedLink(URL(string: "smb://server/share")!).itemToSend == nil)
    }

    @Test func aDragsPasteboardIsReadForWhatCanGo() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PolkaBoxTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, folder as NSURL])
        #expect(DropReceiver.itemsToSend(from: pasteboard).map(\.title) == ["notes.txt"])

        pasteboard.clearContents()
        pasteboard.setString("Some selected words", forType: .string)
        #expect(DropReceiver.itemsToSend(from: pasteboard).map(\.kind) == [.text])

        pasteboard.clearContents()
        pasteboard.setString(example.absoluteString, forType: .string)
        #expect(DropReceiver.itemsToSend(from: pasteboard).map(\.kind) == [.link])

        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        #expect(DropReceiver.itemsToSend(from: pasteboard).isEmpty)
    }

    @Test func aTileDragSendsWhatSendToWould() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShelfStore()
        store.add([ShelfItem.Draft(text: "Note"), ShelfItem.Draft(fileURL: folder), ShelfItem.Draft(linkURL: example)])
        let model = NotchViewModel(store: store)
        #expect(model.tileMoveItemsToSend.isEmpty)
        let items = store.items
        model.beginTileMove(ShelfDragContents(items: [items[2], items[1], items[0]], staysOnShelf: false))
        // The folder stays behind; the rest keep the drag's order.
        #expect(model.tileMoveItemsToSend.map(\.id) == [items[2].id, items[0].id])
        model.endTileMove()
        #expect(model.tileMoveItemsToSend.isEmpty)
    }

    private func peer(_ name: String, version: Int = NearbyProtocol.version, remembered: Bool = false,
                      key: UInt8? = nil) -> NearbyService.Peer {
        NearbyService.Peer(id: "id-\(name)", heardName: name, fingerprint: nil,
                           publicKey: key.map { Data([0x04] + Array(repeating: $0, count: 64)) },
                           isPeerToPeer: true, version: version, rememberedName: remembered ? name : nil)
    }

    @Test func eachMacIsItsInitialOnAColorFromItsKey() {
        let alex = NearbyBoxModel.mac(peer("Alex\u{2019}s MacBook Pro", remembered: true, key: 1), carryingFiles: true)
        #expect(alex.initial == "A")
        #expect(alex.isRemembered)
        #expect(alex.canTake)
        #expect(NearbyBoxModel.initial(of: "  9 Lives") == "9")
        #expect(NearbyBoxModel.initial(of: "\u{1F4BB}") == "?")
        #expect(NearbyBoxModel.initial(of: "\u{430}lex") == "\u{410}")
        // The same key, the same color; another key, most likely another.
        let again = NearbyBoxModel.mac(peer("Renamed", key: 1), carryingFiles: false)
        #expect(again.hue == alex.hue)
        #expect((0..<1).contains(alex.hue))
        #expect(NearbyBoxModel.mac(peer("Sam", key: 2), carryingFiles: false).hue != alex.hue)
    }

    @Test func anOlderPolkaIsDimmedForWhatItCantTake() {
        let n2 = peer("Old", version: NearbyProtocol.offerVersion)
        #expect(NearbyBoxModel.mac(n2, carryingFiles: false).canTake)
        let withFiles = NearbyBoxModel.mac(n2, carryingFiles: true)
        #expect(!withFiles.canTake)
        #expect(withFiles.note == "Needs a newer Polka")
        #expect(!NearbyBoxModel.mac(peer("Older", version: 1), carryingFiles: false).canTake)
    }

    @Test func whileDraggingEveryMacShowsAndAfterOnlyTheSends() {
        let model = NearbyBoxModel()
        let alex = NearbyBoxModel.mac(peer("Alex"), carryingFiles: false)
        let sam = NearbyBoxModel.mac(peer("Sam"), carryingFiles: false)
        model.macs = [alex, sam]
        #expect(!model.wantsToShow)
        model.isDragging = true
        #expect(model.wantsToShow)
        #expect(model.rows.map(\.mac.name) == ["Alex", "Sam"])
        let send = NearbyBoxModel.Send(id: UUID(), mac: sam, status: "Waiting\u{2026}")
        model.sends = [send]
        #expect(model.rows.map(\.send) == [nil, send])
        model.isDragging = false
        #expect(model.wantsToShow)
        #expect(model.rows.map(\.mac.name) == ["Sam"])
        model.sends = []
        #expect(!model.wantsToShow)
    }

    @Test func aSendSaysHowItsGoing() {
        #expect(NearbyBoxModel.words(for: .waiting).text == "Waiting\u{2026}")
        #expect(NearbyBoxModel.words(for: .waiting).fraction == nil)
        #expect(NearbyBoxModel.words(for: .sending(0.4)) == ("Sending 40%", 0.4))
        #expect(NearbyBoxModel.words(for: .sent).text == "Sent")
        #expect(NearbyBoxModel.words(for: .declined).text == "Declined")
        #expect(NearbyBoxModel.words(for: .failed(.tooLarge)).text == "Over 1 GB")
    }

    /// Without being placed, the box never makes its window, so this opens none.
    @Test func aSendStaysInTheBoxUntilAMomentAfterItEnds() async throws {
        let box = NearbyBoxController()
        let transfer = UUID()
        box.addSend(transfer, to: NearbyBoxModel.mac(peer("Alex"), carryingFiles: false))
        #expect(box.model.sends.map(\.status) == ["Waiting\u{2026}"])
        box.update(transfer, .sending(0.5))
        #expect(box.model.sends.first?.status == "Sending 50%")
        #expect(box.model.sends.first?.fraction == 0.5)
        box.update(transfer, .sent)
        #expect(box.model.sends.first?.isFinished == true)
        #expect(box.model.sends.first?.succeeded == true)
        // A late word doesn't bring it back to life.
        box.update(transfer, .sending(0.9))
        #expect(box.model.sends.first?.isFinished == true)
        #expect(try await nearbyEventually(4) { box.model.sends.isEmpty })
        #expect(!box.model.wantsToShow)
        #expect(!box.contains(NSEvent.mouseLocation))
    }

    /// AppKit can report a drag's end before it hands the box the drop: the box keeps
    /// listing the Macs for it, a moment at most.
    @Test func aDropThatArrivesAfterTheDragEndedStillFindsTheMacs() async throws {
        let box = NearbyBoxController()
        let alex = NearbyBoxModel.mac(peer("Alex"), carryingFiles: false)
        box.model.macs = [alex]
        box.awaitDrop()
        #expect(box.model.listsMacs)
        #expect(box.model.wantsToShow)
        #expect(box.model.rows.map(\.mac.name) == ["Alex"])
        #expect(try await nearbyEventually(3) { !box.model.isAwaitingDrop })
        #expect(!box.model.wantsToShow)

        // The drop arrives: its send takes over, and the wait is over.
        box.awaitDrop()
        box.addSend(UUID(), to: alex)
        #expect(!box.model.isAwaitingDrop)
        #expect(box.model.wantsToShow)
        #expect(box.model.rows.map(\.send?.status) == ["Waiting\u{2026}"])
    }

    /// The gap between the shelf and the box is part of the way, not a drag out.
    @Test func theWayFromTheShelfToTheBoxCountsAsTheShelf() {
        let shelf = CGRect(x: 500, y: 600, width: 520, height: 270)
        let box = CGRect(x: 254, y: 760, width: 232, height: 110)
        let area = NearbyBoxController.area(box: box, shelf: shelf)
        // In the 14 pt gap, and below the box beside the shelf.
        #expect(area.contains(CGPoint(x: 493, y: 800)))
        #expect(area.contains(CGPoint(x: 400, y: 650)))
        // Past the box's left edge, or below the shelf, it's a drag out.
        #expect(!area.contains(CGPoint(x: 250, y: 800)))
        #expect(!area.contains(CGPoint(x: 700, y: 590)))
        // Without the box, only the shelf.
        #expect(NearbyBoxController.area(box: nil, shelf: shelf) == shelf)
    }

    @Test func theRowUnderThePointerIsTheMacToDropOn() {
        let geometry = NearbyBoxGeometry()
        geometry.rows = ["a": CGRect(x: 0, y: 30, width: 200, height: 44),
                         "b": CGRect(x: 0, y: 74, width: 200, height: 44)]
        #expect(geometry.mac(at: CGPoint(x: 50, y: 40)) == "a")
        #expect(geometry.mac(at: CGPoint(x: 50, y: 100)) == "b")
        #expect(geometry.mac(at: CGPoint(x: 50, y: 10)) == nil)
    }
}

import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Polka

/// Test pictures, made in memory.
private enum TestPictures {
    static func bitmap() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)!
    }

    static func png() -> Data {
        bitmap().representation(using: .png, properties: [:])!
    }

    static func tiff() -> Data {
        bitmap().tiffRepresentation!
    }

    static func isPNG(_ data: Data) -> Bool {
        data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// A shelf.json that can't be read, like one written by a newer version.
private struct UnreadableShelf: ShelfPersistence {
    struct Failure: Error {}

    func load() throws -> [ShelfItem] { throw Failure() }
    func save(_ items: [ShelfItem]) throws {}
}

/// A clipboard of its own, so tests never touch the real one.
private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    fill(pasteboard)
    return pasteboard
}

// MARK: - Text items

/// Text on the shelf (FR-19): its name, its type, where it sorts, and how it's saved.
@MainActor
struct TextItemTests {
    @Test func aTextIsNamedAfterItsFirstLineWithSomethingOnIt() {
        #expect(ShelfItem.Draft(text: "  Hello   world  \nsecond line").title == "Hello world")
        #expect(ShelfItem.Draft(text: "\n\n   \nFirst real line\nmore").title == "First real line")
        #expect(ShelfItem.Draft(text: "   ").title == "Text")
    }

    @Test func aLongFirstLineIsCutShort() {
        let title = ShelfItem.Draft(text: String(repeating: "word ", count: 30)).title
        #expect(title.hasSuffix("…"))
        #expect(title.count <= ShelfItem.Draft.maxTextTitleLength + 1)
        #expect(!title.dropLast().hasSuffix(" "))
    }

    @Test func aTextItemKeepsAllOfItsText() {
        let store = ShelfStore()
        let text = "First line\n\tindented second line\n"

        store.add([ShelfItem.Draft(text: text)])

        #expect(store.items.count == 1)
        #expect(store.items[0].kind == .text)
        #expect(store.items[0].source == .text(text))
        #expect(store.items[0].typeLabel == "Text")
        #expect(!store.items[0].isTemporary)
    }

    @Test func theSameTextTwiceIsADuplicate() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(text: "note")])

        let result = store.add([ShelfItem.Draft(text: "note"), ShelfItem.Draft(text: "another note")])

        #expect(result.duplicates.map(\.title) == ["note"])
        #expect(store.items.map(\.title) == ["another note", "note"])
    }

    @Test func kindPutsTextAfterLinks() {
        let store = ShelfStore(sort: .kind)
        store.add([ShelfItem.Draft(text: "a note"),
                   ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"))])

        #expect(store.sort.groups(of: store.items).map(\.title) == ["Files", "Links", "Text"])
    }

    @Test func fileTypePutsTextLast() {
        let store = ShelfStore(sort: .fileType)
        store.add([ShelfItem.Draft(text: "a note"),
                   ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/notes"))])

        #expect(store.sort.groups(of: store.items).map(\.title) == ["Other", "Links", "Text"])
    }

    @Test func textAndAScreenshotSurviveARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var screenshot = ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/Screenshot.png"), storageMode: .copy)
        screenshot.origin = .screenshot
        screenshot.lifetime = 3600

        let store = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))
        store.add([ShelfItem.Draft(text: "Привет, мир\nsecond line"), screenshot])
        let reloaded = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))

        #expect(reloaded.items == store.items)
        #expect(reloaded.items[0].source == .text("Привет, мир\nsecond line"))
        #expect(reloaded.items[1].origin == .screenshot)
        #expect(reloaded.items[1].isTemporary)
    }

    @Test func draggingTextOutGivesTheText() {
        let item = ShelfStore().add([ShelfItem.Draft(text: "copy me")]).added[0]
        let writer = ShelfDragSource.pasteboardWriter(for: item) as? NSPasteboardItem

        #expect(writer?.string(forType: .string) == "copy me")
        #expect(writer?.string(forType: .URL) == nil)
    }

    /// A shelf with text on it can't be read by a version from before text existed, and
    /// any shelf may one day be newer than the version reading it. Its links' saved
    /// icons stay, so they're still there once the file is put back.
    @Test func anUnreadableShelfKeepsItsLinksIcons() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = folder.appendingPathComponent("\(UUID().uuidString).png")
        try TestPictures.png().write(to: icon)
        let store = ShelfStore(persistence: UnreadableShelf())
        #expect(store.loadFailed)

        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { _ in .init() }
        fetcher.start()

        #expect(FileManager.default.fileExists(atPath: icon.path))
    }

    @Test func aTextItemsPictureIsAPage() {
        let page = ShelfItemImages.textPage(for: "Some text")

        #expect(page.size == ShelfItemImages.textPageSize)
        #expect(page.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
}

// MARK: - Reading the clipboard

/// What "Paste" offers for what's on the clipboard, and what it calls it.
@MainActor
struct PasteReaderTests {
    @Test func copiedFilesAreFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: file)

        let one = PasteReader.contents(of: pasteboard { $0.writeObjects([file as NSURL]) })
        let both = PasteReader.contents(of: pasteboard { $0.writeObjects([file as NSURL, folder as NSURL]) })
        let justFolder = PasteReader.contents(of: pasteboard { $0.writeObjects([folder as NSURL]) })

        #expect(one?.menuTitle == "Paste File")
        #expect(both?.menuTitle == "Paste 2 Items")
        #expect(justFolder?.menuTitle == "Paste Folder")
        guard case .files(let urls) = both else {
            Issue.record("Expected files, got \(String(describing: both))")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["report.pdf", "Project"])
    }

    @Test func plainTextIsText() {
        let contents = PasteReader.contents(of: pasteboard { $0.setString("Meeting notes\nline two", forType: .string) })

        #expect(contents == .text("Meeting notes\nline two"))
        #expect(contents?.menuTitle == "Paste Text")
    }

    @Test func textThatIsJustAWebAddressIsALink() {
        let contents = PasteReader.contents(of: pasteboard {
            $0.setString("  https://Example.com/page \n", forType: .string)
        })

        #expect(contents == .links([URL(string: "https://example.com/page")!]))
        #expect(contents?.menuTitle == "Paste Link")
    }

    /// In a document, "example.com" or "notes.txt" is more likely a word than a link.
    @Test func anAddressWithoutASchemeStaysText() {
        #expect(PasteReader.contents(of: pasteboard { $0.setString("example.com", forType: .string) })
                == .text("example.com"))
        #expect(PasteReader.contents(of: pasteboard { $0.setString("mailto:someone@example.com", forType: .string) })
                == .text("mailto:someone@example.com"))
    }

    @Test func aBrowsersCopyLinkIsALink() {
        let contents = PasteReader.contents(of: pasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setString("https://github.com/apple/swift", forType: .URL)
            item.setString("https://github.com/apple/swift", forType: .string)
            pasteboard.writeObjects([item])
        })

        #expect(contents == .links([URL(string: "https://github.com/apple/swift")!]))
    }

    @Test func aPictureOnItsOwnIsAPicture() {
        let contents = PasteReader.contents(of: pasteboard { $0.setData(TestPictures.png(), forType: .png) })

        #expect(contents == .image)
        #expect(contents?.menuTitle == "Paste Image")
    }

    /// A browser's "Copy Image" offers the picture and its address.
    @Test func aPictureWithItsAddressIsThePicture() {
        let contents = PasteReader.contents(of: pasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setData(TestPictures.tiff(), forType: .tiff)
            item.setString("https://example.com/photo.jpg", forType: .string)
            pasteboard.writeObjects([item])
        })

        #expect(contents == .image)
    }

    /// Word and Numbers copy text with a picture of it.
    @Test func textWithAPictureOfItIsText() {
        let contents = PasteReader.contents(of: pasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setData(TestPictures.png(), forType: .png)
            item.setString("Quarterly numbers", forType: .string)
            pasteboard.writeObjects([item])
        })

        #expect(contents == .text("Quarterly numbers"))
    }

    @Test func anEmptyClipboardHasNothingToPaste() {
        #expect(PasteReader.contents(of: pasteboard { _ in }) == nil)
        #expect(PasteReader.contents(of: pasteboard { $0.setString(" \n\t ", forType: .string) }) == nil)
    }

    @Test func textLosesBlankLinesAboveAndSpaceAfterButKeepsItsIndent() {
        #expect(PasteReader.trimmed("\n\n    let x = 1\n  \n") == "    let x = 1")
        #expect(PasteReader.trimmed("  indented\nnext  ") == "  indented\nnext")
        #expect(PasteReader.trimmed("   ") == "")
    }

    @Test func thePictureIsReadInItsBestFormat() {
        let image = PasteReader.image(from: pasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setData(TestPictures.tiff(), forType: .tiff)
            item.setData(TestPictures.png(), forType: .png)
            pasteboard.writeObjects([item])
        })

        #expect(image?.type == .png)
    }
}

// MARK: - Saving a pasted picture

struct PastedImageTests {
    @Test func pngAndJPEGAreSavedAsTheyCame() {
        let png = TestPictures.png()

        #expect(PastedImage(data: png, type: .png).encoded()?.data == png)
        #expect(PastedImage(data: png, type: .png).encoded()?.fileExtension == "png")
        #expect(PastedImage(data: Data([1, 2, 3]), type: .jpeg).encoded()?.fileExtension == "jpg")
    }

    @Test func aTIFFBecomesAPNG() throws {
        let encoded = try #require(PastedImage(data: TestPictures.tiff(), type: .tiff).encoded())

        #expect(encoded.fileExtension == "png")
        #expect(TestPictures.isPNG(encoded.data))
    }

    @Test func somethingThatIsntAPictureCantBeSaved() {
        #expect(PastedImage(data: Data("not a picture".utf8), type: .tiff).encoded() == nil)
    }

    @Test func aPastedPictureIsNamedLikeAScreenshot() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 13,
                                                                           hour: 9, minute: 5, second: 7)))

        #expect(PastedImage.fileName(at: date, fileExtension: "png") == "Pasted Image 2026-11-13 at 09.05.07.png")
    }
}

// MARK: - Pasting and dropping text

@MainActor
struct PasteTests {
    private func makeModel() -> (NotchViewModel, ShelfStore) {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.state = .expanded
        return (model, store)
    }

    @Test func pastedTextGoesOnTheShelfInView() {
        let (model, store) = makeModel()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/old.txt"))])

        model.paste(.text("Hello\nworld"))

        #expect(store.items.map(\.title) == ["Hello", "old.txt"])
        // On the open shelf, it's scrolled into view if it's out of sight.
        #expect(model.itemToShow == store.items[0].id)
        #expect(model.state == .expanded)
        #expect(model.notice == nil)
    }

    @Test func pastingTheSameTextAgainSaysSo() {
        let (model, store) = makeModel()
        model.paste(.text("Hello"))

        model.paste(.text("Hello"))

        #expect(store.items.count == 1)
        #expect(model.notice == "Hello is already on the shelf")
    }

    @Test func textTooLongToKeepIsTurnedAway() {
        let (model, store) = makeModel()

        model.paste(.text(String(repeating: "a", count: ShelfItem.maxTextLength + 1)))

        #expect(store.items.isEmpty)
        #expect(model.notice == "That text is too long to keep on the shelf")
    }

    @Test func pastedFilesAndLinksAreStoredLikeDroppedOnes() {
        let (model, store) = makeModel()

        model.paste(.files([URL(fileURLWithPath: "/tmp/a.pdf")]))
        model.paste(.links([URL(string: "https://example.com/")!]))

        #expect(store.items.map(\.kind) == [.link, .file])
        #expect(store.items[1].storageMode == .reference)
    }

    @Test func droppedTextIsStored() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.state = .dropReady
        let items = DropReceiver.items(from: pasteboard { $0.setString("A quote from a page", forType: .string) })

        model.handleDrop(items)

        #expect(items == [.text("A quote from a page")])
        #expect(store.items.map(\.title) == ["A quote from a page"])
        #expect(model.state == .expanded)
    }

    @Test func droppedTextThatIsJustAnAddressIsALink() {
        let items = DropReceiver.items(from: pasteboard { $0.setString("https://example.com/a", forType: .string) })

        #expect(items == [.link(URL(string: "https://example.com/a")!)])
    }

    @Test func dragsOfTextAreAccepted() {
        #expect(DropReceiver.canAccept(pasteboard { $0.setString("words", forType: .string) }))
    }

    /// Text shows in Quick Look, but has no file for Get Info or for opening.
    @Test func textShowsInQuickLookOnly() {
        let (model, store) = makeModel()
        store.add([ShelfItem.Draft(text: "note"), ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))])
        let text = store.items[0].id
        model.click(text, .only)
        model.click(store.items[1].id, .toggle)

        #expect(model.itemsToShow(from: text).map(\.title) == ["note", "a.pdf"])
        #expect(model.filesToShow(from: text) == [URL(fileURLWithPath: "/tmp/a.pdf")])
        #expect(model.urlToOpen(text) == nil)
    }

    @Test func textForQuickLookIsAUTF8FileNamedAfterTheTile() throws {
        let id = UUID()
        let file = try #require(TextPreviewFile.write("Привет\nmore", named: "Notes: draft/2", id: id))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(file.lastPathComponent == "Notes- draft-2.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "Привет\nmore")
        let length = getxattr(file.path, "com.apple.TextEncoding", nil, 0, 0, 0)
        #expect(length > 0)
    }

    @Test func aFileNameNeverHidesTheFile() {
        #expect(TextPreviewFile.fileName(for: ".env") == "env.txt")
        #expect(TextPreviewFile.fileName(for: "  ") == "Text.txt")
    }
}

// MARK: - Pasted pictures and screenshots in Polka's folder

/// Pictures and screenshots are Polka's own files, in its Copies folder. A screenshot
/// goes to the Trash, not straight out, once no item uses it.
@MainActor
struct OwnFilesTests {
    private let fileManager = FileManager.default

    /// A temporary folder with Polka's Copies folder and a stand-in for the Trash.
    private func withFolders(_ body: (_ copies: ShelfCopies, _ trash: URL) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let copies = ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true),
                                 moveToTrash: { file in
                                     try FileManager.default.moveItem(at: file,
                                                                      to: trash.appendingPathComponent(file.lastPathComponent))
                                 })
        try await body(copies, trash)
    }

    @Test func aPastedPictureIsSavedAsACopyWithNoOriginal() async throws {
        try await withFolders { copies, _ in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()

            let item = try #require(await keeper.addPastedImage(PastedImage(data: TestPictures.tiff(), type: .tiff)))

            #expect(item.title.hasPrefix("Pasted Image "))
            #expect(item.title.hasSuffix(".png"))
            #expect(item.storageMode == .copy)
            #expect(item.original == nil)
            #expect(TestPictures.isPNG(try Data(contentsOf: item.url)))
            #expect(copies.folderName(containing: item.url.path) != nil)
        }
    }

    @Test func aRemovedScreenshotGoesToTheTrash() async throws {
        try await withFolders { copies, trash in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let loose = fileManager.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString).png")
            try TestPictures.png().write(to: loose)
            var draft = ShelfItem.Draft(fileURL: try copies.moveIn(loose), storageMode: .copy)
            draft.origin = .screenshot
            let item = try #require(store.add([draft]).added.first)

            store.remove(id: item.id)

            #expect(fileManager.fileExists(atPath: trash.appendingPathComponent(loose.lastPathComponent).path))
            #expect(copies.folderNames().isEmpty)
        }
    }

    @Test func aRemovedPastedPictureIsDeletedNotTrashed() async throws {
        try await withFolders { copies, trash in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let item = try #require(await keeper.addPastedImage(PastedImage(data: TestPictures.png(), type: .png)))

            store.remove(id: item.id)

            #expect(copies.folderNames().isEmpty)
            #expect(try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty)
        }
    }
}

// MARK: - Screenshots

/// "Save Screenshots to Polka" (FR-20), with stand-ins for macOS's screenshot settings,
/// Polka's settings and its folders, so the real ones are never touched.
@MainActor
struct ScreenshotTests {
    private let fileManager = FileManager.default

    private struct Setup {
        let catcher: ScreenshotCatcher
        let store: ShelfStore
        let copies: ShelfCopies
        let system: UserDefaults
        let defaults: UserDefaults
    }

    private func withCatcher(settleTime: TimeInterval = 0,
                             _ body: (Setup) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let systemName = "PolkaTests.screencapture.\(UUID().uuidString)"
        let defaultsName = "PolkaTests.settings.\(UUID().uuidString)"
        let system = try #require(UserDefaults(suiteName: systemName))
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            try? fileManager.removeItem(at: root)
            system.removePersistentDomain(forName: systemName)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = ShelfStore()
        let copies = ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true))
        let catcher = ScreenshotCatcher(store: store,
                                        copies: copies,
                                        inbox: root.appendingPathComponent("Polka Screenshots", isDirectory: true),
                                        system: system,
                                        defaults: defaults,
                                        lifetime: { 3600 },
                                        settleTime: settleTime)
        try await body(Setup(catcher: catcher, store: store, copies: copies, system: system, defaults: defaults))
        // Stops watching the folder, if a test left it on.
        catcher.setEnabled(false)
    }

    private func screenshot(_ name: String, in folder: URL, created: Date? = nil) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try TestPictures.png().write(to: file)
        if let created {
            try fileManager.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: file.path)
        }
        return file
    }

    /// Gives background work up to three seconds to finish.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func turningItOnPointsMacOSAtPolkasFolderAndRemembersWhereItPointed() async throws {
        try await withCatcher { setup in
            setup.system.set("/Users/someone/Pictures/Shots", forKey: ScreenshotCatcher.locationKey)

            setup.catcher.setEnabled(true)

            #expect(setup.catcher.isEnabled)
            #expect(setup.system.string(forKey: ScreenshotCatcher.locationKey) == setup.catcher.inbox.path)
            #expect(setup.defaults.string(forKey: ScreenshotCatcher.previousLocationKey) == "/Users/someone/Pictures/Shots")
            #expect(setup.catcher.usualLocationName == "Shots")
            #expect(fileManager.fileExists(atPath: setup.catcher.inbox.path))
        }
    }

    @Test func turningItOffPutsBackWhereScreenshotsWent() async throws {
        try await withCatcher { setup in
            setup.system.set("/Users/someone/Pictures/Shots", forKey: ScreenshotCatcher.locationKey)
            setup.catcher.setEnabled(true)

            setup.catcher.setEnabled(false)

            #expect(!setup.catcher.isEnabled)
            #expect(setup.system.string(forKey: ScreenshotCatcher.locationKey) == "/Users/someone/Pictures/Shots")
            #expect(setup.defaults.string(forKey: ScreenshotCatcher.previousLocationKey) == nil)
        }
    }

    /// Nothing set is macOS's default, the Desktop, so that's what comes back.
    @Test func withNothingSetBeforeTurningItOffGoesBackToTheDesktop() async throws {
        try await withCatcher { setup in
            #expect(setup.catcher.usualLocationName == "the Desktop")
            setup.catcher.setEnabled(true)
            #expect(setup.catcher.usualLocationName == "the Desktop")

            setup.catcher.setEnabled(false)

            #expect(setup.system.object(forKey: ScreenshotCatcher.locationKey) == nil)
        }
    }

    @Test func anotherLocationPickedInTheToolbarShowsAsOff() async throws {
        try await withCatcher { setup in
            setup.catcher.setEnabled(true)
            setup.system.set("/Users/someone/Documents", forKey: ScreenshotCatcher.locationKey)

            setup.catcher.refresh()

            #expect(!setup.catcher.isEnabled)
            #expect(setup.defaults.string(forKey: ScreenshotCatcher.previousLocationKey) == nil)
            #expect(setup.catcher.usualLocationName == "Documents")
        }
    }

    @Test func aScreenshotGoesOnTheShelfAsATemporaryItemOfPolkasOwn() async throws {
        try await withCatcher { setup in
            var reported: Set<ShelfItem.ID> = []
            setup.catcher.onAdded = { reported = $0 }
            _ = try screenshot("Screenshot 2026-11-13 at 10.00.00.png", in: setup.catcher.inbox)

            setup.catcher.sweep()

            let item = try #require(setup.store.items.first)
            #expect(item.title == "Screenshot 2026-11-13 at 10.00.00.png")
            #expect(item.origin == .screenshot)
            #expect(item.storageMode == .copy)
            #expect(item.original == nil)
            #expect(item.expiresAt == item.createdAt.addingTimeInterval(3600))
            #expect(setup.copies.folderName(containing: item.url.path) != nil)
            #expect(fileManager.fileExists(atPath: item.url.path))
            #expect(try fileManager.contentsOfDirectory(atPath: setup.catcher.inbox.path).isEmpty)
            #expect(reported == [item.id])
        }
    }

    @Test func theNewestScreenshotComesFirst() async throws {
        try await withCatcher { setup in
            let now = Date()
            _ = try screenshot("older.png", in: setup.catcher.inbox, created: now.addingTimeInterval(-60))
            _ = try screenshot("newer.png", in: setup.catcher.inbox, created: now.addingTimeInterval(-10))

            setup.catcher.sweep()

            #expect(setup.store.items.map(\.title) == ["newer.png", "older.png"])
        }
    }

    @Test func hiddenFilesAreLeftAlone() async throws {
        try await withCatcher { setup in
            _ = try screenshot(".partial.png", in: setup.catcher.inbox)

            setup.catcher.sweep()

            #expect(setup.store.items.isEmpty)
        }
    }

    @Test func aFileStillBeingWrittenIsLeftForAMoment() async throws {
        try await withCatcher(settleTime: 30) { setup in
            _ = try screenshot("Recording.mov", in: setup.catcher.inbox)

            setup.catcher.sweep()

            #expect(setup.store.items.isEmpty)
        }
    }

    @Test func whileItsOnNewScreenshotsArePickedUpByThemselves() async throws {
        try await withCatcher { setup in
            setup.catcher.setEnabled(true)

            _ = try screenshot("Screenshot.png", in: setup.catcher.inbox)
            try await waitUntil { !setup.store.items.isEmpty }

            #expect(setup.store.items.map(\.title) == ["Screenshot.png"])
            setup.catcher.setEnabled(false)
        }
    }

    @Test func aLocationCountsAsTheSameFolderHoweverItsWritten() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Shots", isDirectory: true)

        #expect(ScreenshotCatcher.isSameFolder("~/Shots", as: folder))
        #expect(ScreenshotCatcher.isSameFolder(folder.path + "/", as: folder))
        #expect(!ScreenshotCatcher.isSameFolder(nil, as: folder))
        #expect(!ScreenshotCatcher.isSameFolder("", as: folder))
        #expect(ScreenshotCatcher.displayName(of: nil) == "the Desktop")
    }
}

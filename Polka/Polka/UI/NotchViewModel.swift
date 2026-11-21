import AppKit
import SwiftUI

/// The four states from the PRD's interaction flow, plus the link field and an offer
/// from a Mac nearby.
enum NotchState: Equatable {
    case collapsed
    case expanded
    case dropReady
    /// An item is being dragged out and the pointer has left the panel.
    case draggingOut
    /// The shelf has turned into a field for typing a link ("Add New", "Link").
    case addingLink
    /// Another Mac wants to share something (Nearby Sharing, NS-6): the eyes, who's
    /// sharing, the items as tiles, Accept and Decline. Opened by the controller, like
    /// the drop zone, and closed only by an answer, the offer timing out, or the other
    /// Mac withdrawing it.
    case offer

    /// True when the shape is notch-sized and the pointer passes through to what's beneath.
    var isAtNotchSize: Bool {
        self == .collapsed || self == .draggingOut
    }
}

/// What a tile's Rename submenu changes.
enum RenameKind: Equatable {
    /// "Rename Label": only the tile's name (FR-17). Every tile has it.
    case label
    /// "Rename File" or "Rename Folder": the name on disk.
    case file
    /// "Edit Address": the link's web address.
    case address
}

/// How a click on a tile changes the selection, from the keys held during the click.
enum SelectionClick: Equatable {
    /// A plain click: just this item.
    case only
    /// Command-click: adds the item, or removes it if it was selected.
    case toggle
    /// Shift-click: every item from the last one clicked to this one.
    case range
}

@MainActor
final class NotchViewModel: ObservableObject {
    /// Closing the panel clears the selection, so it always opens with nothing selected.
    /// So does the link field, which shows no tiles to keep it on.
    @Published var state: NotchState = .collapsed {
        didSet {
            // A name being edited only shows on the open shelf. The controller ends the
            // edit itself before closing the panel, so this only catches the unexpected.
            if state != .expanded, renamingItemID != nil {
                renamingItemID = nil
            }
            if state != .dropReady, dropZoneFolderID != nil {
                dropZoneFolderID = nil
            }
            // Dust only rises over the open shelf.
            if state != .expanded {
                finishDissolving(dissolvingItemIDs)
                dust.clear()
            }
            if state == .collapsed {
                clearSelection()
                itemToReveal = nil
                itemToShow = nil
                // Closing the panel goes back to the shelf, as closing a folder on
                // iPhone does. Something added to a folder while the panel is closed
                // opens it again (`add`).
                openFolderID = nil
            } else if state == .addingLink {
                clearSelection()
            }
        }
    }
    /// A just-dropped item for the grid to scroll to as the panel opens, since on a
    /// sorted shelf it may land out of view. Nil means the first items.
    @Published private(set) var itemToReveal: ShelfItem.ID?
    /// An item that just arrived on the open shelf, such as a converted PDF, for the
    /// grid to scroll into view if it's out of sight.
    @Published private(set) var itemToShow: ShelfItem.ID?
    /// Selected tiles. A drag that starts on one of them carries them all (FR-10).
    @Published private(set) var selection: Set<ShelfItem.ID> = []
    /// The tile whose name is being edited ("Rename"). The panel takes the keys while
    /// it's set, as it does for the link field.
    @Published private(set) var renamingItemID: ShelfItem.ID?
    /// What the field being edited changes: the label, the file, or the address.
    @Published private(set) var renameKind: RenameKind = .label
    /// Where a Shift-click range starts: the last item clicked without Shift.
    private var selectionAnchor: ShelfItem.ID?
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// False on a screen without a notch, where the closed panel is a pill instead.
    @Published var hasNotch = true
    /// True for the last moment of the hover delay, while the closed notch swells just
    /// before the panel opens.
    @Published var isAboutToOpen = false
    /// True while an acceptable drag hovers over the panel.
    @Published var isDropTargeted = false
    /// A message shown in the panel. It stays until the user closes it,
    /// even if the panel collapses and reopens in between.
    @Published private(set) var notice: String?
    /// The shelf folder the panel shows (FR-26), or nil for the shelf itself. The
    /// header reads "Polka / Work" while it's open.
    @Published private(set) var openFolderID: ShelfItem.ID?

    /// A drag of the shelf's own tiles that's under way.
    struct TileMove: Equatable {
        /// What's being moved, in the drag's order: the pressed tile first.
        let ids: [ShelfItem.ID]
        /// Where they'd land if dropped now: the spot of the first of them, counted
        /// among the tiles that stay. Nil until the pointer has settled on a spot, and
        /// after it leaves the panel; the tiles' old places then show as gaps.
        var target: Int?
        /// False for a missing file, which can only be moved around the shelf.
        let canLeaveShelf: Bool
    }

    /// Set from the moment a tile drag starts until it ends.
    @Published private(set) var tileMove: TileMove?
    /// While tiles are dragged: the shelf folder under the pointer they'd go into, or
    /// the shelf, with the pointer on "Polka" in the header (FR-26). It lights up.
    @Published private(set) var tileMoveInto: TileDrop.Into?
    /// Tiles just dropped, hidden while their pictures glide into place.
    @Published private(set) var landingItemIDs: Set<ShelfItem.ID> = []
    /// Removed tiles taking their pictures for the dust, just before they leave the shelf.
    @Published private(set) var dissolvingItemIDs: Set<ShelfItem.ID> = []
    /// True while the tiles close the gap that dust left, which they do slowly.
    @Published private(set) var isClosingDustGap = false
    /// Where removed tiles turn to dust, drawn over the whole panel.
    let dust = DustField()
    /// Tiles that have taken their pictures, waiting to leave the shelf together.
    private var dissolvedItemIDs: Set<ShelfItem.ID> = []
    private var isFinishingDissolve = false
    private var gapTask: Task<Void, Never>?
    /// How long a removed tile may take to hand over its picture before it leaves anyway.
    private static let dissolveTimeout: Duration = .milliseconds(250)
    /// How long the grid's tiles take to close the gap, so the slow reflow covers it.
    private static let dustGapDuration: Duration = .seconds(ShelfGridView.dustGapDuration)
    /// The edge the grid scrolls toward, one row at a time, while a tile is held near it.
    @Published private(set) var scrollEdge: VerticalEdge?
    /// Kept up to date by the grid, and read to find the spot under the pointer.
    let gridGeometry = ShelfGridGeometry()

    /// Fits two rows of tiles; more than that scrolls.
    let expandedSize = CGSize(width: 520, height: 270)

    private let store: ShelfStore
    /// Nil when Polka has no folder of its own to keep copies in.
    private let copies: CopyKeeper?
    /// Nil when Polka has no folder of its own to make PDFs in.
    private let converter: PDFConverter?
    /// Nil when Polka has no folder of its own to make zips in.
    private let compressor: FolderCompressor?
    private let temporaryLifetime: () -> TimeInterval
    /// Remembers a "Sort By" choice for the next launch.
    private let saveSort: (ShelfSort) -> Void
    /// How long the pointer rests on a spot before the other tiles make room.
    private let moveSettleDelay: Duration
    /// About how long AppKit takes to glide a dropped picture into place.
    private let landingTime: Duration = .milliseconds(220)
    /// The spot under the pointer, waiting out `moveSettleDelay`.
    private var pendingTarget: Int?
    private var settleTask: Task<Void, Never>?
    private var landingTask: Task<Void, Never>?

    init(store: ShelfStore,
         copies: CopyKeeper? = nil,
         converter: PDFConverter? = nil,
         compressor: FolderCompressor? = nil,
         temporaryLifetime: @escaping () -> TimeInterval = { ShelfSettings().temporaryLifetime },
         saveSort: @escaping (ShelfSort) -> Void = { ShelfSettings().shelfSort = $0 },
         moveSettleDelay: Duration = .milliseconds(150)) {
        self.store = store
        self.copies = copies
        self.converter = converter
        self.compressor = compressor
        self.temporaryLifetime = temporaryLifetime
        self.saveSort = saveSort
        self.moveSettleDelay = moveSettleDelay
    }

    var canKeepCopies: Bool {
        copies != nil
    }

    var canConvertToPDF: Bool {
        converter != nil
    }

    var canCompress: Bool {
        compressor != nil
    }

    /// The shelf turned into the link field: as wide as the shelf, and only as tall
    /// as the field and the line under it.
    var linkEntrySize: CGSize {
        CGSize(width: expandedSize.width, height: notchSize.height + LinkEntryView.contentHeight)
    }

    var currentSize: CGSize {
        switch state {
        case .collapsed, .draggingOut: return notchSize
        case .expanded, .dropReady, .offer: return expandedSize
        case .addingLink: return linkEntrySize
        }
    }

    // MARK: - Nearby Sharing

    /// How a person answered an offer.
    enum OfferAnswer {
        case accept
        case decline
        /// "Decline and Block": declines, and turns that Mac away until Polka quits.
        case block
    }

    /// The offer the panel shows while it's `.offer`.
    @Published var shownOffer: NearbyIncomingOffer?
    /// Takes the answer to Nearby Sharing; set by the controller.
    var onOfferAnswered: ((NearbyIncomingOffer, OfferAnswer) -> Void)?

    /// Accept, Decline, or Decline and Block in the offer view. Accept grows the view
    /// back into the shelf, where the items land as they arrive; declining closes it.
    func answerOffer(_ answer: OfferAnswer) {
        guard state == .offer, let offer = shownOffer else { return }
        shownOffer = nil
        onOfferAnswered?(offer, answer)
    }

    /// Accepted offers whose files are still arriving, as the shelf's message line
    /// shows them. Links and text arrive at once, so they never show here.
    @Published var nearbyReceiving: [NearbyReceiving] = []
    var onCancelReceiving: ((UUID) -> Void)?

    /// The receiving message's ×.
    func cancelReceiving(_ id: UUID) {
        onCancelReceiving?(id)
    }

    /// What an accepted offer brought: new tiles at the top, marked with who sent them,
    /// with the usual duplicate check and message. The shelf scrolls to them. Tiles a
    /// remembered Mac sent without asking come with a message saying who sent what
    /// (NS-12), which stays until its ×, like other messages.
    func receiveNearby(_ items: [NearbyReceivedItem], from senderName: String, withoutAsking: Bool = false) {
        let drafts = items.map { $0.draft(from: senderName) }
        // To the shelf itself, whatever folder is open: it came from someone else.
        let added = add(drafts, in: nil)
        if withoutAsking, !drafts.isEmpty {
            let name = store.items.first { added.contains($0.id) }?.displayName ?? drafts[0].title
            notice = Self.arrivalMessage(from: senderName, count: drafts.count, added: added.count, firstName: name)
        }
        reveal(added)
    }

    /// "Alex sent \u{201C}report.pdf\u{201D}", "Alex sent 3 items", and what of it was on the
    /// shelf already.
    static func arrivalMessage(from sender: String, count: Int, added: Int, firstName: String) -> String {
        let what = count == 1 ? "\u{201C}\(firstName)\u{201D}" : "\(count) items"
        let duplicates = count - added
        if duplicates == 0 { return "\(sender) sent \(what)" }
        if added == 0 {
            return count == 1 ? "\(sender) sent \(what), already on the shelf"
                              : "\(sender) sent \(what), all already on the shelf"
        }
        return "\(sender) sent \(what). \(duplicates) \(duplicates == 1 ? "was" : "were") already on the shelf"
    }

    // MARK: Sending

    /// How a Send To is going, by tile, shown in place of the type line.
    @Published private(set) var sendingLabels: [ShelfItem.ID: String] = [:]
    /// Which Send To each label belongs to, so an older one clearing late doesn't wipe
    /// out a newer one.
    private var sendingTransfers: [ShelfItem.ID: UUID] = [:]
    /// The Send To each tile is in while it hasn't finished, for Stop Sending.
    @Published private(set) var activeSends: [ShelfItem.ID: UUID] = [:]
    /// Stop Sending, with the Send To it belongs to.
    var onStopSending: ((UUID) -> Void)?
    /// How long a finished Send To's last word ("Sent", "Declined") stays.
    static let sendingLabelDuration: Duration = .seconds(4)

    /// What a right-click "Send To" on `id` offers: the tile, or the whole selection if
    /// the tile is in it, the tile first, then in shelf order. Files, links and text go;
    /// folders and files that can't be found stay behind.
    func itemsToSend(from id: ShelfItem.ID) -> [ShelfItem] {
        let ids = selection.contains(id) ? selection : [id]
        let chosen = store.items.filter { ids.contains($0.id) && isSendable($0) }
        return chosen.filter { $0.id == id } + chosen.filter { $0.id != id }
    }

    /// What of the tiles being dragged can be sent to a Mac nearby (N5), in the drag's
    /// order: the same as "Send To" leaves in. Empty while no tile is dragged.
    var tileMoveItemsToSend: [ShelfItem] {
        guard let tileMove else { return [] }
        let byID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tileMove.ids.compactMap { byID[$0] }.filter(isSendable)
    }

    /// How many selected tiles "Send To" would offer, for "Send 3 Items To".
    var sendableSelectionCount: Int {
        store.items.filter { selection.contains($0.id) && isSendable($0) }.count
    }

    private func isSendable(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .link, .text: return true
        case .file: return !store.missingItemIDs.contains(item.id)
        case .folder, .shelfFolder: return false
        }
    }

    /// Right-click > Stop Sending on `id`: stops the Send To it's in.
    func stopSending(_ id: ShelfItem.ID) {
        guard let transfer = activeSends[id] else { return }
        onStopSending?(transfer)
    }

    /// Shows how a Send To is going on its tiles. A finished one's last word fades
    /// back to the type line after a few seconds.
    func showSending(_ label: String, isFinished: Bool, on ids: [ShelfItem.ID], transfer: UUID) {
        for id in ids {
            sendingTransfers[id] = transfer
            sendingLabels[id] = label
            if isFinished {
                if activeSends[id] == transfer { activeSends[id] = nil }
            } else if activeSends[id] != transfer {
                activeSends[id] = transfer
            }
        }
        guard isFinished else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.sendingLabelDuration)
            guard let self else { return }
            for id in ids where self.sendingTransfers[id] == transfer {
                self.sendingTransfers[id] = nil
                self.sendingLabels[id] = nil
            }
        }
    }

    /// An accepted offer that stopped arriving partway: nothing from it was added.
    func receiveNearbyFailed(from senderName: String, cancelledByThem: Bool = false) {
        notice = cancelledByThem
            ? "\(senderName) stopped sending"
            : "Couldn't receive what \(senderName) shared"
    }

    /// Promised files aren't in `items` as drafts: they're added by
    /// `receivePromisedFiles` once the app that promised them has written them.
    ///
    /// They go into `folderID` when they were dropped on a folder in the drop zone's
    /// row (FR-26); the shelf then opens with that folder in view, pulsing, as a folder
    /// does when tiles are moved into it. Otherwise they go where the panel was showing.
    func handleDrop(_ items: [DroppedItem], intoFolder folderID: ShelfItem.ID? = nil) {
        let drafts = items.compactMap(ShelfItem.Draft.init)
        let folder = store.folder(folderID)?.id
        if let folder {
            add(drafts, in: folder)
        } else {
            add(drafts)
        }
        if let message = Self.notAWebLinkMessage(refused: items.filter(\.isRefusedLink).count) {
            notice = message
        }
        if items.compactMap(\.text).contains(where: Self.isTooLong) {
            notice = Self.textTooLongMessage
        }
        // The drag's end may have opened the shelf already, before the drop arrived.
        let wasOpen = state == .expanded
        state = .expanded
        if let folder {
            showFolderTookDrop(folder, shelfWasOpen: wasOpen)
        }
    }

    /// The shelf, opening after a drop on one of the drop zone's folders, scrolls to
    /// that folder, and the folder pulses once the shelf has grown in, so you see
    /// where it went. A shelf that's open already scrolls only as far as it takes.
    private func showFolderTookDrop(_ folderID: ShelfItem.ID, shelfWasOpen: Bool) {
        if shelfWasOpen {
            itemToShow = folderID
        } else {
            itemToReveal = folderID
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.store.folder(folderID) != nil else { return }
            self.copyPulses[folderID, default: 0] += 1
        }
    }

    // MARK: - The drop zone's folders

    /// The shelf folders the drop zone offers in a row under its box (FR-26), in the
    /// shelf's order, so a drag from another app can go straight into one. Empty when
    /// there are none, and then the row isn't there.
    var dropZoneFolders: [ShelfItem] {
        store.items(in: nil).filter(\.isShelfFolder)
    }

    /// The folder in the drop zone's row that a drag from another app is over. It
    /// lights up, and the box says the drop goes there.
    @Published private(set) var dropZoneFolderID: ShelfItem.ID?
    /// Where the row's folders are, kept up to date by the row.
    let dropZoneGeometry = DropZoneGeometry()

    /// A drag from another app moved over the panel, or left it (nil).
    func externalDragMoved(to point: CGPoint?) {
        let folder = point.flatMap(dropZoneFolder(at:))
        if folder != dropZoneFolderID {
            dropZoneFolderID = folder
        }
    }

    /// The folder in the drop zone's row under `point`, while the drop zone is open.
    /// Only looks, so it can be asked during a drop.
    func dropZoneFolder(at point: CGPoint) -> ShelfItem.ID? {
        guard state == .dropReady, let id = dropZoneGeometry.folder(at: point) else { return nil }
        return store.folder(id)?.id
    }

    // MARK: - Pasting

    /// "Paste" in the + menu (FR-19): what's on the clipboard, stored like the same
    /// thing dropped. The shelf stays open and scrolls to show it. A picture is
    /// saved first (`pasteImage`), since that takes a moment.
    func paste(_ contents: Pasteable) {
        switch contents {
        case .files(let urls):
            reveal(add(urls.map { ShelfItem.Draft(fileURL: $0) }))
        case .links(let urls):
            reveal(add(urls.map(ShelfItem.Draft.init(linkURL:))))
        case .text(let text):
            guard !Self.isTooLong(text) else {
                notice = Self.textTooLongMessage
                return
            }
            reveal(add([ShelfItem.Draft(text: text)]))
        case .image:
            break
        }
    }

    /// "Paste Image": the picture goes into Polka's folder like a photo dragged in from
    /// Photos, and onto the shelf once it's saved.
    func pasteImage(_ image: PastedImage) {
        guard let copies else {
            notice = "Couldn't save the picture, since Polka has no folder to keep it in"
            return
        }
        let folderID = openFolderID
        Task {
            if let item = await copies.addPastedImage(image, in: folderID) {
                reveal([item.id])
            } else {
                notice = "Couldn't save the picture from the clipboard"
            }
        }
    }

    /// The new item nearest the top: on the open shelf, the grid scrolls it into view if
    /// it's out of sight, as for a converted PDF; otherwise the panel opens scrolled to it.
    func reveal(_ ids: Set<ShelfItem.ID>) {
        let first = store.items.first { ids.contains($0.id) }?.id
        if state == .expanded {
            itemToShow = first
        } else {
            revealWhenOpened(first)
        }
    }

    /// The panel opens with this item in view next time. One in a shelf folder opens
    /// that folder, if the panel is closed; an open panel stays where it is.
    private func revealWhenOpened(_ id: ShelfItem.ID?) {
        itemToReveal = id
        guard state == .collapsed, let id, let folderID = item(id)?.folderID,
              store.folder(folderID) != nil else { return }
        openFolderID = folderID
    }

    /// Each copied tile's count of copies, so its picture pulses once per copy: the
    /// one sign a copy worked, since Polka isn't the app you're in.
    @Published private(set) var copyPulses: [ShelfItem.ID: Int] = [:]

    /// Cmd-C over the shelf: the selected tiles, as a drag out would carry them, onto
    /// the clipboard. Only a selection is copied, as in Finder, never the tile under
    /// the pointer alone. False when there's nothing to copy, so the caller can beep.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        copy(itemsToCopy(selection), to: pasteboard)
    }

    /// The tile's "Copy": this item, or the whole selection if this item is in it.
    func copy(from id: ShelfItem.ID, to pasteboard: NSPasteboard = .general) {
        copy(itemsToCopy(selection.contains(id) ? selection : [id]), to: pasteboard)
    }

    /// How many selected tiles "Copy" would copy, for the menu's "Copy 3 Items".
    var copyableSelectionCount: Int {
        itemsToCopy(selection).count
    }

    /// In shelf order, without files that can't be found, which stay behind as in a drag.
    private func itemsToCopy(_ ids: Set<ShelfItem.ID>) -> [ShelfItem] {
        store.items.filter { ids.contains($0.id) && !store.missingItemIDs.contains($0.id) && !$0.isShelfFolder }
    }

    /// What lands on the clipboard is what a drag out drops (`pasteboardWriter`): the
    /// file itself, so Finder pastes a copy and Mail attaches it; a link as its address;
    /// text as plain text. Several at once go on as several items, which Finder takes
    /// all of and a text field takes the first of.
    @discardableResult
    private func copy(_ items: [ShelfItem], to pasteboard: NSPasteboard) -> Bool {
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map(ShelfDragSource.pasteboardWriter(for:)))
        for item in items {
            copyPulses[item.id, default: 0] += 1
        }
        Log.drop.debug("Copied \(items.count, privacy: .public) items")
        return true
    }

    nonisolated fileprivate static func isTooLong(_ text: String) -> Bool {
        text.utf16.count > ShelfItem.maxTextLength
    }

    private static let textTooLongMessage = "That text is too long to keep on the shelf"

    // MARK: - Adding from the header's "Add New" menu

    /// "Link": the shelf turns into a field for typing a link.
    func beginAddingLink() {
        guard state == .expanded else { return }
        state = .addingLink
    }

    /// Esc, the field's ×, or a click outside the panel: back to the shelf, adding nothing.
    func cancelAddingLink() {
        guard state == .addingLink else { return }
        state = .expanded
    }

    /// Return or Add in the link field. The link is stored like a dropped one, and the
    /// field turns back into the shelf, scrolled to show it. When there's nothing to
    /// add, the field stays and this returns what to say under it instead.
    func addLink(from text: String) -> String? {
        guard state == .addingLink else { return nil }
        guard let url = LinkInput.url(from: text) else {
            return "That doesn't look like a web address"
        }
        let result = store.add([ShelfItem.Draft(linkURL: url)], in: openFolderID)
        guard let added = result.added.first else {
            return "That link is already \(whereItIs(ShelfItem.Source.link(url).dedupeKey))"
        }
        itemToReveal = added.id
        state = .expanded
        return nil
    }

    /// "File": what was picked in the Open dialog, stored like dropped files, in the
    /// folder that was open when "File" was chosen. The panel closed before the dialog
    /// opened, so it opens scrolled to them next time, in that folder, and anything
    /// already on the shelf gets the usual message there.
    func addFiles(_ urls: [URL], in folderID: ShelfItem.ID? = nil) {
        add(urls.map { ShelfItem.Draft(fileURL: $0) }, in: folderID)
    }

    /// Stores new items in the open folder, or on the shelf itself if none is open.
    @discardableResult
    private func add(_ drafts: [ShelfItem.Draft]) -> Set<ShelfItem.ID> {
        add(drafts, in: openFolderID)
    }

    /// Stores new items in the shelf folder `folderID`, or on the shelf itself with
    /// nil, says if any were already on the shelf, and remembers the new item nearest
    /// the top, so the panel opens with it in view. Added to a folder while the panel
    /// is closed, they open that folder next time.
    @discardableResult
    private func add(_ drafts: [ShelfItem.Draft], in folderID: ShelfItem.ID?) -> Set<ShelfItem.ID> {
        let result = store.add(drafts, in: folderID)
        if let message = alreadyOnShelfMessage(for: result.duplicates) {
            notice = message
        }
        let addedIDs = Set(result.added.map(\.id))
        revealWhenOpened(store.items.first { addedIDs.contains($0.id) }?.id)
        return addedIDs
    }

    /// A choice from the header's "Sort By" menu, for the place the panel shows. It
    /// sorts itself now and stays sorted from then on. The shelf keeps its choice for
    /// the next launch as a setting; a shelf folder keeps its own in shelf.json, apart
    /// from the shelf's.
    func chooseSort(_ sort: ShelfSort) {
        if let folder = shownFolder {
            store.setSort(sort, in: folder.id)
            return
        }
        store.setSort(sort)
        saveSort(sort)
    }

    /// The order of the place the panel shows, as the header's sort button shows it.
    var shownSort: ShelfSort {
        store.sort(in: shownFolder?.id)
    }

    func dismissNotice() {
        notice = nil
    }

    /// The tile's "Temporary" menu item: a permanent item becomes temporary, and the other way round.
    func toggleTemporary(_ id: ShelfItem.ID) {
        guard let item = store.items.first(where: { $0.id == id }), !item.isShelfFolder else { return }
        if item.isTemporary {
            store.makePermanent(id: id)
        } else {
            store.makeTemporary(id: id, lifetime: temporaryLifetime())
        }
    }

    /// The tile's "Pin" or "Unpin" menu item (FR-21). Past the limit, nothing is pinned
    /// and a message says why, rather than the item being greyed out without a reason.
    func togglePinned(_ id: ShelfItem.ID) {
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        if item.isPinned {
            store.unpin(id: id)
        } else if !store.pin(id: id) {
            let place = store.folder(item.folderID).map { " in \($0.displayName)" } ?? ""
            notice = "You can pin up to \(ShelfStore.maxPinned) items\(place). Unpin one to pin this."
        }
    }

    /// Starts receiving the files an app promised in a drop. Called during the drop
    /// itself, so it changes nothing now; a failure shows a message later. They go into
    /// `folderID` when dropped on a folder in the drop zone's row, otherwise where the
    /// panel was showing.
    func receivePromisedFiles(_ promises: [NSFilePromiseReceiver], intoFolder folderID: ShelfItem.ID? = nil) {
        guard let copies else {
            Log.drop.error("A promised file was dropped, but Polka has no folder to put it in")
            return
        }
        copies.receive(promises, in: store.folder(folderID)?.id ?? openFolderID) { [weak self] fileName in
            self?.notice = "Couldn't get \(fileName ?? "a file") from the app it came from"
        }
    }

    /// The tile's "Keep a Copy" menu item. Checking it copies the original into
    /// Polka's folder; unchecking it goes back to the original and deletes the copy.
    func toggleKeepCopy(_ id: ShelfItem.ID) {
        guard let copies,
              let item = store.items.first(where: { $0.id == id }),
              case .file = item.source else { return }
        switch item.storageMode {
        case .reference:
            Task {
                if await !copies.keepCopy(of: id) {
                    notice = "Couldn't keep a copy of \(item.displayName)"
                }
            }
        case .copy:
            if !store.useOriginal(id: id) {
                notice = "Can't find the original of \(item.displayName), so the copy stays"
            }
        }
    }

    // MARK: - Converting to PDF

    /// What "Convert to PDF" on `id` converts: the whole selection if `id` is in it,
    /// otherwise just `id`, like Quick Look and Remove. Anything that isn't a document,
    /// can't be found, or is already being converted is skipped. In shelf order.
    func documentsToConvert(from id: ShelfItem.ID) -> [ShelfItem.ID] {
        let ids = selection.contains(id) ? selection : [id]
        return store.items.filter { ids.contains($0.id) && canConvertNow($0) }.map(\.id)
    }

    /// How many selected documents "Convert to PDF" would convert, for the menu's
    /// "Convert 3 Items to PDF".
    var convertibleSelectionCount: Int {
        guard !selection.isEmpty else { return 0 }
        return store.items.filter { selection.contains($0.id) && canConvertNow($0) }.count
    }

    /// The tile's "Convert to PDF" menu item. Each PDF lands right after its document;
    /// on the open shelf the grid scrolls to the first if it's out of sight, otherwise
    /// the panel opens scrolled to it next time.
    func convertToPDF(from id: ShelfItem.ID) {
        guard let converter else { return }
        let ids = documentsToConvert(from: id)
        guard !ids.isEmpty else { return }
        Task {
            let outcome = await converter.convert(ids)
            if let message = Self.conversionMessage(for: outcome) {
                notice = message
            }
            let added = Set(outcome.added)
            guard let first = store.items.first(where: { added.contains($0.id) })?.id else { return }
            if state == .expanded {
                itemToShow = first
            } else {
                revealWhenOpened(first)
            }
        }
    }

    private func canConvertNow(_ item: ShelfItem) -> Bool {
        PDFConversion.canConvert(item)
            && !store.missingItemIDs.contains(item.id)
            && !store.convertingItemIDs.contains(item.id)
    }

    /// A failure matters more than where a PDF ended up, so it's the one said.
    static func conversionMessage(for outcome: PDFConverter.Outcome) -> String? {
        switch outcome.failed.count {
        case 0: break
        case 1: return "Couldn't convert \(outcome.failed[0]) to PDF"
        default: return "Couldn't convert \(outcome.failed.count) files to PDF"
        }
        switch outcome.keptInPolka.count {
        case 0: return nil
        case 1: return "Couldn't save \(outcome.keptInPolka[0]) next to its document, so Polka keeps it"
        default: return "Couldn't save \(outcome.keptInPolka.count) PDFs next to their documents, so Polka keeps them"
        }
    }

    // MARK: - Renaming

    /// One of the tile's Rename choices: its name turns into a field, with the name
    /// selected. As in Finder, the tile being renamed is the only one selected. A file
    /// that can't be found, or is being copied or converted, can't be renamed on disk.
    func beginRenaming(_ id: ShelfItem.ID, _ kind: RenameKind = .label) {
        guard state == .expanded, tileMove == nil,
              let item = store.items.first(where: { $0.id == id }) else { return }
        switch kind {
        case .label:
            break
        case .file:
            guard item.kind == .file || item.kind == .folder,
                  !store.missingItemIDs.contains(id),
                  !store.copyingItemIDs.contains(id),
                  !store.convertingItemIDs.contains(id) else { return }
        case .address:
            guard item.kind == .link else { return }
        }
        click(id, .only)
        // Before the ID, so whatever watches the ID finds the kind already set.
        renameKind = kind
        renamingItemID = id
    }

    /// Return, Tab, or a click anywhere else: the edit keeps what's typed. For the
    /// label, an empty name brings back the automatic one; for a file or an address,
    /// nothing typed leaves it as it was. An edit that has already ended is ignored.
    func finishRenaming(_ id: ShelfItem.ID, as name: String) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
        switch renameKind {
        case .label:
            store.rename(id: id, to: name)
        case .file:
            renameFile(id, to: name)
        case .address:
            changeAddress(id, to: name)
        }
    }

    /// Renames the file on disk, in the background. The tile shows the new name once
    /// the file has it; a refused name leaves the file alone and says why.
    private func renameFile(_ id: ShelfItem.ID, to name: String) {
        guard let item = store.items.first(where: { $0.id == id }),
              let plan = FileRenamer.Plan(item: item) else { return }
        Task {
            switch await FileRenamer.rename(plan, to: name) {
            case .unchanged:
                break
            case .refused(let message):
                notice = message
            case .renamed(let newName, let path, let originalPath):
                store.fileRenamed(id: id, to: newName, path: path, originalPath: originalPath)
            }
        }
    }

    /// Reads what was typed the way the link field does (`LinkInput`), so
    /// "example.com" works and only web addresses are kept.
    private func changeAddress(_ id: ShelfItem.ID, to typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = LinkInput.url(from: trimmed) else {
            notice = "That isn't a web address, so the link didn't change"
            return
        }
        if store.changeAddress(id: id, to: url) == .duplicate {
            notice = "That link is already on the shelf, so this one didn't change"
        }
    }

    /// Esc: the tile keeps the name it had.
    func cancelRenaming(_ id: ShelfItem.ID) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
    }

    // MARK: - Shelf folders

    /// The tiles of the place the panel shows: the open shelf folder's, or the shelf's.
    var shownItems: [ShelfItem] {
        store.items(in: shownFolder?.id)
    }

    /// The open shelf folder, while it's still there.
    var shownFolder: ShelfItem? {
        store.folder(openFolderID)
    }

    /// Double-click on a shelf folder: the panel shows its tiles, and the header reads
    /// "Polka / Work". Nothing stays selected, as when Finder opens a folder.
    func openFolder(_ id: ShelfItem.ID) {
        guard state == .expanded, tileMove == nil, store.folder(id) != nil, openFolderID != id else { return }
        renamingItemID = nil
        clearSelection()
        itemToShow = nil
        openFolderID = id
    }

    /// "Polka" in the header, while a folder is open: back to the shelf, with the
    /// folder you were in selected and scrolled into view, so you can see where you
    /// were.
    func closeFolder() {
        guard let folderID = openFolderID, tileMove == nil else { return }
        renamingItemID = nil
        openFolderID = nil
        selection = store.folder(folderID) == nil ? [] : [folderID]
        selectionAnchor = selection.first
        itemToShow = selection.first
    }

    /// "New Folder", from the + menu or a right-click on free space: an empty shelf
    /// folder arrives and its name turns into a field at once, as in Finder. Only on
    /// the shelf itself, since a folder never goes into another.
    func createFolder() {
        guard state == .expanded, openFolderID == nil else { return }
        let folder = store.createFolder()
        itemToShow = folder.id
        beginRenaming(folder.id)
    }

    /// True where "New Folder" is offered: on the open shelf itself.
    var canCreateFolder: Bool {
        state == .expanded && openFolderID == nil
    }

    /// How many tiles each shelf folder holds, for its type line ("3 Items").
    var folderItemCounts: [ShelfItem.ID: Int] {
        store.folderItemCounts
    }

    /// One place "Move To" can send a tile: a shelf folder, or the shelf itself (nil).
    struct MoveDestination: Equatable {
        let folderID: ShelfItem.ID?
        let title: String
    }

    /// What a tile's "Move To" lists: "Shelf" while a folder is open, then every shelf
    /// folder but the open one, A to Z. Empty for a folder, which never goes into
    /// another, and when there's nowhere to go.
    func moveDestinations(for id: ShelfItem.ID) -> [MoveDestination] {
        guard let item = item(id), !item.isShelfFolder else { return [] }
        let shelf = item.folderID == nil ? [] : [MoveDestination(folderID: nil, title: "Shelf")]
        let folders = store.items
            .filter { $0.isShelfFolder && $0.id != item.folderID }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { MoveDestination(folderID: $0.id, title: $0.displayName) }
        return shelf + folders
    }

    /// A shelf folder's "Compress": its tiles in a zip, which lands on the shelf right
    /// after it. On the open shelf the grid scrolls to it if it's out of sight;
    /// otherwise the panel opens scrolled to it next time.
    func compress(_ id: ShelfItem.ID) {
        guard let compressor, let folder = store.folder(id) else { return }
        Task {
            switch await compressor.compress(id) {
            case .added(let zipID):
                if state == .expanded {
                    itemToShow = zipID
                } else {
                    revealWhenOpened(zipID)
                }
            case .nothingToCompress:
                notice = "There's nothing in \(folder.displayName) that can be compressed"
            case .failed:
                notice = "Couldn't compress \(folder.displayName)"
            }
        }
    }

    /// How many selected tiles "Move To" would move, for "Move 3 Items To".
    var movableSelectionCount: Int {
        store.items.filter { selection.contains($0.id) && !$0.isShelfFolder }.count
    }

    /// "Move To" > a place: the tile, or the whole selection if it's in it, folders
    /// left behind, into the shelf folder `folderID` or onto the shelf with nil. A
    /// folder they go into pulses, as a copied tile does, the one sign of where they
    /// went.
    func move(from id: ShelfItem.ID, toFolder folderID: ShelfItem.ID?) {
        let ids = selection.contains(id) ? selection : [id]
        let moved = store.move(ids, toFolder: folderID)
        guard !moved.isEmpty else { return }
        selection.subtract(moved)
        if let folderID {
            copyPulses[folderID, default: 0] += 1
        }
    }

    // MARK: - Selection

    /// Selects tiles the way Finder does in icon view.
    func click(_ id: ShelfItem.ID, _ kind: SelectionClick) {
        switch kind {
        case .only:
            selection = [id]
            selectionAnchor = id
        case .toggle:
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchor = id
        case .range:
            let ids = shownItems.map(\.id)
            guard let anchor = selectionAnchor,
                  let start = ids.firstIndex(of: anchor),
                  let end = ids.firstIndex(of: id) else {
                // Nothing to measure from yet, so it's a plain click.
                click(id, .only)
                return
            }
            selection = Set(ids[min(start, end)...max(start, end)])
        }
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// What was selected when the selection rectangle started, for Shift and Command.
    private var selectionBeforeMarquee: Set<ShelfItem.ID> = []
    private var marqueeKind = SelectionClick.only

    /// A drag on free space starts a selection rectangle, as on the desktop. On its own
    /// it replaces the selection, with Shift (`.range`) it adds to it, and with Command
    /// (`.toggle`) it flips each tile it covers.
    func beginMarquee(_ kind: SelectionClick) {
        marqueeKind = kind
        selectionBeforeMarquee = selection
        if kind == .only {
            selectionAnchor = nil
        }
    }

    /// Called as the rectangle moves with every tile it touches, so tiles light up as
    /// it reaches them and go dark again if it pulls back.
    func updateMarquee(touching ids: Set<ShelfItem.ID>) {
        let newSelection: Set<ShelfItem.ID>
        switch marqueeKind {
        case .only: newSelection = ids
        case .range: newSelection = selectionBeforeMarquee.union(ids)
        case .toggle: newSelection = selectionBeforeMarquee.symmetricDifference(ids)
        }
        // Called on every mouse move; only a real change redraws the shelf.
        if newSelection != selection {
            selection = newSelection
        }
    }

    /// What a drag that starts on `id` carries: that item first, then every other
    /// selected item, in shelf order. Items whose file is missing stay behind.
    /// Like in Finder, dragging an item that isn't selected selects it alone.
    ///
    /// A drag that starts on a missing file carries just that one, and only around
    /// the shelf, since there's no file to hand to another app.
    func dragContents(from id: ShelfItem.ID) -> ShelfDragContents {
        if !selection.contains(id) {
            click(id, .only)
        }
        // A shelf folder has nothing to hand to another app either: it only moves
        // around the shelf, and stays behind when other tiles go.
        if store.missingItemIDs.contains(id) || store.folder(id) != nil {
            return ShelfDragContents(items: store.items.filter { $0.id == id }, staysOnShelf: true)
        }
        let draggable = store.items.filter {
            selection.contains($0.id) && !store.missingItemIDs.contains($0.id) && !$0.isShelfFolder
        }
        return ShelfDragContents(items: draggable.filter { $0.id == id } + draggable.filter { $0.id != id },
                                 staysOnShelf: false)
    }

    // MARK: - Opening and inspecting

    func item(_ id: ShelfItem.ID) -> ShelfItem? {
        store.items.first { $0.id == id }
    }

    /// What a double-click on `id` opens. Nil for a file that can't be found, and for
    /// text, which has nothing to open and shows in Quick Look instead.
    func urlToOpen(_ id: ShelfItem.ID) -> URL? {
        guard !store.missingItemIDs.contains(id),
              let item = item(id), item.kind != .text, !item.isShelfFolder else { return nil }
        return item.urlToOpen()
    }

    /// The files a right-click "Get Info" on `id` acts on: the whole selection if `id`
    /// is in it, otherwise just `id`, with `id` first, like a drag. Links and text have
    /// no file and missing files can't be shown, so they stay out.
    func filesToShow(from id: ShelfItem.ID) -> [URL] {
        itemsToShow(from: id).filter { $0.kind != .text }.map { $0.urlToOpen() }
    }

    /// What a right-click "Quick Look" on `id` shows, chosen like `filesToShow`, but
    /// with text too: Quick Look shows it as a page of text.
    func itemsToShow(from id: ShelfItem.ID) -> [ShelfItem] {
        itemsToShare(from: id).filter { $0.kind != .link }
    }

    /// What a right-click "Share" on `id` sends, chosen like `filesToShow`, but with
    /// links and text too, which the share services take as they come.
    func itemsToShare(from id: ShelfItem.ID) -> [ShelfItem] {
        let ids = selection.contains(id) ? selection : [id]
        let chosen = store.items.filter {
            ids.contains($0.id) && !store.missingItemIDs.contains($0.id) && !$0.isShelfFolder
        }
        return chosen.filter { $0.id == id } + chosen.filter { $0.id != id }
    }

    /// The tile's "Remove" menu item: the whole selection if `id` is in it, otherwise
    /// just `id`, like Quick Look and Get Info. Only the shelf entries go; original
    /// files are never touched.
    func remove(from id: ShelfItem.ID) {
        remove(selection.contains(id) ? selection : [id])
    }

    /// Takes items off the shelf (the × button, and the menu's "Remove"). On the open
    /// shelf they turn to dust, after Telegram's delete animation: each tile hands a
    /// picture of itself to `dust` and hides, then the items leave the shelf together
    /// and the other tiles close the gap while the dust rises. With Reduce Motion, or
    /// without the dust's view, they leave at once and shrink away.
    func remove(_ ids: Set<ShelfItem.ID>) {
        let leaving = ids.filter { id in store.items.contains { $0.id == id } }
        guard state == .expanded, dust.canScatter,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !leaving.isEmpty else {
            store.remove(ids: ids)
            selection.subtract(ids)
            return
        }
        dissolvingItemIDs.formUnion(leaving)
        // In case a tile never gets to take its picture, it leaves anyway.
        Task { [weak self] in
            try? await Task.sleep(for: Self.dissolveTimeout)
            self?.finishDissolving(leaving)
        }
    }

    /// A tile has handed its picture to the dust. The others removed with it do so
    /// while the same change is drawn, so they're all taken off the shelf together a
    /// moment later, with one save.
    func tileDissolved(_ id: ShelfItem.ID) {
        dissolvedItemIDs.insert(id)
        guard !isFinishingDissolve else { return }
        isFinishingDissolve = true
        // After the update that took the pictures, not during it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFinishingDissolve = false
            let ids = self.dissolvedItemIDs
            self.dissolvedItemIDs = []
            self.finishDissolving(ids)
        }
    }

    /// The items leave the shelf, and the other tiles close the gap slowly, as the dust
    /// rises. Items that already left are skipped.
    private func finishDissolving(_ ids: Set<ShelfItem.ID>) {
        let leaving = dissolvingItemIDs.intersection(ids)
        guard !leaving.isEmpty else { return }
        isClosingDustGap = true
        dissolvingItemIDs.subtract(leaving)
        // Selected tiles stay selected until now, so their highlight turns to dust too.
        selection.subtract(leaving)
        store.remove(ids: leaving)
        // Long enough for the grid to animate this change; another tile removed in the
        // meantime closes its gap the same way.
        gapTask?.cancel()
        gapTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dustGapDuration)
            guard !Task.isCancelled else { return }
            self?.isClosingDustGap = false
        }
    }

    /// For something that went wrong outside the panel, such as a file that wouldn't open.
    func showNotice(_ message: String) {
        notice = message
    }

    // MARK: - Drag out

    /// Shrinks the panel once a drag leaves it, so it doesn't cover what's underneath.
    /// It stays shrunk if the pointer comes back, until the drag is over. A missing
    /// file can't go anywhere else, so for it the panel stays open to come back to.
    func dragOutMoved(isInsidePanel: Bool) {
        guard tileMove?.canLeaveShelf != false else { return }
        if state == .expanded, !isInsidePanel {
            tileMoveLeft()
            state = .draggingOut
        }
    }

    func dragOutEnded() {
        if state == .draggingOut {
            state = .collapsed
        }
    }

    // MARK: - Moving tiles

    /// The tiles in the order to show them: the shelf's own order, or, while tiles are
    /// being moved, the order they'd have if dropped now.
    var displayedItems: [ShelfItem] {
        let shown = shownItems
        guard let tileMove, let target = tileMove.target else { return shown }
        return shown.moving(Set(tileMove.ids), to: target)
    }

    /// The titled groups the tiles show in, for the orders that group them (Kind,
    /// File Type). Empty for a plain grid.
    var displayedGroups: [ShelfGroup] {
        shownSort.groups(of: displayedItems)
    }

    /// Tiles drawn as empty gaps: the ones being moved, whose pictures are under the
    /// pointer, and the ones just dropped, whose pictures are still gliding into place.
    var hiddenItemIDs: Set<ShelfItem.ID> {
        landingItemIDs.union(tileMove?.ids ?? [])
    }

    /// A drag of tiles has started. Whether it ends in another app or back on the
    /// shelf isn't known yet, so the tiles lift out of the grid either way.
    func beginTileMove(_ contents: ShelfDragContents) {
        endTileMove()
        finishLanding()
        tileMove = TileMove(ids: contents.items.map(\.id), target: nil, canLeaveShelf: !contents.staysOnShelf)
    }

    /// The pointer is over the panel with the tiles, at `point` in the panel's
    /// coordinates. AppKit keeps calling this while the pointer holds still too.
    ///
    /// The other tiles make room only once the pointer has rested on a spot for
    /// `moveSettleDelay`, as on iPhone, so sweeping across the grid on the way
    /// somewhere doesn't shuffle every tile it passes.
    ///
    /// A sorted shelf keeps its order, so there the other tiles never make room and
    /// the grid doesn't scroll: the moved tiles can only go back where they were. The
    /// same goes for pinned and unpinned tiles moved together, which have no one
    /// part of the shelf to land in.
    ///
    /// Over a shelf folder's picture, or over "Polka" while a folder is open, the tiles
    /// would go in there instead (`tileMoveInto`), sorted or not: the folder lights up,
    /// the others stop making room, and the grid doesn't scroll.
    func tileMoved(to point: CGPoint) {
        guard let tileMove else { return }
        let into = destination(at: point, moving: tileMove.ids)
        if into != tileMoveInto {
            tileMoveInto = into
        }
        if into != nil {
            cancelSettle()
            if scrollEdge != nil {
                scrollEdge = nil
            }
            return
        }
        guard shownSort == .none,
              let target = target(at: point, moving: tileMove.ids) else { return }
        let edge = gridGeometry.scrollEdge(at: point)
        if edge != scrollEdge {
            scrollEdge = edge
        }
        guard target != pendingTarget else { return }
        pendingTarget = target
        settleTask?.cancel()
        settleTask = nil
        guard target != tileMove.target else { return }
        if moveSettleDelay == .zero {
            applyTarget(target)
            return
        }
        settleTask = Task { [weak self, moveSettleDelay] in
            try? await Task.sleep(for: moveSettleDelay)
            guard !Task.isCancelled else { return }
            self?.applyTarget(target)
        }
    }

    /// The pointer left the panel, so the tiles go back to their old places.
    func tileMoveLeft() {
        cancelSettle()
        if tileMoveInto != nil {
            tileMoveInto = nil
        }
        if tileMove?.target != nil {
            tileMove?.target = nil
        }
        if scrollEdge != nil {
            scrollEdge = nil
        }
    }

    /// Where tiles dropped at `point` would go, and where each picture would end up,
    /// in the drag's order. AppKit asks during the drop, so this changes nothing. The
    /// spot is the one under the pointer, even if the tiles haven't made room yet.
    /// On a sorted shelf there's no new spot: the pictures glide back to their own,
    /// like an icon dropped in a sorted Finder window.
    func tileDrop(at point: CGPoint) -> TileDrop? {
        guard let tileMove else { return nil }
        if let into = destination(at: point, moving: tileMove.ids) {
            // The pictures shrink into the folder, or into "Polka".
            let frame = landingFrame(into)
            return TileDrop(target: nil,
                            landingFrames: frame.map { Array(repeating: $0, count: tileMove.ids.count) } ?? [],
                            into: into)
        }
        let target = shownSort == .none ? target(at: point, moving: tileMove.ids) : nil
        let shown = shownItems
        let landedItems = target.map { shown.moving(Set(tileMove.ids), to: $0) } ?? shown
        let landed = landedItems.map(\.id)
        // Laid out in groups, the pinned row and the order's titled groups.
        let placement = gridGeometry.layout.placement(tileCount: landed.count,
                                                      groups: shownSort.groups(of: landedItems))
        let frames = tileMove.ids.compactMap { id in
            landed.firstIndex(of: id).flatMap { gridGeometry.pictureFrame(ofTile: $0, in: placement) }
        }
        return TileDrop(target: target, landingFrames: frames.count == tileMove.ids.count ? frames : [])
    }

    /// The drop: the tiles take their new places and the order is saved, or, with no
    /// `target` (a sorted shelf), they stay where they were. While their pictures
    /// glide into place (`gliding`), the tiles stay hidden, then appear.
    func finishTileMove(at target: Int?, gliding: Bool) {
        guard let tileMove else { return }
        let ids = Set(tileMove.ids)
        if let target {
            store.move(ids, to: target, in: openFolderID)
        }
        endTileMove()
        guard gliding else { return }
        landingItemIDs = ids
        landingTask = Task { [weak self, landingTime] in
            try? await Task.sleep(for: landingTime)
            guard !Task.isCancelled else { return }
            self?.finishLanding()
        }
    }

    /// The drop, wherever it was: into a shelf folder, back onto the shelf from "Polka",
    /// or a spot in the place the panel shows (`finishTileMove(at:gliding:)`). Tiles
    /// that go into a folder leave the place the panel shows; a folder they go into
    /// pulses, as with "Move To". Folders among them stay where they were.
    func finishTileMove(_ drop: TileDrop, gliding: Bool) {
        guard let into = drop.into else {
            finishTileMove(at: drop.target, gliding: gliding)
            return
        }
        guard let tileMove else { return }
        let folderID: ShelfItem.ID?
        switch into {
        case .folder(let id): folderID = id
        case .shelf: folderID = nil
        }
        let moved = store.move(Set(tileMove.ids), toFolder: folderID)
        selection.subtract(moved)
        if let folderID, !moved.isEmpty {
            copyPulses[folderID, default: 0] += 1
        }
        endTileMove()
    }

    /// Where tiles held at `point` would go other than a spot: into the shelf folder
    /// whose picture is under it, or back onto the shelf from "Polka" in the header,
    /// while a folder is open. Nil elsewhere, and when only folders are moving, since
    /// a folder never goes into another.
    private func destination(at point: CGPoint, moving ids: [ShelfItem.ID]) -> TileDrop.Into? {
        let moving = Set(ids)
        guard store.items.contains(where: { moving.contains($0.id) && !$0.isShelfFolder }) else { return nil }
        if shownFolder != nil,
           gridGeometry.backTitleArea.insetBy(dx: -Glass.headerClickMargin, dy: -Glass.headerClickMargin).contains(point) {
            return .shelf
        }
        // Only a folder you can see, not one scrolled under the header.
        guard gridGeometry.viewport.contains(point) else { return nil }
        let items = displayedItems
        let placement = gridGeometry.layout.placement(tileCount: items.count, groups: displayedGroups)
        for (index, item) in items.enumerated() where item.isShelfFolder && !moving.contains(item.id) {
            if gridGeometry.pictureFrame(ofTile: index, in: placement)?.contains(point) == true {
                return .folder(item.id)
            }
        }
        return nil
    }

    /// Where the pictures of tiles dropped into a folder or onto "Polka" glide to: a
    /// small square in the middle of the folder's picture, or of the title.
    private func landingFrame(_ into: TileDrop.Into) -> CGRect? {
        let area: CGRect
        switch into {
        case .shelf:
            area = gridGeometry.backTitleArea
        case .folder(let id):
            let items = displayedItems
            let placement = gridGeometry.layout.placement(tileCount: items.count, groups: displayedGroups)
            guard let index = items.firstIndex(where: { $0.id == id }),
                  let frame = gridGeometry.pictureFrame(ofTile: index, in: placement) else { return nil }
            area = frame
        }
        guard !area.isNull, !area.isEmpty else { return nil }
        let side = ShelfItemTile.imageSide * 0.35
        return CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    }

    /// The drag is over, however it ended. Tiles that didn't land on the shelf show
    /// again in their old places.
    func endTileMove() {
        cancelSettle()
        if tileMoveInto != nil {
            tileMoveInto = nil
        }
        if tileMove != nil {
            tileMove = nil
        }
        if scrollEdge != nil {
            scrollEdge = nil
        }
    }

    /// Where the first moved tile would land with the pointer at `point`, counted
    /// among the tiles that stay, as `moving(_:to:)` counts.
    ///
    /// Tiles stay in their part of the shelf: pinned ones in the pinned row, the
    /// others after it. Held over the other part, they go to the nearest end of their
    /// own, and past the last tile counts as the end. Nil for pinned and unpinned
    /// tiles moved together, which can't land side by side in either part.
    private func target(at point: CGPoint, moving ids: [ShelfItem.ID]) -> Int? {
        let items = shownItems
        let moving = Set(ids)
        let pinnedCount = items.filter(\.isPinned).count
        let pinnedMoving = items.filter { moving.contains($0.id) && $0.isPinned }.count
        let movingCount = items.filter { moving.contains($0.id) }.count
        guard pinnedMoving == 0 || pinnedMoving == movingCount else { return nil }
        let staying = items.count - movingCount
        // Tiles only move within their part, so its size stays the same throughout.
        let placement = gridGeometry.layout.placement(tileCount: items.count, groups: shownSort.groups(of: items))
        let spot = gridGeometry.spot(at: point, in: placement)
        // With anything pinned, the pinned row is the first group.
        let isOverPinned = pinnedCount > 0 && spot.group == 0
        if pinnedMoving > 0 {
            let pinnedStaying = pinnedCount - pinnedMoving
            return isOverPinned ? min(spot.index, pinnedStaying) : pinnedStaying
        }
        return isOverPinned ? pinnedCount : min(max(spot.index, pinnedCount), staying)
    }

    private func applyTarget(_ target: Int) {
        settleTask = nil
        tileMove?.target = target
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        pendingTarget = nil
    }

    private func finishLanding() {
        landingTask?.cancel()
        landingTask = nil
        if !landingItemIDs.isEmpty {
            landingItemIDs = []
        }
    }

    /// "report.pdf is already on the shelf", or "already in Work" when the tile is in
    /// a shelf folder, so you know where to find it.
    private func alreadyOnShelfMessage(for duplicates: [ShelfItem.Draft]) -> String? {
        switch duplicates.count {
        case 0: return nil
        case 1: return "\(duplicates[0].title) is already \(whereItIs(duplicates[0].source.dedupeKey))"
        default: return "\(duplicates.count) items are already on the shelf"
        }
    }

    /// Where the tile with this duplicate key is: "on the shelf", or "in Work" for one
    /// in a shelf folder.
    private func whereItIs(_ key: String) -> String {
        let existing = store.items.first { $0.dedupeKeys.contains(key) }
        return store.folder(existing?.folderID).map { "in \($0.displayName)" } ?? "on the shelf"
    }

    /// For dropped addresses that aren't web links, which are never stored.
    private static func notAWebLinkMessage(refused count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "That link isn't a web address, so it wasn't added"
        default: return "\(count) links aren't web addresses, so they weren't added"
        }
    }
}

private extension ShelfItem.Draft {
    init?(_ dropped: DroppedItem) {
        switch dropped {
        case .file(let url): self.init(fileURL: url)
        case .link(let url): self.init(linkURL: url)
        case .text(let text):
            // Too long to keep: the panel says so instead.
            guard !NotchViewModel.isTooLong(text) else { return nil }
            self.init(text: text)
        case .promise, .refusedLink: return nil
        }
    }
}

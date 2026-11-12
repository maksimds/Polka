import AppKit
import SwiftUI

/// The four states from the PRD's interaction flow, plus the link field.
enum NotchState: Equatable {
    case collapsed
    case expanded
    case dropReady
    /// An item is being dragged out and the pointer has left the panel.
    case draggingOut
    /// The shelf has turned into a field for typing a link ("Add New", "Link").
    case addingLink

    /// True when the shape is notch-sized and the pointer passes through to what's beneath.
    var isAtNotchSize: Bool {
        self == .collapsed || self == .draggingOut
    }
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
            if state == .collapsed {
                clearSelection()
                itemToReveal = nil
            } else if state == .addingLink {
                clearSelection()
            }
        }
    }
    /// A just-dropped item for the grid to scroll to as the panel opens, since on a
    /// sorted shelf it may land out of view. Nil means the first items.
    @Published private(set) var itemToReveal: ShelfItem.ID?
    /// Selected tiles. A drag that starts on one of them carries them all (FR-10).
    @Published private(set) var selection: Set<ShelfItem.ID> = []
    /// The tile whose name is being edited ("Rename"). The panel takes the keys while
    /// it's set, as it does for the link field.
    @Published private(set) var renamingItemID: ShelfItem.ID?
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
    /// Tiles just dropped, hidden while their pictures glide into place.
    @Published private(set) var landingItemIDs: Set<ShelfItem.ID> = []
    /// The edge the grid scrolls toward, one row at a time, while a tile is held near it.
    @Published private(set) var scrollEdge: VerticalEdge?
    /// Kept up to date by the grid, and read to find the spot under the pointer.
    let gridGeometry = ShelfGridGeometry()

    /// Fits two rows of tiles; more than that scrolls.
    let expandedSize = CGSize(width: 520, height: 270)

    private let store: ShelfStore
    /// Nil when Polka has no folder of its own to keep copies in.
    private let copies: CopyKeeper?
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
         temporaryLifetime: @escaping () -> TimeInterval = { ShelfSettings().temporaryLifetime },
         saveSort: @escaping (ShelfSort) -> Void = { ShelfSettings().shelfSort = $0 },
         moveSettleDelay: Duration = .milliseconds(150)) {
        self.store = store
        self.copies = copies
        self.temporaryLifetime = temporaryLifetime
        self.saveSort = saveSort
        self.moveSettleDelay = moveSettleDelay
    }

    var canKeepCopies: Bool {
        copies != nil
    }

    /// The shelf turned into the link field: as wide as the shelf, and only as tall
    /// as the field and the line under it.
    var linkEntrySize: CGSize {
        CGSize(width: expandedSize.width, height: notchSize.height + LinkEntryView.contentHeight)
    }

    var currentSize: CGSize {
        switch state {
        case .collapsed, .draggingOut: return notchSize
        case .expanded, .dropReady: return expandedSize
        case .addingLink: return linkEntrySize
        }
    }

    /// Promised files aren't in `items` as drafts: they're added by
    /// `receivePromisedFiles` once the app that promised them has written them.
    func handleDrop(_ items: [DroppedItem]) {
        add(items.compactMap(ShelfItem.Draft.init))
        state = .expanded
    }

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
        let result = store.add([ShelfItem.Draft(linkURL: url)])
        guard let added = result.added.first else {
            return "That link is already on the shelf"
        }
        itemToReveal = added.id
        state = .expanded
        return nil
    }

    /// "File": what was picked in the Open dialog, stored like dropped files. The
    /// panel closed before the dialog opened, so it opens scrolled to them next time,
    /// and anything already on the shelf gets the usual message there.
    func addFiles(_ urls: [URL]) {
        add(urls.map { ShelfItem.Draft(fileURL: $0) })
    }

    /// Stores new items, says if any were already on the shelf, and remembers the new
    /// item nearest the top, so the panel opens with it in view.
    private func add(_ drafts: [ShelfItem.Draft]) {
        let result = store.add(drafts)
        if let message = Self.alreadyOnShelfMessage(for: result.duplicates) {
            notice = message
        }
        let addedIDs = Set(result.added.map(\.id))
        itemToReveal = store.items.first { addedIDs.contains($0.id) }?.id
    }

    /// A choice from the header's "Sort By" menu. The shelf sorts itself now, stays
    /// sorted from then on, and keeps the choice for the next launch.
    func chooseSort(_ sort: ShelfSort) {
        store.setSort(sort)
        saveSort(sort)
    }

    func dismissNotice() {
        notice = nil
    }

    /// The tile's "Temporary" menu item: a permanent item becomes temporary, and the other way round.
    func toggleTemporary(_ id: ShelfItem.ID) {
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        if item.isTemporary {
            store.makePermanent(id: id)
        } else {
            store.makeTemporary(id: id, lifetime: temporaryLifetime())
        }
    }

    /// Starts receiving the files an app promised in a drop. Called during the drop
    /// itself, so it changes nothing now; a failure shows a message later.
    func receivePromisedFiles(_ promises: [NSFilePromiseReceiver]) {
        guard let copies else {
            Log.drop.error("A promised file was dropped, but Polka has no folder to put it in")
            return
        }
        copies.receive(promises) { [weak self] fileName in
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

    // MARK: - Renaming

    /// The tile's "Rename" menu item: its name turns into a field, with the name
    /// selected. As in Finder, the tile being renamed is the only one selected.
    func beginRenaming(_ id: ShelfItem.ID) {
        guard state == .expanded, tileMove == nil, store.items.contains(where: { $0.id == id }) else { return }
        click(id, .only)
        renamingItemID = id
    }

    /// Return, Tab, or a click anywhere else: the tile keeps the name typed. An empty
    /// name brings back the automatic one. An edit that has already ended is ignored.
    func finishRenaming(_ id: ShelfItem.ID, as name: String) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
        store.rename(id: id, to: name)
    }

    /// Esc: the tile keeps the name it had.
    func cancelRenaming(_ id: ShelfItem.ID) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
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
            let ids = store.items.map(\.id)
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
        if store.missingItemIDs.contains(id) {
            return ShelfDragContents(items: store.items.filter { $0.id == id }, staysOnShelf: true)
        }
        let draggable = store.items.filter {
            selection.contains($0.id) && !store.missingItemIDs.contains($0.id)
        }
        return ShelfDragContents(items: draggable.filter { $0.id == id } + draggable.filter { $0.id != id },
                                 staysOnShelf: false)
    }

    // MARK: - Opening and inspecting

    /// What a double-click on `id` opens. Nil for a file that can't be found.
    func urlToOpen(_ id: ShelfItem.ID) -> URL? {
        guard !store.missingItemIDs.contains(id),
              let item = store.items.first(where: { $0.id == id }) else { return nil }
        return item.urlToOpen()
    }

    /// The files a right-click choice on `id` (Quick Look, Get Info) acts on: the
    /// whole selection if `id` is in it, otherwise just `id`, with `id` first, like a
    /// drag. Links have no file and missing files can't be shown, so both stay out.
    func filesToShow(from id: ShelfItem.ID) -> [URL] {
        let ids = selection.contains(id) ? selection : [id]
        let files = store.items.filter {
            ids.contains($0.id) && $0.kind != .link && !store.missingItemIDs.contains($0.id)
        }
        return (files.filter { $0.id == id } + files.filter { $0.id != id }).map { $0.urlToOpen() }
    }

    /// The tile's "Remove" menu item: the whole selection if `id` is in it, otherwise
    /// just `id`, like Quick Look and Get Info. Only the shelf entries go; original
    /// files are never touched.
    func remove(from id: ShelfItem.ID) {
        let ids = selection.contains(id) ? selection : [id]
        store.remove(ids: ids)
        selection.subtract(ids)
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
        guard let tileMove, let target = tileMove.target else { return store.items }
        return store.items.moving(Set(tileMove.ids), to: target)
    }

    /// The titled groups the tiles show in, for the orders that group them (Kind,
    /// File Type). Empty for a plain grid.
    var displayedGroups: [ShelfGroup] {
        store.sort.groups(of: displayedItems)
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
    /// the grid doesn't scroll: the moved tiles can only go back where they were.
    func tileMoved(to point: CGPoint) {
        guard let tileMove, store.sort == .none else { return }
        let edge = gridGeometry.scrollEdge(at: point)
        if edge != scrollEdge {
            scrollEdge = edge
        }
        let target = target(at: point, moving: tileMove.ids.count)
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
        let target = store.sort == .none ? target(at: point, moving: tileMove.ids.count) : nil
        let landedItems = target.map { store.items.moving(Set(tileMove.ids), to: $0) } ?? store.items
        let landed = landedItems.map(\.id)
        // Laid out with the groups' titles, if the order has them.
        let placement = gridGeometry.layout.placement(tileCount: landed.count,
                                                      groups: store.sort.groups(of: landedItems).map(\.count))
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
            store.move(ids, to: target)
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

    /// The drag is over, however it ended. Tiles that didn't land on the shelf show
    /// again in their old places.
    func endTileMove() {
        cancelSettle()
        if tileMove != nil {
            tileMove = nil
        }
        if scrollEdge != nil {
            scrollEdge = nil
        }
    }

    /// Where the first moved tile would land with the pointer at `point`. Past the
    /// last tile counts as the end.
    private func target(at point: CGPoint, moving count: Int) -> Int {
        min(gridGeometry.slot(at: point), max(store.items.count - count, 0))
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

    private static func alreadyOnShelfMessage(for duplicates: [ShelfItem.Draft]) -> String? {
        switch duplicates.count {
        case 0: return nil
        case 1: return "\(duplicates[0].title) is already on the shelf"
        default: return "\(duplicates.count) items are already on the shelf"
        }
    }
}

private extension ShelfItem.Draft {
    init?(_ dropped: DroppedItem) {
        switch dropped {
        case .file(let url): self.init(fileURL: url)
        case .link(let url): self.init(linkURL: url)
        case .promise: return nil
        }
    }
}

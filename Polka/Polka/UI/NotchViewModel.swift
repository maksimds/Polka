import AppKit
import SwiftUI

/// The four states from the PRD's interaction flow.
enum NotchState: Equatable {
    case collapsed
    case expanded
    case dropReady
    /// An item is being dragged out and the pointer has left the panel.
    case draggingOut

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
    @Published var state: NotchState = .collapsed {
        didSet { if state == .collapsed { clearSelection() } }
    }
    /// Selected tiles. A drag that starts on one of them carries them all (FR-10).
    @Published private(set) var selection: Set<ShelfItem.ID> = []
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

    /// Fits two rows of tiles; more than that scrolls.
    let expandedSize = CGSize(width: 520, height: 270)

    private let store: ShelfStore
    /// Nil when Polka has no folder of its own to keep copies in.
    private let copies: CopyKeeper?
    private let temporaryLifetime: () -> TimeInterval

    init(store: ShelfStore,
         copies: CopyKeeper? = nil,
         temporaryLifetime: @escaping () -> TimeInterval = { ShelfSettings().temporaryLifetime }) {
        self.store = store
        self.copies = copies
        self.temporaryLifetime = temporaryLifetime
    }

    var canKeepCopies: Bool {
        copies != nil
    }

    var currentSize: CGSize {
        state.isAtNotchSize ? notchSize : expandedSize
    }

    /// Promised files aren't in `items` as drafts: they're added by
    /// `receivePromisedFiles` once the app that promised them has written them.
    func handleDrop(_ items: [DroppedItem]) {
        let result = store.add(items.compactMap(ShelfItem.Draft.init))
        if let message = Self.alreadyOnShelfMessage(for: result.duplicates) {
            notice = message
        }
        state = .expanded
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
                    notice = "Couldn't keep a copy of \(item.title)"
                }
            }
        case .copy:
            if !store.useOriginal(id: id) {
                notice = "Can't find the original of \(item.title), so the copy stays"
            }
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
    func itemsToDrag(from id: ShelfItem.ID) -> [ShelfItem] {
        if !selection.contains(id) {
            click(id, .only)
        }
        let draggable = store.items.filter {
            selection.contains($0.id) && !store.missingItemIDs.contains($0.id)
        }
        return draggable.filter { $0.id == id } + draggable.filter { $0.id != id }
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
    /// It stays shrunk if the pointer comes back, until the drag is over.
    func dragOutMoved(isInsidePanel: Bool) {
        if state == .expanded, !isInsidePanel {
            state = .draggingOut
        }
    }

    func dragOutEnded() {
        if state == .draggingOut {
            state = .collapsed
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

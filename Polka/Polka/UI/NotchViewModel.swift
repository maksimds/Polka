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

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .collapsed
    @Published var notchSize = CGSize(width: 200, height: 32)
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

    /// The tile's one-click toggle: a permanent item becomes temporary, and the other way round.
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

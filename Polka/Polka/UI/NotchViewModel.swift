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

    init(store: ShelfStore) {
        self.store = store
    }

    var currentSize: CGSize {
        state.isAtNotchSize ? notchSize : expandedSize
    }

    func handleDrop(_ items: [DroppedItem]) {
        let result = store.add(items.map(ShelfItem.Draft.init))
        if let message = Self.alreadyOnShelfMessage(for: result.duplicates) {
            notice = message
        }
        state = .expanded
    }

    func dismissNotice() {
        notice = nil
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
    init(_ dropped: DroppedItem) {
        switch dropped {
        case .file(let url): self.init(fileURL: url)
        case .link(let url): self.init(linkURL: url)
        }
    }
}

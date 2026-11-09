import SwiftUI

/// The four states from the PRD's interaction flow. "Dragging out" arrives in M2.
enum NotchState: Equatable {
    case collapsed
    case expanded
    case dropReady
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .collapsed
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// True while an acceptable drag hovers over the panel.
    @Published var isDropTargeted = false
    /// A message shown in the panel. It stays until the user closes it.
    @Published private(set) var notice: String?

    let expandedSize = CGSize(width: 520, height: 180)

    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
    }

    var currentSize: CGSize {
        state == .collapsed ? notchSize : expandedSize
    }

    /// True while the panel has to stay open even if the pointer leaves it.
    /// Collapsing would hide a message that is meant to stay until it is closed.
    var keepsPanelOpen: Bool {
        notice != nil
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

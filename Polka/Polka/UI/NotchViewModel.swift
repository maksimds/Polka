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
    /// Spike only: the last few drops, shown in the panel so you can see they arrived.
    @Published private(set) var recentDrops: [String] = []

    let expandedSize = CGSize(width: 520, height: 180)

    var currentSize: CGSize {
        state == .collapsed ? notchSize : expandedSize
    }

    func handleDrop(_ items: [DroppedItem]) -> Bool {
        guard !items.isEmpty else { return false }
        for item in items {
            recentDrops.insert(item.label, at: 0)
        }
        recentDrops = Array(recentDrops.prefix(4))
        state = .expanded
        return true
    }
}

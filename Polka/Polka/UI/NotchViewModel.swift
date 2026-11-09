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
    /// Spike only: the last few drops, shown in the panel so you can see they arrived.
    @Published private(set) var recentDrops: [String] = []

    let expandedSize = CGSize(width: 520, height: 180)

    var currentSize: CGSize {
        state == .collapsed ? notchSize : expandedSize
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = DropReceiver.receive(providers) { [weak self] item in
            self?.record(item)
        }
        if accepted { state = .expanded }
        return accepted
    }

    private func record(_ item: DroppedItem) {
        recentDrops.insert(item.label, at: 0)
        if recentDrops.count > 4 { recentDrops.removeLast() }
    }
}

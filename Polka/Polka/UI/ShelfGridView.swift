import SwiftUI

/// The shelf's items as a scrolling grid, newest first.
struct ShelfGridView: View {
    let items: [ShelfItem]
    /// False while the panel is closed or a drag out is running; the grid stays built.
    let isActive: Bool
    let missingItemIDs: Set<ShelfItem.ID>
    let copyingItemIDs: Set<ShelfItem.ID>
    let selection: Set<ShelfItem.ID>
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onClick: @MainActor (ShelfItem.ID, SelectionClick) -> Void
    let onClearSelection: @MainActor () -> Void
    let itemsToDrag: @MainActor (ShelfItem.ID) -> [ShelfItem]
    let onDelete: @MainActor (ShelfItem.ID) -> Void
    let onToggleTemporary: @MainActor (ShelfItem.ID) -> Void
    let onToggleKeepCopy: (@MainActor (ShelfItem.ID) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    /// A tile grows in when added and shrinks away when removed, while the others
    /// slide into place. Reduce Motion gets a fade.
    private var tileTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
    }

    private var reflowAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items) { item in
                            ShelfItemTile(item: item,
                                          isAvailable: !missingItemIDs.contains(item.id),
                                          isCopying: copyingItemIDs.contains(item.id),
                                          isSelected: selection.contains(item.id),
                                          isActive: isActive,
                                          images: images,
                                          dragSource: dragSource,
                                          onClick: { onClick(item.id, $0) },
                                          itemsToDrag: { itemsToDrag(item.id) },
                                          onDelete: { onDelete(item.id) },
                                          onToggleTemporary: { onToggleTemporary(item.id) },
                                          onToggleKeepCopy: onToggleKeepCopy.map { toggle in { toggle(item.id) } })
                                .transition(tileTransition)
                        }
                    }
                    .animation(reflowAnimation, value: items.map(\.id))
                    // At least as tall as the visible area, so a click anywhere around the
                    // tiles clears the selection. Clicks on a tile never get here: its
                    // AppKit layer takes them first.
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClearSelection)
                }
                // The grid isn't rebuilt each time anymore, so bring the newest items back
                // into view on opening, while the shelf is still fading in.
                .onChange(of: isActive) { _, active in
                    if active, let newest = items.first {
                        scroller.scrollTo(newest.id, anchor: .top)
                    }
                }
            }
        }
    }
}

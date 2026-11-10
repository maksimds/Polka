import SwiftUI

/// The shelf's items as a scrolling grid, newest first.
struct ShelfGridView: View {
    let items: [ShelfItem]
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        ShelfItemTile(item: item,
                                      isAvailable: !missingItemIDs.contains(item.id),
                                      isCopying: copyingItemIDs.contains(item.id),
                                      isSelected: selection.contains(item.id),
                                      images: images,
                                      dragSource: dragSource,
                                      onClick: { onClick(item.id, $0) },
                                      itemsToDrag: { itemsToDrag(item.id) },
                                      onDelete: { onDelete(item.id) },
                                      onToggleTemporary: { onToggleTemporary(item.id) },
                                      onToggleKeepCopy: onToggleKeepCopy.map { toggle in { toggle(item.id) } })
                    }
                }
                // At least as tall as the visible area, so a click anywhere around the
                // tiles clears the selection. Clicks on a tile never get here: its
                // AppKit layer takes them first.
                .frame(minHeight: proxy.size.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClearSelection)
            }
        }
    }
}

import SwiftUI

/// The shelf's items as a scrolling grid, newest first.
struct ShelfGridView: View {
    let items: [ShelfItem]
    let missingItemIDs: Set<ShelfItem.ID>
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onDelete: @MainActor (ShelfItem.ID) -> Void
    let onToggleTemporary: @MainActor (ShelfItem.ID) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { item in
                    ShelfItemTile(item: item,
                                  isAvailable: !missingItemIDs.contains(item.id),
                                  images: images,
                                  dragSource: dragSource,
                                  onDelete: { onDelete(item.id) },
                                  onToggleTemporary: { onToggleTemporary(item.id) })
                }
            }
        }
    }
}

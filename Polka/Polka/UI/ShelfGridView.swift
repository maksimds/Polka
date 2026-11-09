import SwiftUI

/// The shelf's items as a scrolling grid, newest first.
struct ShelfGridView: View {
    let items: [ShelfItem]
    let images: ShelfItemImages
    let dragSource: ShelfDragSource

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { item in
                    ShelfItemTile(item: item, images: images, dragSource: dragSource)
                }
            }
        }
    }
}

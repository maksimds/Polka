import SwiftUI

/// One item in the grid: thumbnail or icon, name and type (FR-2).
struct ShelfItemTile: View {
    static let height: CGFloat = 100
    private static let imageSide: CGFloat = 52

    let item: ShelfItem
    let images: ShelfItemImages
    let dragSource: ShelfDragSource

    @State private var loadedThumbnail: NSImage?

    private var image: NSImage {
        loadedThumbnail ?? images.image(for: item)
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: Self.imageSide, height: Self.imageSide)
                .padding(.bottom, 4)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.typeLabel)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .overlay {
            ShelfItemDragHandle(item: item, image: image, source: dragSource)
        }
        .task(id: item.id) {
            loadedThumbnail = await images.loadThumbnail(for: item, side: Self.imageSide)
        }
    }
}

extension ShelfItem {
    /// The short type line under a tile's name.
    var typeLabel: String {
        switch kind {
        case .folder:
            return "Folder"
        case .link:
            return "Link"
        case .file:
            let fileExtension = url.pathExtension.uppercased()
            return fileExtension.isEmpty ? "File" : fileExtension
        }
    }
}

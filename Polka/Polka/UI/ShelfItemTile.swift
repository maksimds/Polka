import SwiftUI

/// One item in the grid: thumbnail or icon, name and type (FR-2).
struct ShelfItemTile: View {
    static let height: CGFloat = 100
    private static let imageSide: CGFloat = 52

    let item: ShelfItem
    /// False when the original file can't be found (FR-15).
    let isAvailable: Bool
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onDelete: @MainActor () -> Void
    let onToggleTemporary: @MainActor () -> Void

    @State private var loadedThumbnail: NSImage?
    @State private var isHovering = false

    private var image: NSImage {
        loadedThumbnail ?? images.image(for: item)
    }

    private var detailLine: String {
        guard isAvailable else { return "Unavailable" }
        return [item.typeLabel, item.timeLeftLabel(now: Date())]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: Self.imageSide, height: Self.imageSide)
                .saturation(isAvailable ? 1 : 0)
                .opacity(isAvailable ? 1 : 0.35)
                .padding(.bottom, 4)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(isAvailable ? 1 : 0.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detailLine)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .overlay {
            ShelfItemDragHandle(item: item,
                                image: image,
                                source: dragSource,
                                isDragEnabled: isAvailable) { isHovering = $0 }
        }
        .overlay(alignment: .topLeading) {
            // Temporary items always show it, so they stand out at a glance.
            if isHovering || item.isTemporary {
                lifetimeButton
                    .padding(.leading, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                deleteButton
                    .padding(.trailing, 6)
            }
        }
        .task(id: item.id) {
            loadedThumbnail = await images.loadThumbnail(for: item, side: Self.imageSide)
        }
    }

    /// One click switches the item between permanent and temporary.
    private var lifetimeButton: some View {
        cornerButton(symbol: item.isTemporary ? "clock.fill" : "clock",
                     foreground: item.isTemporary ? .black : .white,
                     background: item.isTemporary ? .orange : Color(white: 0.3),
                     label: item.isTemporary ? "Keep \(item.title) permanently" : "Make \(item.title) temporary",
                     action: onToggleTemporary)
    }

    /// Removes the item from the shelf. The original file is never touched.
    private var deleteButton: some View {
        cornerButton(symbol: "xmark",
                     foreground: .white,
                     background: Color(white: 0.3),
                     label: "Remove \(item.title) from the shelf",
                     action: onDelete)
    }

    /// A small round button with a larger invisible hit area.
    private func cornerButton(symbol: String,
                              foreground: Color,
                              background: Color,
                              label: String,
                              action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 18, height: 18)
                .background(background, in: Circle())
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    /// How long a temporary item has left, rounded up: "45m", "23h" or "3d".
    /// Nil for permanent items.
    func timeLeftLabel(now: Date) -> String? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = Int((seconds / 3600).rounded(.up))
        if hours < 48 { return "\(hours)h" }
        return "\(Int((seconds / 86_400).rounded(.up)))d"
    }
}

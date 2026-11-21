import SwiftUI

/// Where the drop zone's folders are (FR-26), in the panel's SwiftUI space, for finding
/// the one under a drag from another app. A plain class, like `ShelfGridGeometry`: the
/// frames only change when the row lays out, and nothing is drawn from them.
final class DropZoneGeometry {
    /// Each folder's place in the row, the gaps beside it included, so the row has no
    /// spots between folders that would drop onto the shelf instead.
    var folderFrames: [ShelfItem.ID: CGRect] = [:]

    func folder(at point: CGPoint) -> ShelfItem.ID? {
        folderFrames.first { $0.value.contains(point) }?.key
    }
}

/// The row under the drop zone's box (FR-26): each shelf folder as a small light grey
/// glass folder with its name under it, so a drag from another app can go straight
/// into one without opening it. Only there while at least one folder exists. The one
/// under the drag swells and lights up, as a folder tile does when tiles are dragged
/// onto it. In the shelf's order, so pinning a folder brings it to the front; past
/// what fits, the last place says how many more there are.
struct DropZoneFolderRow: View {
    let folders: [ShelfItem]
    /// The folder under the drag, if any.
    let targetID: ShelfItem.ID?
    let geometry: DropZoneGeometry
    /// The room the row has.
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let chipWidth: CGFloat = 64
    static let spacing: CGFloat = 6
    static let pictureSide: CGFloat = 34
    /// How much the folder under the drag swells.
    static let targetScale: CGFloat = 1.12

    /// How many places fit across.
    private var capacity: Int {
        max(Int((width + Self.spacing) / (Self.chipWidth + Self.spacing)), 1)
    }

    var body: some View {
        let shown = folders.count > capacity ? Array(folders.prefix(capacity - 1)) : folders
        let more = folders.count - shown.count
        HStack(spacing: Self.spacing) {
            ForEach(shown) { folder in
                chip(folder)
            }
            if more > 0 {
                Text("+\(more) More")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: Self.chipWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop into a folder")
    }

    private func chip(_ folder: ShelfItem) -> some View {
        let isTarget = folder.id == targetID
        return VStack(spacing: 4) {
            Image(nsImage: ShelfItemImages.shelfFolderPicture)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.pictureSide, height: Self.pictureSide)
                .scaleEffect(isTarget && !reduceMotion ? Self.targetScale : 1)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isTarget ? 0.24 : 0))
                        .padding(-4)
                )
            Text(folder.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(isTarget ? 1 : 0.75))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: Self.chipWidth)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isTarget)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { [geometry] frame in
            geometry.folderFrames[folder.id] = frame.insetBy(dx: -Self.spacing / 2, dy: -6)
        }
        .onDisappear { [geometry] in
            geometry.folderFrames[folder.id] = nil
        }
        .accessibilityElement(children: .combine)
    }
}

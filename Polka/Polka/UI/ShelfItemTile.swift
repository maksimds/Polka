import SwiftUI

/// One item in the grid: thumbnail or icon, name and type (FR-2).
struct ShelfItemTile: View {
    static let height: CGFloat = 100
    /// The picture's square, centered in its column.
    static let imageSide: CGFloat = 52

    let item: ShelfItem
    /// False when the original file can't be found (FR-15).
    let isAvailable: Bool
    /// True while Polka is making a copy of the file.
    let isCopying: Bool
    let isSelected: Bool
    /// True while the tile is being moved, or has just been dropped and its picture
    /// is still gliding into place. It shows as an empty gap.
    let isLifted: Bool
    /// False while the panel is closed or a drag out is running.
    let isActive: Bool
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onClick: @MainActor (SelectionClick) -> Void
    /// This item, or the whole selection if this item is in it.
    let dragContents: @MainActor () -> ShelfDragContents
    /// The × button: this item alone.
    let onDelete: @MainActor () -> Void
    /// The menu's "Remove": this item, or the whole selection if this item is in it.
    let onRemoveFromMenu: @MainActor () -> Void
    /// Set as the tile is removed from the open shelf: it takes a picture of what's
    /// drawn of it, hands it over, and hides, and dust takes its place.
    let isDissolving: Bool
    /// The picture, at the display's scale and `snapshotMargin` larger on every side
    /// than the tile's picture and text. Nil if it couldn't be made.
    let onDissolve: @MainActor (CGImage?, CGFloat) -> Void
    /// How many items are selected, for the menu's "Remove 3 Items".
    let selectionCount: Int
    let onToggleTemporary: @MainActor () -> Void
    /// Nil when Polka has nowhere to keep copies.
    let onToggleKeepCopy: (@MainActor () -> Void)?
    /// Double-click.
    let onOpen: @MainActor () -> Void
    /// This item, or the whole selection if this item is in it.
    let onQuickLook: @MainActor () -> Void
    /// This item, or the whole selection if this item is in it.
    let onShowInfo: @MainActor () -> Void
    /// True while the name is a field being typed in ("Rename").
    let isRenaming: Bool
    /// The menu's "Rename": this item alone.
    let onRename: @MainActor () -> Void
    /// The edit ended keeping what's typed: Return, Tab or a click elsewhere.
    let onRenameFinished: @MainActor (String) -> Void
    /// Esc, or the tile went away mid-edit: the name stays as it was.
    let onRenameCancelled: @MainActor () -> Void
    /// Where the picture and text are in the grid's visible area, for the selection
    /// rectangle. Nil once the tile is gone.
    let onPressAreaMoved: @MainActor (CGRect?) -> Void
    /// Where the picture is within the tile's spot, so a dropped picture can glide
    /// to the right place. Every tile lays out the same way.
    let onPictureInSlotMeasured: @MainActor (CGRect) -> Void

    @State private var loadedThumbnail: NSImage?
    @State private var isHovering = false
    /// The picture and text together, within the tile, for placing the picture.
    @State private var pressArea: CGRect?
    /// The name (with its selection capsule) and the type line, as drawn, within the
    /// tile. Part of the tile's shape for hover and presses.
    @State private var nameFrame: CGRect?
    @State private var typeLineFrame: CGRect?
    /// The tile's width, the most the rename field can grow to.
    @State private var tileWidth: CGFloat = 0
    /// What's typed in the rename field, which the field grows to fit. Nil until
    /// something is typed.
    @State private var typedName: String?
    /// True once the tile has handed its picture to the dust, so it hides.
    @State private var isDissolved = false

    private static let coordinateSpace = "ShelfItemTile"

    /// Room around the picture the dust starts from, so a selected picture's grey
    /// square, which reaches 5 pt past the picture, comes along whole.
    static let snapshotMargin: CGFloat = 8

    /// The name's font, as AppKit needs it for the rename field and for measuring.
    /// The same as the `Text` under the picture.
    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private var image: NSImage {
        loadedThumbnail ?? images.image(for: item)
    }

    private var detailLine: String {
        if isCopying { return "Copying…" }
        guard isAvailable else { return "Unavailable" }
        return [item.typeLabel, item.storageMode == .copy ? "Copy" : nil, item.timeLeftLabel(now: Date())]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Quick Look and Get Info for files and folders, and "Rename" for every tile,
    /// right after Get Info as in Finder. Then how Polka keeps the item: "Temporary",
    /// checked while it has an expiry, and for files and folders "Keep a Copy", checked
    /// for a copy. Links have no file to show or copy, so they skip those. "Remove"
    /// comes last, set apart. Unchecking "Keep a Copy" goes back to the original, so it
    /// can't be unchecked for a promised file, which has none.
    private var menuEntries: [TileDragView.MenuEntry] {
        let isFile = item.kind != .link
        var entries: [TileDragView.MenuEntry] = []
        if isFile {
            entries.append(TileDragView.MenuEntry(title: "Quick Look", isEnabled: isAvailable, action: onQuickLook))
            entries.append(TileDragView.MenuEntry(title: "Get Info", isEnabled: isAvailable, action: onShowInfo))
        }
        // Only the tile's label changes, so a missing file can be renamed too.
        entries.append(TileDragView.MenuEntry(title: "Rename", action: onRename))
        entries.append(TileDragView.MenuEntry(title: "Temporary",
                                              isChecked: item.isTemporary,
                                              startsGroup: true,
                                              action: onToggleTemporary))
        if isFile, let onToggleKeepCopy {
            let isCopy = item.storageMode == .copy
            entries.append(TileDragView.MenuEntry(title: "Keep a Copy",
                                                  isChecked: isCopy,
                                                  isEnabled: !isCopying && (isCopy ? item.original != nil : isAvailable),
                                                  action: onToggleKeepCopy))
        }
        // A destructive choice says how much it removes when it's more than this tile.
        let removeCount = isSelected ? max(selectionCount, 1) : 1
        entries.append(TileDragView.MenuEntry(title: removeCount > 1 ? "Remove \(removeCount) Items" : "Remove",
                                              startsGroup: true,
                                              action: onRemoveFromMenu))
        return entries
    }

    /// What's drawn of the tile: its picture, name and type line. The tile itself also
    /// measures the name and type line, and hides the name while it's being renamed.
    /// The picture the dust starts from does neither.
    private func face(isLive: Bool) -> some View {
        VStack(spacing: 2) {
            artwork
                .frame(width: Self.imageSide, height: Self.imageSide)
                .saturation(isAvailable ? 1 : 0)
                .opacity(isAvailable ? 1 : 0.35)
                // Selected, as in Finder: a soft square behind the picture...
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.16 : 0))
                        .padding(-5)
                )
                .padding(.bottom, 4)
            Text(item.displayName)
                .font(Font(Self.nameFont))
                .foregroundStyle(.white.opacity(isAvailable || isSelected ? 1 : 0.5))
                .lineLimit(1)
                // File names keep their extension; link titles keep the site name.
                .truncationMode(item.kind == .link ? .tail : .middle)
                // ...and the name in an accent-colored capsule.
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(isSelected ? 1 : 0)))
                .modifier(FrameReport(isOn: isLive, space: Self.coordinateSpace) { nameFrame = $0 })
                // The rename field takes its place, at once, as in Finder, rather than
                // with the selection's fade.
                .opacity(isLive && isRenaming ? 0 : 1)
                .animation(nil, value: isRenaming)
            Text(detailLine)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .modifier(FrameReport(isOn: isLive, space: Self.coordinateSpace) { typeLineFrame = $0 })
        }
    }

    var body: some View {
        face(isLive: true)
        // The picture and text, measured before the tile stretches to its column. Like
        // an icon on the desktop, only what's drawn of them counts as the tile, for
        // presses and hover (`tileShape`); the rest of the column is free space.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.coordinateSpace))
        } action: { area in
            pressArea = area
            // The picture is the top of this area, centered across it.
            onPictureInSlotMeasured(CGRect(x: area.midX - Self.imageSide / 2,
                                           y: area.minY,
                                           width: Self.imageSide,
                                           height: Self.imageSide))
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(ShelfGridView.viewportSpace))
        } action: { area in
            onPressAreaMoved(area)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            tileWidth = width
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        .overlay {
            ShelfItemDragHandle(source: dragSource,
                                menuEntries: menuEntries,
                                shape: tileShape,
                                removeButtonArea: removeButtonArea,
                                isHovering: isHovering,
                                onHoverChanged: { isHovering = $0 },
                                onClick: onClick,
                                onDoubleClick: onOpen,
                                dragContents: dragContents)
        }
        // Over the drag layer, so it gets its own clicks, and placed once the picture
        // has been measured. Always built, and only shown while hovered. Making and
        // throwing away a Button each time the pointer crosses a tile also makes SwiftUI
        // redo the panel's focus order, which is slow enough to drop frames while tiles
        // scroll past the pointer.
        .overlay(alignment: .topLeading) {
            if let removeBadgeCenter {
                deleteButton
                    .position(removeBadgeCenter)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
            }
        }
        // Over the drag layer as well, so clicks in the field place the caret instead
        // of pressing the tile. Only built while renaming: unlike the × button, it's
        // made once per rename, not on every hover.
        .overlay(alignment: .topLeading) {
            if isRenaming, let nameFrame {
                renameField
                    .position(x: nameFrame.midX, y: nameFrame.midY)
                    // At once, like the name it replaces, not with the selection's fade.
                    .transition(.identity)
            }
        }
        .onChange(of: isRenaming) { _, renaming in
            if !renaming { typedName = nil }
        }
        // Removed: a picture of the tile goes to the dust, and then the tile hides, at
        // once. The dust's first frame looks just like the tile, so for a moment both
        // may show, but never neither.
        .background {
            if isDissolving {
                DissolveSnapshot(face: face(isLive: false).padding(Self.snapshotMargin),
                                 width: tileWidth + 2 * Self.snapshotMargin) { picture, scale in
                    onDissolve(picture, scale)
                    isDissolved = true
                }
            }
        }
        .opacity(isDissolved ? 0 : 1)
        .animation(nil, value: isDissolved)
        .onChange(of: isDissolving) { _, dissolving in
            if !dissolving { isDissolved = false }
        }
        // Lifting out is instant, since the picture is already under the pointer.
        // Coming back is a quick fade, so it doesn't pop in.
        .opacity(isLifted ? 0 : 1)
        .animation(isLifted ? nil : .easeOut(duration: 0.1), value: isLifted)
        // Quick fades, so moving across the grid doesn't leave buttons flickering.
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        // The tile outlives the closed panel now, and a closing panel stops taking
        // mouse events, so the pointer leaving may never be reported. Start clean.
        .onChange(of: isActive) { _, active in
            if !active { isHovering = false }
        }
        .task(id: item.id) {
            loadedThumbnail = await images.loadThumbnail(for: item, side: Self.imageSide)
        }
        .onDisappear {
            onPressAreaMoved(nil)
        }
    }

    /// A link shows its site's icon in a rounded square, with glass built in like an
    /// iOS 27 app icon (`SiteIconStyle`). A tile made for phone home screens fills
    /// the square. A bare logo or a favicon sits on dark glass with room around it,
    /// or on the light card if it's dark. File icons and thumbnails keep their own
    /// shape and look.
    @ViewBuilder
    private var artwork: some View {
        switch images.siteIconStyle(for: item) {
        case .tile:
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.imageSide, height: Self.imageSide)
                .clipShape(Self.linkIconShape)
                .overlay(GlassPictureFinish(shape: Self.linkIconShape))
        case .logo:
            GlassSurface(Self.linkIconShape)
                .overlay(siteIcon)
                .overlay(GlassPictureFinish(shape: Self.linkIconShape))
        case .darkLogo:
            LightGlassCard(shape: Self.linkIconShape)
                .overlay(siteIcon)
        case nil:
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
    }

    /// The site's icon fitted in the middle of its glass or card: small for a
    /// favicon, which is drawn for 16 to 64 pixels, larger for a big logo.
    private var siteIcon: some View {
        let side = ShelfItemImages.isLargeSiteIcon(image) ? Self.logoSide : Self.faviconSide
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
    }

    /// A link's icon or card.
    private static let linkIconShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    /// A bare logo in its 52 pt square, leaving room around it like an app icon's art.
    private static let logoSide: CGFloat = 34
    /// A small favicon, kept small, since it's drawn for 16 to 64 pixels.
    private static let faviconSide: CGFloat = 28

    /// How far inside the picture's top-right corner the remove badge's middle sits,
    /// so the badge hangs over the corner, as on an iPhone app being deleted (which
    /// has it on the left).
    private static let removeBadgeInset: CGFloat = 4

    /// How much lower a folder's remove badge sits, as a part of the picture's height.
    /// The folder icon leaves the top of its square empty above the tab, so at the
    /// square's corner the badge would float above the folder.
    private static let folderBadgeDrop: CGFloat = 0.15

    /// The part of the picture square the picture covers. A link's icon or card fills
    /// it; a file's thumbnail or icon is fitted, so a page is narrower than it's tall.
    private var visiblePicture: CGRect {
        let square = CGRect(x: 0, y: 0, width: Self.imageSide, height: Self.imageSide)
        let size = image.size
        guard item.linkPreview?.iconFileName == nil, size.width > 0, size.height > 0 else {
            return square
        }
        let scale = min(Self.imageSide / size.width, Self.imageSide / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (Self.imageSide - fitted.width) / 2,
                      y: (Self.imageSide - fitted.height) / 2,
                      width: fitted.width,
                      height: fitted.height)
    }

    /// Where the remove badge's middle goes in the tile: over the top-right corner of
    /// the picture you can see, a little lower on a folder. The picture is the top of
    /// the measured area, centered across it. Nil until the tile has been measured.
    private var removeBadgeCenter: CGPoint? {
        guard let pressArea else { return nil }
        let picture = visiblePicture
        let drop = item.kind == .folder ? picture.height * Self.folderBadgeDrop : 0
        return CGPoint(x: pressArea.midX - Self.imageSide / 2 + picture.maxX - Self.removeBadgeInset,
                       y: pressArea.minY + picture.minY + Self.removeBadgeInset + drop)
    }

    /// The picture as drawn, in the picture square. A link's icon or card fills it. A
    /// file's thumbnail or icon is fitted, and only its visible part counts, without
    /// the see-through room a folder or a document icon leaves around its drawing.
    private var drawnPicture: CGRect {
        let fitted = visiblePicture
        guard item.linkPreview?.iconFileName == nil else { return fitted }
        let visible = images.visibleBounds(of: image)
        return CGRect(x: fitted.minX + visible.minX * fitted.width,
                      y: fitted.minY + visible.minY * fitted.height,
                      width: visible.width * fitted.width,
                      height: visible.height * fitted.height)
    }

    /// What counts as the tile for hover and presses, in the tile: the picture as
    /// drawn, the name and the type line, each as wide as it's drawn. The small gaps
    /// between them count too, so moving down the tile doesn't leave it and come back.
    /// Empty until the tile has been measured.
    private var tileShape: [CGRect] {
        guard let pressArea else { return [] }
        var parts = [drawnPicture.offsetBy(dx: pressArea.midX - Self.imageSide / 2, dy: pressArea.minY)]
        parts += [nameFrame, typeLineFrame].compactMap { $0 }
        // Top to bottom: each part reaches down to the next one.
        for index in parts.indices.dropLast() where parts[index + 1].minY > parts[index].maxY {
            parts[index].size.height = parts[index + 1].minY - parts[index].minY
        }
        return parts
    }

    /// The remove button's area in the tile, its invisible margin included.
    private var removeButtonArea: CGRect? {
        removeBadgeCenter.map {
            CGRect(x: $0.x - Self.removeButtonSide / 2, y: $0.y - Self.removeButtonSide / 2,
                   width: Self.removeButtonSide, height: Self.removeButtonSide)
        }
    }

    /// The remove button: its badge with an invisible margin around it, easier to hit.
    private static let removeButtonSide: CGFloat = 26

    /// Removes the item from the shelf. The original file is never touched. The badge
    /// iPhone puts on an app being deleted, with a × for its minus, and a larger
    /// invisible hit area.
    private var deleteButton: some View {
        Button(action: onDelete) {
            GlassRemoveBadge()
                .frame(width: Self.removeButtonSide, height: Self.removeButtonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(item.displayName) from the shelf")
    }

    // MARK: - Rename

    /// Room around the text inside the rename field, the same as the selection
    /// capsule's, so the text doesn't move when editing starts.
    private static let renameInset = CGSize(width: 5, height: 2)

    /// The field the name turns into, like Finder's: a dark box with a focus ring,
    /// as wide as what's typed, and at most as wide as the tile, ring included, so
    /// the grid's edge never cuts the ring off. A longer name scrolls inside it.
    private var renameField: some View {
        let text = typedName ?? item.displayName
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.nameFont]).width)
        // A little extra for the caret at the end, and never so narrow it's hard to click.
        let width = min(max(textWidth + 4 + Self.renameInset.width * 2, 32), max(tileWidth - 8, 32))
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return TileNameEditor(name: item.displayName,
                              fileExtension: item.kind == .file ? item.url.pathExtension : nil,
                              font: Self.nameFont,
                              onTextChange: { typedName = $0 },
                              onFinish: onRenameFinished,
                              onCancel: onRenameCancelled)
            .padding(.horizontal, Self.renameInset.width)
            .padding(.vertical, Self.renameInset.height)
            .frame(width: width)
            .background(shape.fill(Color(white: 0.14)))
            // The system's focus ring color, a softened accent, just outside the box.
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-3)
            )
    }
}

/// Reports where a part of the tile is drawn, in the tile, when `isOn`. The picture the
/// dust starts from is drawn outside the tile, so it must not report.
private struct FrameReport: ViewModifier {
    let isOn: Bool
    let space: String
    let action: (CGRect) -> Void

    func body(content: Content) -> some View {
        if isOn {
            content.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(space))
            } action: { frame in
                action(frame)
            }
        } else {
            content
        }
    }
}

/// Takes the picture a removed tile turns to dust from, as soon as it's added: `face`
/// laid out `width` wide, at the display's scale.
///
/// `ImageRenderer` draws outside the panel, so it doesn't inherit the panel's
/// settings, such as Reduce Transparency, which the glass reads. This view passes all
/// of them on. It only exists for that moment, so the tiles themselves don't have to
/// watch every setting.
private struct DissolveSnapshot<Face: View>: View {
    let face: Face
    let width: CGFloat
    let onTaken: @MainActor (CGImage?, CGFloat) -> Void

    @Environment(\.self) private var environment

    var body: some View {
        Color.clear
            .onAppear {
                let renderer = ImageRenderer(content: face.environment(\.self, environment))
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                renderer.scale = environment.displayScale
                onTaken(renderer.cgImage, renderer.scale)
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

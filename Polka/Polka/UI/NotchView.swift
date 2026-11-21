import SwiftUI

/// The black shape hanging from the notch. It grows from notch size to the
/// expanded size, anchored at the top center of the panel.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: ShelfStore
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let openSettings: @MainActor () -> Void
    /// The + menu's choices.
    let addLink: @MainActor () -> Void
    let addFiles: @MainActor () -> Void
    /// "Folder": a new shelf folder (FR-26).
    let addFolder: @MainActor () -> Void
    /// What "Paste" would add, read from the clipboard as the menu opens.
    let pasteable: @MainActor () -> Pasteable?
    let paste: @MainActor (Pasteable) -> Void
    let commands: ShelfItemCommands
    /// The pointer in the panel's SwiftUI space, for the drop zone's eyes.
    let pointer: @MainActor () -> CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Settings' Transparency, watched so a change shows on the next opening.
    @AppStorage(ShelfSettings.panelTransparencyKey) private var storedTransparency = ShelfSettings.defaultPanelTransparency
    /// Settings' Color, a hex code, or nothing for black.
    @AppStorage(ShelfSettings.panelColorKey) private var storedColor = ""
    /// Goes up each time a drag arrives over the drop zone, to bounce its icon once.
    @State private var dropArrivals = 0
    /// Each press of the gear spins it once.
    @State private var gearPresses = 0
    @State private var isGearHovered = false
    /// "Polka" in the header, while it's the way back from a shelf folder.
    @State private var isBackHovered = false

    /// How much the closed notch swells just before it opens.
    private static let hoverGrowth = CGSize(width: 14, height: 4)
    /// Space between the panel's sides and the tiles, also used by the header and
    /// the link field.
    static let sideInset: CGFloat = 16
    /// How far below the notch's middle the header strip's title and symbols sit,
    /// also used by the link field's header, which takes their place.
    static let headerDrop: CGFloat = 2
    /// Space between the notch and the drop zone's eyes.
    private static let eyesTopGap: CGFloat = 9.9
    /// Space between the eyes and the dashed box below them.
    private static let eyesBottomGap: CGFloat = 11.88

    private var isTargeted: Bool { model.isDropTargeted }
    /// The shelf is showing and can be used.
    private var isOpen: Bool { model.state == .expanded }

    // MARK: - Shape

    private var shapeSize: CGSize {
        var size = model.currentSize
        if model.state == .collapsed, model.isAboutToOpen, !reduceMotion {
            size.width += Self.hoverGrowth.width
            size.height += Self.hoverGrowth.height
        }
        return size
    }

    /// The outward curves where the shape meets the top of the screen. A real notch
    /// has its own, so the closed shape there stays square and hidden inside it.
    private var topRadius: CGFloat {
        guard model.state.isAtNotchSize else { return NotchShape.openTopRadius }
        return model.hasNotch ? 0 : 6
    }

    /// Without a notch, the closed shape is a pill: its bottom is fully round.
    private var bottomRadius: CGFloat {
        guard model.state.isAtNotchSize else { return 24 }
        return model.hasNotch ? 10 : shapeSize.height / 2
    }

    /// How see-through the open panel is, from 0 to 1. Reduce Transparency keeps it solid.
    private var transparency: Double {
        guard !reduceTransparency else { return 0 }
        return Double(ShelfSettings.panelTransparency(stored: storedTransparency)) / 100
    }

    /// Opening: one smooth spring with a touch of bounce, shared by the shape and the
    /// shelf inside it, so the shelf grows out of the notch as a single piece.
    private static let openSpring = Animation.spring(duration: 0.42, bounce: 0.12)

    /// Opening uses `openSpring`; closing is quicker and doesn't bounce. Reduce
    /// Motion gets a plain ease. Read with the new state, so it picks the direction.
    private var shapeAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return model.state.isAtNotchSize ? .spring(duration: 0.3, bounce: 0) : Self.openSpring
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                // Removed tiles turn to dust over everything in the panel, and only
                // inside its outline.
                .overlay(alignment: .top) {
                    DustOverlay(field: model.dust,
                                outline: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                                    .path(in: CGRect(origin: .zero, size: model.expandedSize)))
                        .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                }
                .clipped()
                // Solid black, or glass while open: see-through (Settings' Transparency),
                // colored (Settings' Color), or both.
                .background(
                    PanelBackground(shape: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius),
                                    transparency: transparency,
                                    color: ShelfSettings.panelColor(stored: storedColor),
                                    isClosed: model.state.isAtNotchSize,
                                    isOpen: isOpen)
                )
            // Drops are received by DropTargetView (AppKit), which wraps this view.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // When the state and the swell change together (the panel opening), the state's
        // animation wins, since the modifier nearer the view applies last.
        .animation(shapeAnimation, value: model.state)
        // The same spring as the opening, so the swell flows into it without a seam.
        .animation(reduceMotion ? nil : Self.openSpring, value: model.isAboutToOpen)
        .animation(.easeOut(duration: 0.15), value: model.notice)
        .animation(.easeOut(duration: 0.15), value: model.nearbyReceiving.first?.id)
    }

    // MARK: - Content

    /// The shelf is built once and stays built while the panel is closed, hidden and
    /// clipped to the notch. Opening only reveals it, so the first frames of the
    /// animation never wait for the grid, its icons and thumbnails to be made. It also
    /// keeps its full size while the shape shrinks around it, so the tile a drag out
    /// started from is still there when the drag ends.
    private var content: some View {
        ZStack(alignment: .top) {
            expandedContent
                .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                .overlay(alignment: .top) { header }
                // Grows out of the notch together with the shape...
                .scaleEffect(isOpen || reduceMotion ? 1 : 0.92, anchor: .top)
                // ...fading in just behind it, and out quickly before it shrinks.
                .animation(isOpen ? .easeOut(duration: 0.24).delay(0.04) : .easeIn(duration: 0.1)) {
                    $0.opacity(isOpen ? 1 : 0)
                }
                // Hidden tiles can't be clicked or hovered.
                .allowsHitTesting(isOpen)
            if model.state == .dropReady {
                dropZone
                    .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                    .transition(dropZoneTransition)
            }
            if model.state == .addingLink {
                LinkEntryView(headerHeight: model.notchSize.height,
                              width: model.linkEntrySize.width,
                              onSubmit: { model.addLink(from: $0) },
                              onCancel: { model.cancelAddingLink() })
                    .frame(width: model.linkEntrySize.width, height: model.linkEntrySize.height)
                    .transition(dropZoneTransition)
            }
            if model.state == .offer, let offer = model.shownOffer {
                NearbyOfferView(offer: offer,
                                images: images,
                                headerHeight: model.notchSize.height,
                                pointer: pointer,
                                onAnswer: { model.answerOffer($0) })
                    .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                    .transition(dropZoneTransition)
            }
        }
    }

    /// The drop zone, the link field and an offer are light enough to build when
    /// they're needed. Each arrives as the shape changes and leaves quickly.
    private var dropZoneTransition: AnyTransition {
        let arrival: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
        return .asymmetric(insertion: arrival.animation(.easeOut(duration: 0.24).delay(0.04)),
                           removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    /// Nil when Polka has nowhere to keep copies, so tiles show no "Keep a Copy".
    private var keepCopyAction: (@MainActor (ShelfItem.ID) -> Void)? {
        guard model.canKeepCopies else { return nil }
        return { [model] id in model.toggleKeepCopy(id) }
    }

    /// The + menu's "Folder". Nil inside a shelf folder, since folders are only made
    /// on the shelf itself.
    private var addFolderAction: (@MainActor () -> Void)? {
        guard model.shownFolder == nil else { return nil }
        return addFolder
    }

    /// Nil when Polka has nowhere to make zips, so shelf folders show no "Compress".
    private var compressAction: (@MainActor (ShelfItem.ID) -> Void)? {
        guard model.canCompress else { return nil }
        return { [model] id in model.compress(id) }
    }

    /// Nil when Polka has nowhere to make PDFs, so tiles show no "Convert to PDF".
    private var convertAction: (@MainActor (ShelfItem.ID) -> Void)? {
        guard model.canConvertToPDF else { return nil }
        return { [model] id in model.convertToPDF(from: id) }
    }

    /// "Rename" starts a tick later, since it's chosen as the menu closes, and the
    /// panel shouldn't take the keys while the menu still tracks the pointer.
    private var renameActions: ShelfRenameActions {
        ShelfRenameActions(begin: { [model] id, kind in
                               DispatchQueue.main.async { model.beginRenaming(id, kind) }
                           },
                           finish: { [model] id, name in model.finishRenaming(id, as: name) },
                           cancel: { [model] id in model.cancelRenaming(id) })
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            shelf
            // Below the grid so it never covers a tile, and tiles don't shift under the pointer.
            if let receiving = model.nearbyReceiving.first {
                NearbyReceivingBanner(receiving: receiving) { model.cancelReceiving(receiving.id) }
                    .transition(.opacity)
            }
            if let notice = model.notice {
                NoticeBanner(message: notice) { model.dismissNotice() }
                    .transition(.opacity)
            }
        }
        .font(.system(size: 13))
        .padding(.top, model.notchSize.height + 8)
        .padding(.horizontal, Self.sideInset)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The tiles of the shelf or the open shelf folder, or with none, a line saying how
    /// to add some. Measured for the free space menu, which a right-click anywhere
    /// here but on a tile opens.
    ///
    /// Each place gets a grid of its own (`id`), so opening or leaving a folder swaps
    /// the whole page at once, as Finder does, rather than every tile sliding.
    private var shelf: some View {
        ZStack {
            place
                .id(model.shownFolder?.id)
                .transition(placeTransition)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.2), value: model.shownFolder?.id)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { [geometry = model.gridGeometry] frame in
            geometry.shelfArea = frame
        }
    }

    /// The tiles of one place, the shelf or a shelf folder, or the line for an empty one.
    @ViewBuilder
    private var place: some View {
        Group {
            if model.shownItems.isEmpty {
                Text("Drag a file or link here")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ShelfGridView(items: model.displayedItems,
                              groups: model.displayedGroups,
                              isActive: isOpen,
                              missingItemIDs: store.missingItemIDs,
                              copyingItemIDs: store.copyingItemIDs,
                              convertingItemIDs: store.convertingItemIDs,
                              sendingLabels: model.sendingLabels,
                              sendingItemIDs: Set(model.activeSends.keys),
                              sendableSelectionCount: model.sendableSelectionCount,
                              folderItemCounts: model.folderItemCounts,
                              movableSelectionCount: model.movableSelectionCount,
                              dropTargetFolderID: dropTargetFolderID,
                              compressingItemIDs: store.compressingItemIDs,
                              onCompress: compressAction,
                              selection: model.selection,
                              hiddenItemIDs: model.hiddenItemIDs,
                              isMovingTiles: model.tileMove != nil,
                              scrollEdge: model.scrollEdge,
                              revealItemID: model.itemToReveal,
                              showItemID: model.itemToShow,
                              geometry: model.gridGeometry,
                              images: images,
                              dragSource: dragSource,
                              onClick: { model.click($0, $1) },
                              onClearSelection: { model.clearSelection() },
                              dragContents: { model.dragContents(from: $0) },
                              onDelete: { model.remove([$0]) },
                              onRemoveFromMenu: { model.remove(from: $0) },
                              dissolvingItemIDs: model.dissolvingItemIDs,
                              isClosingDustGap: model.isClosingDustGap,
                              dust: model.dust,
                              onDissolved: { model.tileDissolved($0) },
                              onTogglePinned: { model.togglePinned($0) },
                              onToggleKeepCopy: keepCopyAction,
                              convertibleSelectionCount: model.convertibleSelectionCount,
                              copyableSelectionCount: model.copyableSelectionCount,
                              copyPulses: model.copyPulses,
                              onConvertToPDF: convertAction,
                              commands: commands,
                              renamingItemID: model.renamingItemID,
                              renameKind: model.renameKind,
                              rename: renameActions,
                              onMarqueeBegan: { model.beginMarquee($0) },
                              onMarqueeChanged: { model.updateMarquee(touching: $0) })
            }
        }
    }

    /// The strip beside the notch, laid out on the tiles' own grid: same columns, same
    /// side inset, and each end held to a picture's width. So "Polka" starts exactly
    /// where the first column's pictures start, and the gear ends exactly where the
    /// last column's pictures end. The sort and + buttons sit left of the gear, running
    /// a little into the fourth column but well clear of the notch, which the middle
    /// columns sit under.
    private var header: some View {
        LazyVGrid(columns: ShelfGridView.columns, spacing: 0) {
            nameLabel
                .frame(width: ShelfItemTile.imageSide, alignment: .leading)
            ForEach(0..<3, id: \.self) { _ in
                Color.clear
            }
            // Glass symbols, 16 pt apart, so their 8 pt click margins meet without overlapping.
            HStack(spacing: Glass.headerSymbolSpacing) {
                AddMenuButton(height: model.notchSize.height,
                              isActive: model.state == .expanded,
                              onAddLink: addLink,
                              onAddFiles: addFiles,
                              onAddFolder: addFolderAction,
                              pasteable: pasteable,
                              onPaste: paste)
                SortMenuButton(sort: model.shownSort,
                               height: model.notchSize.height,
                               isActive: model.state == .expanded) { model.chooseSort($0) }
                settingsButton
            }
            .fixedSize()
            .frame(width: ShelfItemTile.imageSide, alignment: .trailing)
        }
        .frame(height: model.notchSize.height)
        // A touch below the notch's middle, which sat a little high next to the tiles.
        .offset(y: Self.headerDrop)
        .padding(.horizontal, Self.sideInset)
    }

    /// "Polka", or "Polka / Work" while a shelf folder is open, where "Polka" is the way
    /// back. Never squeezed by its column: it runs on to the right, and a long folder
    /// name is cut short before it reaches the notch.
    private var nameLabel: some View {
        HStack(spacing: 5) {
            if let folder = model.shownFolder {
                backButton
                GlassTitle(text: "/")
                    .opacity(0.5)
                    .allowsHitTesting(false)
                GlassTitle(text: folder.displayName, truncates: true)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
            } else {
                GlassTitle(text: "Polka")
                    .allowsHitTesting(false)
            }
        }
        .frame(width: nameWidth, height: model.notchSize.height, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: model.shownFolder?.id)
    }

    /// The shelf folder dragged tiles would go into, if any.
    private var dropTargetFolderID: ShelfItem.ID? {
        guard case .folder(let id) = model.tileMoveInto else { return nil }
        return id
    }

    /// The room left of the notch for the header's name, less a little air.
    private var nameWidth: CGFloat {
        max((model.expandedSize.width - model.notchSize.width) / 2 - Self.sideInset - 10, ShelfItemTile.imageSide)
    }

    /// "Polka", while a folder is open: back to the shelf. Glows under the pointer like
    /// the header's symbols. Tiles dragged onto it go back onto the shelf, and while
    /// they're over it, it lights up like a folder taking them.
    private var backButton: some View {
        let isDropTarget = model.tileMoveInto == .shelf
        return Button {
            model.closeFolder()
        } label: {
            GlassHeaderGlyph(height: model.notchSize.height,
                             isGlowing: isBackHovered && isOpen,
                             gloss: GlassTitle.gloss) {
                Text("Polka")
                    .font(GlassTitle.font)
            }
            .fixedSize()
            .background(
                Capsule()
                    .fill(Color.white.opacity(isDropTarget ? 0.26 : 0))
                    .padding(.horizontal, -7)
                    .padding(.vertical, 4)
            )
            .scaleEffect(isDropTarget && !reduceMotion ? 1.08 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: isDropTarget)
            .contentShape(Rectangle().inset(by: -Glass.headerClickMargin))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the shelf")
        .overlay {
            HeaderHoverArea(isActive: isOpen) { isBackHovered = $0 }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { [geometry = model.gridGeometry] frame in
            geometry.backTitleArea = frame
        }
        .onDisappear { [geometry = model.gridGeometry] in
            geometry.backTitleArea = .null
        }
    }

    /// Opening or leaving a folder: the new page fades in, growing a touch as the shelf
    /// does when it opens, and the old one fades out. Reduce Motion fades only.
    private var placeTransition: AnyTransition {
        let arrival: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
        return .asymmetric(insertion: arrival, removal: .opacity)
    }

    /// Opens Settings, with a spin of the gear; the shelf stays open while Settings
    /// is. The gear's own frame is just the symbol, so its edge is what lines up with
    /// the tiles; the area you can click reaches 8 pt further around it.
    private var settingsButton: some View {
        Button {
            gearPresses += 1
            openSettings()
        } label: {
            GearSymbol(presses: gearPresses,
                       height: model.notchSize.height,
                       isGlowing: isGearHovered && model.state == .expanded)
                .contentShape(Rectangle().inset(by: -Glass.headerClickMargin))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .overlay {
            HeaderHoverArea(isActive: model.state == .expanded) { isGearHovered = $0 }
                .padding(-Glass.headerClickMargin)
        }
    }

    // MARK: - Drop zone

    /// Eyes hanging just under the notch, watching the drag, over the dashed box.
    /// The eyes, the box, and under it, while there are shelf folders, a row of them
    /// to drop straight into (FR-26). The box gets shorter to make room.
    private var dropZone: some View {
        VStack(spacing: 0) {
            DropZoneEyes(pointer: pointer, isTargeted: isTargeted)
                // Just the eyes' own height, so its middle is where they look from.
                // They can lean past it a little as they turn; nothing clips them.
                .frame(height: DropZoneEyes.eyeSize.height)
                .padding(.top, Self.eyesTopGap)
                .padding(.bottom, Self.eyesBottomGap)
            dropBox
            let folders = model.dropZoneFolders
            if !folders.isEmpty {
                DropZoneFolderRow(folders: folders,
                                  targetID: model.dropZoneFolderID,
                                  geometry: model.dropZoneGeometry,
                                  width: model.expandedSize.width - 32)
                    .padding(.top, Self.folderRowGap)
            }
        }
        .padding(.top, model.notchSize.height)
        .padding([.horizontal, .bottom], 16)
    }

    /// Space between the drop zone's box and its row of folders.
    private static let folderRowGap: CGFloat = 10

    /// The drag is over the box itself, not over one of the folders under it.
    private var isBoxTargeted: Bool {
        isTargeted && model.dropZoneFolderID == nil
    }

    /// What the drop zone says: where a drop goes. Over a folder in the row, that
    /// folder. Over the box, where the panel was showing: the shelf, or the shelf
    /// folder still open, as it is while Settings holds the shelf open.
    private var dropZoneLine: String {
        if let id = model.dropZoneFolderID, let folder = store.folder(id) {
            return "Release to add to \(folder.displayName)"
        }
        guard let folder = model.shownFolder else { return isBoxTargeted ? "Release to add" : "Drop here" }
        return isBoxTargeted ? "Release to add to \(folder.displayName)" : "Drop into \(folder.displayName)"
    }

    private var dropBox: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .foregroundStyle(.white.opacity(isBoxTargeted ? 0.9 : 0.4))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isBoxTargeted ? 0.12 : 0.04))
            )
            .overlay(
                VStack(spacing: 8) {
                    // Glass, and brighter while a drag is over the panel.
                    GlassGlyph(isLit: isBoxTargeted) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 26, weight: .medium))
                            .symbolEffect(.bounce, value: dropArrivals)
                    }
                    Text(dropZoneLine)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .contentTransition(.opacity)
                }
                // Bright over a folder too, since the words then name it.
                .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.8))
            )
            // Leans toward the pointer a little when a drag is over it.
            .scaleEffect(isBoxTargeted && !reduceMotion ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: isBoxTargeted)
            .onChange(of: isTargeted) { _, targeted in
                if targeted { dropArrivals += 1 }
            }
    }
}

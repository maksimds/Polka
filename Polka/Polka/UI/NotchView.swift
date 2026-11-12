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
    let commands: ShelfItemCommands
    /// The pointer in the panel's SwiftUI space, for the drop zone's eyes.
    let pointer: @MainActor () -> CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Goes up each time a drag arrives over the drop zone, to bounce its icon once.
    @State private var dropArrivals = 0

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
        guard model.state.isAtNotchSize else { return 14 }
        return model.hasNotch ? 0 : 6
    }

    /// Without a notch, the closed shape is a pill: its bottom is fully round.
    private var bottomRadius: CGFloat {
        guard model.state.isAtNotchSize else { return 24 }
        return model.hasNotch ? 10 : shapeSize.height / 2
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
                .background(
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .fill(Color.black)
                        // Lifts the open panel off whatever is behind it. Pushed down so
                        // it falls below the panel rather than on the menu bar beside
                        // it, and none while closed, where it would ring the notch. It
                        // fades in as the opening settles, not while the shape grows.
                        .animation(isOpen ? .easeOut(duration: 0.2).delay(0.2) : .easeIn(duration: 0.1)) {
                            $0.shadow(color: .black.opacity(model.state.isAtNotchSize ? 0 : 0.3),
                                      radius: 10, y: 9)
                        }
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
        }
    }

    /// The drop zone and the link field are light enough to build when they're
    /// needed. Each arrives as the shape changes and leaves quickly.
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

    /// "Rename" starts a tick later, since it's chosen as the menu closes, and the
    /// panel shouldn't take the keys while the menu still tracks the pointer.
    private var renameActions: ShelfRenameActions {
        ShelfRenameActions(begin: { [model] id in
                               DispatchQueue.main.async { model.beginRenaming(id) }
                           },
                           finish: { [model] id, name in model.finishRenaming(id, as: name) },
                           cancel: { [model] id in model.cancelRenaming(id) })
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                Text("Drag a file or link here")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ShelfGridView(items: model.displayedItems,
                              groups: model.displayedGroups,
                              isActive: isOpen,
                              missingItemIDs: store.missingItemIDs,
                              copyingItemIDs: store.copyingItemIDs,
                              selection: model.selection,
                              hiddenItemIDs: model.hiddenItemIDs,
                              isMovingTiles: model.tileMove != nil,
                              scrollEdge: model.scrollEdge,
                              revealItemID: model.itemToReveal,
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
                              onToggleTemporary: { model.toggleTemporary($0) },
                              onToggleKeepCopy: keepCopyAction,
                              commands: commands,
                              renamingItemID: model.renamingItemID,
                              rename: renameActions,
                              onMarqueeBegan: { model.beginMarquee($0) },
                              onMarqueeChanged: { model.updateMarquee(touching: $0) })
            }
            // Below the grid so it never covers a tile, and tiles don't shift under the pointer.
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
                AddMenuButton(height: model.notchSize.height, onAddLink: addLink, onAddFiles: addFiles)
                SortMenuButton(sort: store.sort, height: model.notchSize.height) { model.chooseSort($0) }
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

    private var nameLabel: some View {
        // Never squeezed by its column: a longer name would run on to the right.
        GlassTitle(text: "Polka")
            .frame(height: model.notchSize.height)
            .allowsHitTesting(false)
    }

    /// Opens Settings. The gear's own frame is just the symbol, so its edge is what
    /// lines up with the tiles; the area you can click reaches 8 pt further around it.
    private var settingsButton: some View {
        Button(action: openSettings) {
            GlassHeaderSymbol(systemName: "gearshape.fill", height: model.notchSize.height)
                .contentShape(Rectangle().inset(by: -Glass.headerClickMargin))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    // MARK: - Drop zone

    /// Eyes hanging just under the notch, watching the drag, over the dashed box.
    private var dropZone: some View {
        VStack(spacing: 0) {
            DropZoneEyes(pointer: pointer, isTargeted: isTargeted)
                // Just the eyes' own height, so its middle is where they look from.
                // They can lean past it a little as they turn; nothing clips them.
                .frame(height: DropZoneEyes.eyeSize.height)
                .padding(.top, Self.eyesTopGap)
                .padding(.bottom, Self.eyesBottomGap)
            dropBox
        }
        .padding(.top, model.notchSize.height)
        .padding([.horizontal, .bottom], 16)
    }

    private var dropBox: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.4))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isTargeted ? 0.12 : 0.04))
            )
            .overlay(
                VStack(spacing: 8) {
                    // Glass, and brighter while a drag is over the panel.
                    GlassGlyph(isLit: isTargeted) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 26, weight: .medium))
                            .symbolEffect(.bounce, value: dropArrivals)
                    }
                    Text(isTargeted ? "Release to add" : "Drop here")
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.8))
            )
            // Leans toward the pointer a little when a drag is over it.
            .scaleEffect(isTargeted && !reduceMotion ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .onChange(of: isTargeted) { _, targeted in
                if targeted { dropArrivals += 1 }
            }
    }
}

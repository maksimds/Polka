import SwiftUI
import UniformTypeIdentifiers

/// What the panel shows when another Mac wants to share something (NS-6, NS-7): the
/// drop zone's eyes under the notch, who's sharing and how much, every item as the
/// tile it would be on the shelf, and the answers.
///
/// Until Show Preview, nothing from the other Mac is decoded as an image: a file shows
/// the icon macOS has for its type, a link the generic link icon, and a text its page,
/// drawn here from the start of the text. Image decoders have been the way into real
/// zero-click attacks, and an offer opens the panel by itself. Show Preview, once for
/// the whole offer, swaps in the pictures the other Mac sent.
struct NearbyOfferView: View {
    let offer: NearbyIncomingOffer
    let images: ShelfItemImages
    /// The notch's height, which the header strip above the eyes takes.
    let headerHeight: CGFloat
    /// The pointer in the panel's SwiftUI space, for the eyes.
    let pointer: @MainActor () -> CGPoint?
    let onAnswer: @MainActor (NotchViewModel.OfferAnswer) -> Void

    /// Accept ignores clicks for this long after the view appears, so a click meant for
    /// something else as the panel opens can't accept by accident.
    static let acceptDelay: Duration = .milliseconds(700)

    @State private var acceptsClicks = false
    /// The other Mac's pictures, decoded once Show Preview is clicked.
    @State private var shownPictures: [ShelfItem.ID: NSImage]?

    private static let eyesTopGap: CGFloat = 6
    private static let eyesBottomGap: CGFloat = 8
    private static let buttonHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            DropZoneEyes(pointer: pointer, isTargeted: false)
                .frame(height: DropZoneEyes.eyeSize.height)
                .padding(.top, Self.eyesTopGap)
                .padding(.bottom, Self.eyesBottomGap)
            titleLine
                .padding(.bottom, 2)
            tiles
                .padding(.bottom, 4)
            buttons
        }
        .padding(.top, headerHeight)
        .padding(.horizontal, NotchView.sideInset)
        .padding(.bottom, 12)
        // Each offer is its own view, so the wait starts again for the next one.
        .task(id: offer.id) {
            shownPictures = nil
            acceptsClicks = false
            try? await Task.sleep(for: Self.acceptDelay)
            acceptsClicks = true
        }
    }

    /// "Alex wants to share 3 items", with "Not verified" beside it, since anyone can
    /// call themselves anything. A long name is cut short; the rest always shows.
    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(offer.senderName)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("wants to share \(itemCount)")
                .fixedSize()
            if offer.offer.hasFiles {
                Text(Self.size(offer.offer.totalFileBytes))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            }
            Text("Not verified")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                .fixedSize()
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private var itemCount: String {
        offer.previews.count == 1 ? "1 item" : "\(offer.previews.count) items"
    }

    /// "24 MB", as Finder counts.
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// On the shelf's own grid, so each tile sits where it would on the shelf. One row
    /// shows; more scroll.
    private var tiles: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: ShelfGridView.columns, spacing: ShelfGridLayout.spacing) {
                ForEach(offer.previews) { item in
                    NearbyOfferTile(item: item, images: images, picture: shownPictures?[item.id])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    /// Laid out on the grid as well, like the header: "Decline and Block" starts where
    /// the first column's pictures start, and Accept ends where the last column's end.
    private var buttons: some View {
        LazyVGrid(columns: ShelfGridView.columns, spacing: 0) {
            Button("Decline and Block") { onAnswer(.block) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
                .frame(width: ShelfItemTile.imageSide, alignment: .leading)
            Color.clear
            showPreviewButton
                .frame(width: ShelfItemTile.imageSide)
            Color.clear
            HStack(spacing: 8) {
                glassButton("Decline", tint: nil) { onAnswer(.decline) }
                glassButton("Accept", tint: SortMenuButton.activeColor) { onAnswer(.accept) }
                    .opacity(acceptsClicks ? 1 : 0.6)
                    .allowsHitTesting(acceptsClicks)
                    .animation(.easeOut(duration: 0.15), value: acceptsClicks)
            }
            .fixedSize()
            .frame(width: ShelfItemTile.imageSide, alignment: .trailing)
        }
        .frame(height: Self.buttonHeight)
    }

    /// Only for an offer that brought pictures, until they show.
    @ViewBuilder private var showPreviewButton: some View {
        if !offer.pictures.isEmpty && shownPictures == nil {
            Button("Show Preview") { showPictures() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
        } else {
            Color.clear
        }
    }

    /// Decodes the pictures, each checked again as a small PNG first. One that doesn't
    /// pass keeps its icon.
    private func showPictures() {
        var pictures: [ShelfItem.ID: NSImage] = [:]
        for (id, data) in offer.pictures {
            guard let image = NearbyPreviewImage.decode(data) else { continue }
            // Drawn at half its pixels, like a Retina thumbnail.
            pictures[id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        }
        withAnimation(.easeOut(duration: 0.2)) { shownPictures = pictures }
    }

    /// Glass, like the link field's Add button.
    private func glassButton(_ title: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: Self.buttonHeight)
                .background(GlassSurface(RoundedRectangle(cornerRadius: 6, style: .continuous), tint: tint))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An offered item drawn as its tile would be on the shelf: its picture, name and
/// type line, at the shelf's sizes. Only looked at, never pressed or dragged. A file
/// that can run something when opened (an app, a script, an installer) gets a warning
/// mark on its picture.
private struct NearbyOfferTile: View {
    let item: ShelfItem
    let images: ShelfItemImages
    /// The other Mac's picture, once Show Preview was clicked.
    let picture: NSImage?

    /// The mark's yellow, the system's warning color on a dark background.
    static let warningColor = Color(red: 1, green: 0.8, blue: 0)

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: picture ?? icon)
                .resizable()
                .scaledToFit()
                .frame(width: ShelfItemTile.imageSide, height: ShelfItemTile.imageSide)
                .overlay(alignment: .topLeading) {
                    if mayRun {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Self.warningColor)
                            .shadow(color: .black.opacity(0.5), radius: 1.5)
                            .offset(x: -4, y: -4)
                            .accessibilityLabel("Can run code when opened")
                    }
                }
                .padding(.bottom, 4)
            Text(item.displayName)
                .font(Font(ShelfItemTile.nameFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
            Text(item.typeLabel)
                .font(.system(size: 10))
                .foregroundStyle(mayRun ? Self.warningColor : .white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ShelfItemTile.height)
    }

    private var mayRun: Bool {
        item.kind == .file && NearbyFileName.mayRun(item.title)
    }

    /// A file's is the icon macOS has for its type, worked out here from the name's
    /// extension, never from the file, which isn't here yet. Links and text are
    /// drawn as on the shelf.
    private var icon: NSImage {
        guard item.kind == .file else { return images.image(for: item) }
        let ext = (item.title as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

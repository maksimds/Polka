import SwiftUI

/// The black shape hanging from the notch. It grows from notch size to the
/// expanded size, anchored at the top center of the panel.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: ShelfStore
    let images: ShelfItemImages
    let dragSource: ShelfDragSource

    private var isTargeted: Bool { model.isDropTargeted }

    private var cornerRadius: CGFloat {
        model.state == .collapsed ? 10 : 24
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: model.currentSize.width, height: model.currentSize.height)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius,
                                           bottomTrailingRadius: cornerRadius,
                                           style: .continuous)
                        .fill(Color.black)
                )
            // Drops are received by DropTargetView (AppKit), which wraps this view.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.state)
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .collapsed:
            Color.clear
        case .expanded:
            expandedContent
                .transition(.opacity)
        case .dropReady:
            dropZone
                .transition(.opacity)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                Text("Drag a file or link here")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ShelfGridView(items: store.items, images: images, dragSource: dragSource)
            }
            // Below the grid so it never covers a tile, and tiles don't shift under the pointer.
            if let notice = model.notice {
                NoticeBanner(message: notice) { model.dismissNotice() }
                    .transition(.opacity)
            }
        }
        .font(.system(size: 13))
        .padding(.top, model.notchSize.height + 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.4))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isTargeted ? 0.12 : 0.04))
            )
            .overlay(
                Text(isTargeted ? "Release to add" : "Drop here")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .padding(.top, model.notchSize.height + 8)
            .padding([.horizontal, .bottom], 16)
    }
}

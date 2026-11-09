import SwiftUI

/// The black shape hanging from the notch. It grows from notch size to the
/// expanded size, anchored at the top center of the panel.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @State private var isTargeted = false

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
                .onDrop(of: DropReceiver.acceptedTypes, isTargeted: $isTargeted) { providers in
                    model.handleDrop(providers)
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.state)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Polka")
                .font(.headline)
                .foregroundStyle(.white)
            if model.recentDrops.isEmpty {
                Text("Drag a file or link here")
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(model.recentDrops, id: \.self) { label in
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.top, model.notchSize.height + 8)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
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

import SwiftUI

/// A message inside the panel that stays until the user closes it.
/// It lives in the panel because a system alert would activate Polka and take
/// focus away from the app you're using.
struct NoticeBanner: View {
    let message: String
    let onClose: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button(action: onClose) {
                GlassCloseMark()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close message")
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Files arriving from another Mac (NS-10): "Receiving 3 items from Alex… 40%", in the
/// message's place and look, filling from the left as they arrive. Its × stops the
/// transfer, and nothing from it is kept.
struct NearbyReceivingBanner: View {
    let receiving: NearbyReceiving
    let onCancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer(minLength: 0)
            Button(action: onCancel) {
                GlassCloseMark()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop receiving")
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            Color(white: 0.2)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Color(white: 0.3)
                            .frame(width: proxy.size.width * receiving.fraction)
                            .animation(.linear(duration: 0.2), value: receiving.fraction)
                    }
                }
                .clipShape(shape)
        }
    }

    private var message: String {
        let items = receiving.itemCount == 1 ? "1 item" : "\(receiving.itemCount) items"
        return "Receiving \(items) from \(receiving.senderName)… \(Int(receiving.fraction * 100))%"
    }
}

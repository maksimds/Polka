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

import SwiftUI

/// What the shelf turns into for "Add New", "Link…": a field for typing a link, under
/// a header strip that names it and has a × to go back to the shelf.
///
/// The panel takes the keys only while this is showing (see `NotchPanel`).
struct LinkEntryView: View {
    /// The notch's height, which the header strip shares, like the shelf's.
    let headerHeight: CGFloat
    /// The panel's width, for lining the field up with the tiles' pictures.
    let width: CGFloat
    /// Adds the link, or returns what to say under the field instead.
    let onSubmit: @MainActor (String) -> String?
    let onCancel: @MainActor () -> Void

    @State private var text = ""
    /// Why the last Return added nothing. Cleared as soon as the text changes.
    @State private var problem: String?
    @FocusState private var isFieldFocused: Bool

    private static let topGap: CGFloat = 10
    private static let fieldHeight: CGFloat = 36
    private static let messageGap: CGFloat = 8
    private static let messageHeight: CGFloat = 14
    private static let bottomInset: CGFloat = 16
    /// From the field's edge to its text, and to the line under it.
    private static let textInset: CGFloat = 12

    /// Everything below the header strip, which sets how tall the shape becomes.
    static let contentHeight = topGap + fieldHeight + messageGap + messageHeight + bottomInset

    /// A soft red that reads on the black panel.
    private static let problemColor = Color(.sRGB, red: 1, green: 0.45, blue: 0.42)

    /// The field and the header's ends line up with the first and last columns'
    /// pictures, like the shelf's header strip.
    private var sideInset: CGFloat {
        let gridWidth = width - 2 * NotchView.sideInset
        return NotchView.sideInset + ShelfGridLayout(width: gridWidth).pictureInset
    }

    private var canAdd: Bool {
        LinkInput.url(from: text) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: headerHeight)
            field
                .padding(.top, Self.topGap)
            messageLine
                .frame(height: Self.messageHeight)
                .padding(.top, Self.messageGap)
                .padding(.leading, Self.textInset)
        }
        .padding(.horizontal, sideInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Light placeholder, caret and selection on the black panel.
        .environment(\.colorScheme, .dark)
        .onAppear {
            // A tick later too, in case the panel only became key as this appeared.
            isFieldFocused = true
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var header: some View {
        HStack {
            Text("Add Link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
            Spacer(minLength: 0)
            // Where the gear is on the shelf. Esc presses it.
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: headerHeight)
                    .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
            TextField("Link", text: $text, prompt: Text("https://example.com"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .onSubmit(submit)
                // Esc, in case the field takes it before the ×'s shortcut sees it.
                .onExitCommand(perform: onCancel)
                .onChange(of: text) {
                    problem = nil
                }
            addButton
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, 6)
        .frame(height: Self.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(problem == nil ? Color.white.opacity(0.12) : Self.problemColor.opacity(0.7),
                              lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: problem)
    }

    /// Blue like an active sort once there's a link to add, dim until then.
    private var addButton: some View {
        Button(action: submit) {
            Text("Add")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(canAdd ? 1 : 0.35))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(canAdd ? SortMenuButton.activeColor : Color.white.opacity(0.1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .animation(.easeOut(duration: 0.15), value: canAdd)
    }

    @ViewBuilder
    private var messageLine: some View {
        if let problem {
            Text(problem)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.problemColor)
                .transition(.opacity)
        } else {
            Text("Press Return to add, or Esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .transition(.opacity)
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        problem = onSubmit(text)
    }
}

import SwiftUI

/// The contents of the Settings window.
struct SettingsView: View {
    @ObservedObject var loginItem: LoginItem
    /// Nil when Polka has no folder of its own to save screenshots in.
    let screenshots: ScreenshotCatcher?

    /// The raw stored value, watched by SwiftUI, so a change made with
    /// `defaults write` while the window is open shows up too.
    @AppStorage(ShelfSettings.temporaryLifetimeKey) private var storedLifetime: Double = 0
    @AppStorage(ShelfSettings.hoverDelayKey) private var storedHoverDelay = ShelfSettings.defaultHoverDelay
    @AppStorage(ShelfSettings.hoverAreaKey) private var hoverArea = ShelfSettings.defaultHoverArea
    @AppStorage(ShelfSettings.panelTransparencyKey) private var storedTransparency = ShelfSettings.defaultPanelTransparency
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var lifetime: Binding<TimeInterval> {
        Binding(get: { ShelfSettings.temporaryLifetime(stored: storedLifetime) },
                set: { storedLifetime = $0 })
    }

    private var hoverDelay: Int {
        ShelfSettings.hoverDelay(stored: storedHoverDelay)
    }

    /// The slider moves in 50 ms steps. They're rounded here rather than given to the
    /// slider as `step`, which would draw 17 tick marks under it.
    private var hoverDelaySlider: Binding<Double> {
        Binding(get: { Double(hoverDelay) },
                set: { storedHoverDelay = Int(($0 / 50).rounded()) * 50 })
    }

    private var hoverDelayLabel: String {
        hoverDelay == 0 ? "Instantly" : "\(hoverDelay) ms"
    }

    private var transparency: Int {
        ShelfSettings.panelTransparency(stored: storedTransparency)
    }

    /// In 5% steps, rounded here like the hover delay's, so there are no tick marks.
    private var transparencySlider: Binding<Double> {
        Binding(get: { Double(transparency) },
                set: { storedTransparency = Int(($0 / 5).rounded()) * 5 })
    }

    private var transparencyLabel: String {
        transparency == 0 ? "Solid" : "\(transparency)%"
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
            }

            Section {
                LabeledContent("Transparency") {
                    HStack(spacing: 10) {
                        Slider(value: transparencySlider,
                               in: Double(ShelfSettings.panelTransparencyRange.lowerBound)...Double(ShelfSettings.panelTransparencyRange.upperBound))
                            .labelsHidden()
                            .frame(width: 150)
                        Text(transparencyLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                .disabled(reduceTransparency)
                PanelColorSwatches()
                PanelColorHexField()
            } header: {
                Text("Appearance")
            } footer: {
                // About as long either way, so the window keeps its height.
                SettingsFootnote(text: reduceTransparency
                    ? "Reduce Transparency is on in Accessibility settings, so the shelf isn't see-through. A color becomes a deep, glassy gradient, so names stay readable."
                    : "Transparency lets what's behind the open shelf show through, blurred, as in Finder. A color becomes a deep, glassy gradient, so names stay readable.")
            }

            Section {
                LabeledContent("Open after") {
                    HStack(spacing: 10) {
                        Slider(value: hoverDelaySlider,
                               in: Double(ShelfSettings.hoverDelayRange.lowerBound)...Double(ShelfSettings.hoverDelayRange.upperBound))
                            .labelsHidden()
                            .frame(width: 150)
                        Text(hoverDelayLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                Picker("Hover area", selection: $hoverArea) {
                    ForEach(HoverArea.allCases, id: \.self) { area in
                        Text(area.title).tag(area)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Hover")
            } footer: {
                SettingsFootnote(text: "A larger area or a shorter wait means more accidental opens.")
            }

            Section {
                Picker("Temporary items last", selection: lifetime) {
                    ForEach(ShelfSettings.temporaryLifetimeChoices(current: lifetime.wrappedValue),
                            id: \.self) { seconds in
                        Text(ShelfSettings.label(forLifetime: seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Shelf")
            } footer: {
                SettingsFootnote(text: "Items that are already temporary keep the time they have left.")
                    .padding(.bottom, screenshots == nil ? 10 : 0)
            }

            if let screenshots {
                ScreenshotsSection(catcher: screenshots)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

}

/// "Save Screenshots to Polka" (FR-20). Its own view, so it can watch the switch's
/// state, which macOS's Screenshot toolbar can also change.
private struct ScreenshotsSection: View {
    @ObservedObject var catcher: ScreenshotCatcher

    var body: some View {
        Section {
            Toggle("Save Screenshots to Polka", isOn: Binding(
                get: { catcher.isEnabled },
                set: { catcher.setEnabled($0) }
            ))
        } header: {
            Text("Screenshots")
        } footer: {
            // The same sentence on and off, so the window doesn't change height.
            SettingsFootnote(text: """
                Screenshots and screen recordings go on the shelf as temporary items, not \
                to \(catcher.usualLocationName), and to the Trash when they expire or are removed.
                """)
                .padding(.bottom, 10)
        }
    }
}

/// The panel's color (FR-24) as swatches, each drawn as the glass it makes, so a
/// light color shows up deepened, as it will be. Only the gradient's lighter half, the
/// panel's top left, fits in a swatch: the whole of it, dark end included, left
/// neighbors such as Pink, Red and Orange hard to tell apart. The chosen one is ringed.
/// Black is the panel as it always was.
private struct PanelColorSwatches: View {
    @AppStorage(ShelfSettings.panelColorKey) private var storedColor = ""

    var body: some View {
        let current = ShelfSettings.panelColor(stored: storedColor)
        LabeledContent("Color") {
            HStack(spacing: 4) {
                ForEach(PanelColor.swatches) { swatch in
                    Button {
                        storedColor = ShelfSettings.storedValue(for: swatch.color)
                    } label: {
                        PanelSwatchView(color: swatch.color, isSelected: swatch.color == current)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(swatch.color == current ? .isSelected : [])
                }
            }
        }
    }
}

private struct PanelSwatchView: View {
    let color: PanelColor?
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(fill)
            // Dark swatches would melt into a dark window without an edge.
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .frame(width: 18, height: 18)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isSelected ? 1 : 0))
            .contentShape(Circle())
    }

    /// The gradient stretched to twice the swatch, so the swatch holds its first half.
    private var fill: LinearGradient {
        guard let gradient = color?.gradient else {
            return LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(gradient.start), Color(gradient.end)],
                              startPoint: .topLeading, endPoint: UnitPoint(x: 2, y: 2))
    }
}

/// The panel's color as a hex code: "#2881DB", "2881db" or "#28D". Return or a click
/// elsewhere applies what's typed. A code Polka can't read turns red and changes
/// nothing; an empty field goes back to the current code.
private struct PanelColorHexField: View {
    @AppStorage(ShelfSettings.panelColorKey) private var storedColor = ""
    @State private var text = ""
    @State private var isWrong = false
    @FocusState private var isEditing: Bool

    private var currentHex: String {
        (ShelfSettings.panelColor(stored: storedColor) ?? .black).hex
    }

    var body: some View {
        LabeledContent("Hex") {
            TextField("Hex", text: $text, prompt: Text(currentHex))
                .labelsHidden()
                // A grouped form draws its fields without a border, which read as a label.
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .foregroundStyle(isWrong ? Color.red : Color.primary)
                .frame(width: 84)
                .focused($isEditing)
                .onSubmit(apply)
        }
        .onAppear { text = currentHex }
        // A swatch was picked, or the field was applied.
        .onChange(of: storedColor) {
            guard !isEditing else { return }
            text = currentHex
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { apply() }
        }
        .onChange(of: text) {
            isWrong = false
        }
    }

    private func apply() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            text = currentHex
            return
        }
        guard let color = PanelColor(hex: text) else {
            isWrong = true
            return
        }
        storedColor = ShelfSettings.storedValue(for: color)
        text = color.hex
    }
}

/// The small grey note under a section, lined up with the row labels.
private struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            // Form footers center wrapped lines unless told otherwise.
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

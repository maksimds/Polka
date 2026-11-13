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
                PanelColorPicker()
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
        // Only scrolls when the screen is too short for the whole form; otherwise the
        // window is exactly as tall as the form (`SettingsWindowController`).
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
    }

    static let width: CGFloat = 440

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

/// The panel's color (FR-24), picked as on the web: a square of saturation (across)
/// and brightness (down) for the hue chosen on the rainbow bar under it. The block on
/// its left shows the shelf as it will look, the deepened glass made from the color,
/// not the color itself. The very bottom of the square is black, the panel as it
/// always was.
private struct PanelColorPicker: View {
    @AppStorage(ShelfSettings.panelColorKey) private var storedColor = ""
    /// What the picker shows, kept apart from the stored code: black and greys have
    /// no hue, and black no saturation, so these stay where they were when you pass
    /// through them, and rounding to a hex code doesn't nudge the thumbs.
    @State private var hue = PanelColor(hex: "#2881DB")?.hsb.hue ?? 0
    @State private var saturation = 1.0
    @State private var brightness = 0.0
    /// The code the picker stored last, so its own change isn't read back in.
    @State private var written: String?

    private static let squareHeight: CGFloat = 104
    private static let previewWidth: CGFloat = 92
    private static let cornerRadius: CGFloat = 6
    private static let hueBarHeight: CGFloat = 10
    private static let thumbSide: CGFloat = 16

    private var picked: PanelColor {
        PanelColor(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color")
            HStack(spacing: 0) {
                preview
                    .frame(width: Self.previewWidth)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius,
                                                      bottomLeadingRadius: Self.cornerRadius,
                                                      style: .continuous))
                square
            }
            .frame(height: Self.squareHeight)
            hueBar
        }
        .padding(.vertical, 2)
        .onAppear(perform: readStored)
        // The hex field changed it.
        .onChange(of: storedColor) {
            if storedColor != written { readStored() }
        }
    }

    // MARK: - Parts

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            if let gradient = ShelfSettings.panelColor(stored: storedColor)?.gradient {
                Rectangle().fill(gradient.linear)
                Rectangle().fill(PanelBackground.sheen)
            } else {
                Color.black
            }
            GlassTitle(text: "Polka")
                .padding(8)
        }
        .accessibilityHidden(true)
        .help("How the shelf will look")
    }

    private var square: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(PanelColor(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: Self.cornerRadius,
                                              topTrailingRadius: Self.cornerRadius,
                                              style: .continuous))
            // After the clip, so a thumb at the edge isn't cut in half.
            .overlay {
                PickerThumb(color: picked, side: Self.thumbSide)
                    .position(x: saturation * size.width, y: (1 - brightness) * size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                saturation = Self.share(drag.location.x, of: size.width)
                brightness = 1 - Self.share(drag.location.y, of: size.height)
                write()
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue("\(Int((saturation * 100).rounded()))% saturation, \(Int((brightness * 100).rounded()))% brightness")
        .accessibilityAdjustableAction { direction in
            brightness = min(max(brightness + (direction == .increment ? 0.05 : -0.05), 0), 1)
            write()
        }
    }

    /// The rainbow, red to red. Its thumb travels between the middles of its round
    /// ends, so it never hangs past them.
    private var hueBar: some View {
        GeometryReader { geometry in
            let inset = Self.hueBarHeight / 2
            let travel = max(geometry.size.width - inset * 2, 1)
            Capsule()
                .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
                    Color(PanelColor(hue: $0 == 1 ? 0 : $0, saturation: 1, brightness: 1))
                }, startPoint: .leading, endPoint: .trailing))
                .frame(height: Self.hueBarHeight)
                .frame(maxHeight: .infinity)
                .overlay {
                    PickerThumb(color: Color(PanelColor(hue: hue, saturation: 1, brightness: 1)), side: Self.thumbSide)
                        .position(x: inset + hue * travel, y: geometry.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    hue = Self.share(drag.location.x - inset, of: travel)
                    write()
                })
        }
        .frame(height: Self.thumbSide + 4)
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            hue = min(max(hue + (direction == .increment ? 1.0 : -1.0) / 36, 0), 1)
            write()
        }
    }

    // MARK: - Reading and writing

    private static func share(_ position: CGFloat, of length: CGFloat) -> Double {
        min(max(Double(position / max(length, 1)), 0), 1)
    }

    private func write() {
        let value = ShelfSettings.storedValue(for: picked)
        written = value
        storedColor = value
    }

    private func readStored() {
        guard let color = ShelfSettings.panelColor(stored: storedColor) else {
            // Black: the bottom of the square, with hue and saturation kept.
            brightness = 0
            return
        }
        let hsb = color.hsb
        brightness = hsb.brightness
        if hsb.saturation > 0 {
            saturation = hsb.saturation
            hue = hsb.hue
        } else {
            saturation = 0
        }
    }
}

/// A picker's handle: the color it's on, ringed in white, lifted by a soft shadow.
private struct PickerThumb: View {
    let color: Color
    let side: CGFloat

    init(color: PanelColor, side: CGFloat) {
        self.init(color: Color(color), side: side)
    }

    init(color: Color, side: CGFloat) {
        self.color = color
        self.side = side
    }

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .allowsHitTesting(false)
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
        // The picker changed it, or the field was applied.
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

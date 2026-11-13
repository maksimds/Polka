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
            } header: {
                Text("Appearance")
            } footer: {
                // About as long either way, so the window keeps its height.
                SettingsFootnote(text: reduceTransparency
                    ? "Reduce Transparency is on in Accessibility settings, so the shelf stays solid."
                    : "How much of what's behind the open shelf shows through, blurred, as in Finder.")
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

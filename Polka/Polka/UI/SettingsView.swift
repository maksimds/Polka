import SwiftUI

/// The contents of the Settings window.
struct SettingsView: View {
    @ObservedObject var loginItem: LoginItem

    /// The raw stored value, watched by SwiftUI, so a change made with
    /// `defaults write` while the window is open shows up too.
    @AppStorage(ShelfSettings.temporaryLifetimeKey) private var storedLifetime: Double = 0
    @AppStorage(ShelfSettings.hoverDelayKey) private var storedHoverDelay = ShelfSettings.defaultHoverDelay
    @AppStorage(ShelfSettings.hoverAreaKey) private var hoverArea = ShelfSettings.defaultHoverArea

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

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
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
                footnote("A larger area or a shorter wait means more accidental opens.")
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
                footnote("Items that are already temporary keep the time they have left.")
                    .padding(.bottom, 10)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The small grey note under a section, lined up with the row labels.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            // Form footers center wrapped lines unless told otherwise.
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

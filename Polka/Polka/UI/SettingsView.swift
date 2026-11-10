import SwiftUI

/// The contents of the Settings window.
struct SettingsView: View {
    @ObservedObject var loginItem: LoginItem

    /// The raw stored value, watched by SwiftUI, so a change made with
    /// `defaults write` while the window is open shows up too.
    @AppStorage(ShelfSettings.temporaryLifetimeKey) private var storedLifetime: Double = 0

    private var lifetime: Binding<TimeInterval> {
        Binding(get: { ShelfSettings.temporaryLifetime(stored: storedLifetime) },
                set: { storedLifetime = $0 })
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
                Picker("Temporary items last", selection: lifetime) {
                    ForEach(ShelfSettings.temporaryLifetimeChoices(current: lifetime.wrappedValue),
                            id: \.self) { seconds in
                        Text(ShelfSettings.label(forLifetime: seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Items that are already temporary keep the time they have left.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

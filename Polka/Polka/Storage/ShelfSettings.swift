import Foundation

/// Preferences kept in UserDefaults. A Settings window arrives in M4; until then they
/// can be changed with `defaults write com.maksimds.Polka <key> <value>`.
struct ShelfSettings {
    static let temporaryLifetimeKey = "temporaryLifetimeSeconds"
    static let defaultTemporaryLifetime: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How long an item lasts after it is made temporary.
    var temporaryLifetime: TimeInterval {
        let stored = defaults.double(forKey: Self.temporaryLifetimeKey)
        return stored > 0 ? stored : Self.defaultTemporaryLifetime
    }
}

import Foundation

/// Preferences kept in UserDefaults and changed in the Settings window. They can also
/// be set with `defaults write com.maksimds.Polka <key> <value>`.
struct ShelfSettings {
    static let temporaryLifetimeKey = "temporaryLifetimeSeconds"
    static let defaultTemporaryLifetime: TimeInterval = 24 * 60 * 60

    private static let hour: TimeInterval = 60 * 60

    /// The lifetimes Settings offers, in hours: 1, 6 and 12 hours, 1 and 3 days, 1 week.
    static let standardTemporaryLifetimes: [TimeInterval] = [1, 6, 12, 24, 72, 168].map { $0 * hour }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How long an item lasts after it is made temporary. Changing it doesn't touch
    /// items that are already temporary: each one keeps the expiry it was given.
    var temporaryLifetime: TimeInterval {
        get { Self.temporaryLifetime(stored: defaults.double(forKey: Self.temporaryLifetimeKey)) }
        nonmutating set { defaults.set(newValue, forKey: Self.temporaryLifetimeKey) }
    }

    /// The lifetime a stored value stands for. Zero (nothing stored) or less means the default.
    static func temporaryLifetime(stored: Double) -> TimeInterval {
        stored > 0 ? stored : defaultTemporaryLifetime
    }

    /// The choices to show in Settings: the standard ones, plus the current lifetime
    /// if it was set to something else with `defaults write`, so it isn't lost.
    static func temporaryLifetimeChoices(current: TimeInterval) -> [TimeInterval] {
        if standardTemporaryLifetimes.contains(current) {
            return standardTemporaryLifetimes
        }
        return (standardTemporaryLifetimes + [current]).sorted()
    }

    /// A lifetime written out for Settings: "6 hours", "1 day", "1 week",
    /// or "1 day, 6 hours" for a lifetime set by hand.
    static func label(forLifetime seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds)) seconds"
    }
}

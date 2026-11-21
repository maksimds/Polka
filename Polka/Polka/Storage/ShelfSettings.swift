import Foundation

/// Preferences kept in UserDefaults and changed in the Settings window. They can also
/// be set with `defaults write com.maksimds.Polka <key> <value>`.
struct ShelfSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Hover

    static let hoverDelayKey = "hoverDelayMilliseconds"
    static let defaultHoverDelay = 250
    /// The delays Settings offers, in milliseconds. A stored value outside it counts
    /// as the nearest end.
    static let hoverDelayRange = 0...800

    /// How long the pointer has to stay on the notch before the panel opens, in
    /// milliseconds. Zero opens it right away.
    var hoverDelay: Int {
        get { Self.hoverDelay(stored: defaults.object(forKey: Self.hoverDelayKey) as? Int) }
        nonmutating set { defaults.set(newValue, forKey: Self.hoverDelayKey) }
    }

    /// The delay a stored value stands for. Nothing stored means the default; zero is
    /// a real choice, opening at once.
    static func hoverDelay(stored: Int?) -> Int {
        guard let stored else { return defaultHoverDelay }
        return min(max(stored, hoverDelayRange.lowerBound), hoverDelayRange.upperBound)
    }

    static let hoverAreaKey = "hoverArea"
    static let defaultHoverArea = HoverArea.small

    /// How far around the notch the pointer opens the panel.
    var hoverArea: HoverArea {
        get { defaults.string(forKey: Self.hoverAreaKey).flatMap(HoverArea.init(rawValue:)) ?? Self.defaultHoverArea }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.hoverAreaKey) }
    }

    // MARK: - Appearance

    static let panelTransparencyKey = "panelTransparencyPercent"
    /// Solid black, as the panel always was.
    static let defaultPanelTransparency = 0
    static let panelTransparencyRange = 0...100

    /// How see-through the open panel is, in percent: 0 is solid black, 100 is the
    /// blurred glass alone.
    var panelTransparency: Int {
        get { Self.panelTransparency(stored: defaults.integer(forKey: Self.panelTransparencyKey)) }
        nonmutating set { defaults.set(newValue, forKey: Self.panelTransparencyKey) }
    }

    /// The transparency a stored value stands for. Nothing stored reads as 0, which is
    /// the default; a value outside the range counts as the nearest end.
    static func panelTransparency(stored: Int) -> Int {
        min(max(stored, panelTransparencyRange.lowerBound), panelTransparencyRange.upperBound)
    }

    static let panelColorKey = "panelColor"

    /// The color the open panel's glass is made from, kept as its hex code. Nil is
    /// black, the panel as it always was.
    var panelColor: PanelColor? {
        get { Self.panelColor(stored: defaults.string(forKey: Self.panelColorKey) ?? "") }
        nonmutating set { defaults.set(Self.storedValue(for: newValue), forKey: Self.panelColorKey) }
    }

    /// The color a stored value stands for. Nothing stored, a code Polka can't read,
    /// or #000000 is black.
    static func panelColor(stored: String) -> PanelColor? {
        guard let color = PanelColor(hex: stored), color != .black else { return nil }
        return color
    }

    /// What's stored for a color: its hex code, or nothing for black.
    static func storedValue(for color: PanelColor?) -> String {
        guard let color, color != .black else { return "" }
        return color.hex
    }

    // MARK: - Sorting

    static let shelfSortKey = "shelfSort"

    /// The "Sort By" choice from the header's sort menu. Nothing stored, or a value
    /// Polka doesn't know, means `none`.
    var shelfSort: ShelfSort {
        get { defaults.string(forKey: Self.shelfSortKey).flatMap(ShelfSort.init(rawValue:)) ?? .none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.shelfSortKey) }
    }

    // MARK: - Nearby Sharing

    static let nearbySharingKey = "nearbySharingEnabled"
    static let nearbyNameKey = "nearbyDisplayName"
    static let nearbyReceiveFromKey = "nearbyReceiveFrom"

    /// Nearby Sharing's switch (NS-1). Off by default: until it's turned on, Polka
    /// doesn't advertise, browse or listen, and nobody nearby can see or reach it.
    var nearbySharingEnabled: Bool {
        get { defaults.bool(forKey: Self.nearbySharingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.nearbySharingKey) }
    }

    /// The name others see, as typed in Settings (NS-2). Empty means the Mac's name.
    var nearbyName: String {
        get { defaults.string(forKey: Self.nearbyNameKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.nearbyNameKey) }
    }

    /// Who can see this Mac and send to it (NS-3). Everyone by default.
    var nearbyReceiveFrom: NearbyReceiveFrom {
        get { defaults.string(forKey: Self.nearbyReceiveFromKey).flatMap(NearbyReceiveFrom.init(rawValue:)) ?? .everyone }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.nearbyReceiveFromKey) }
    }

    /// The name others see: what was typed, cleaned as any name is, or else the Mac's
    /// name, or else "Mac".
    static func nearbyName(typed: String, macName: String) -> String {
        NearbyName.clean(typed) ?? NearbyName.clean(macName) ?? "Mac"
    }
}

/// Settings' "Receive From" for Nearby Sharing.
enum NearbyReceiveFrom: String, CaseIterable {
    /// Anyone nearby with Polka can see this Mac's name and send to it.
    case everyone
    /// Only remembered Macs can. Everyone else gets no name and no answer.
    case remembered

    var title: String {
        switch self {
        case .everyone: return "Everyone"
        case .remembered: return "Remembered Macs Only"
        }
    }
}

/// The hover area setting. The sizes in points are in `NotchGeometry`.
enum HoverArea: String, CaseIterable {
    /// Just the notch.
    case small
    /// The notch and a little around it.
    case medium
    /// A wide margin around the notch.
    case large

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

import Foundation

/// A color picked for the panel in Settings (FR-24), by swatch or hex code. It's never
/// drawn as it is: `gradient` turns it into the panel's glass, a diagonal two-tone
/// deepened so the shelf's white names stay readable on it, whatever was picked.
struct PanelColor: Hashable {
    /// sRGB, from 0 to 1.
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Reads "#2881DB", "2881db" or the short "#FFF", with spaces around allowed.
    /// Nil for anything else.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 3 || digits.count == 6,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 3 {
            // Each digit doubled: "F80" is "FF8800".
            let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
            self.init(red: Double(r * 17) / 255, green: Double(g * 17) / 255, blue: Double(b * 17) / 255)
        } else {
            self.init(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        }
    }

    /// "#2881DB": six digits, capitals.
    var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static let black = PanelColor(red: 0, green: 0, blue: 0)

    // MARK: - Swatches

    /// Settings' swatches: Black, the panel as it always was, then macOS's accent
    /// colors as Dark Mode draws them.
    static let swatches: [PanelSwatch] = [
        PanelSwatch(name: "Black", color: nil),
        PanelSwatch(name: "Blue", hex: "#0A84FF"),
        PanelSwatch(name: "Purple", hex: "#BF5AF2"),
        PanelSwatch(name: "Pink", hex: "#FF375F"),
        PanelSwatch(name: "Red", hex: "#FF453A"),
        PanelSwatch(name: "Orange", hex: "#FF9F0A"),
        PanelSwatch(name: "Yellow", hex: "#FFD60A"),
        PanelSwatch(name: "Green", hex: "#32D74B"),
        PanelSwatch(name: "Graphite", hex: "#98989D"),
    ]

    // MARK: - Gradient

    /// The lightest the gradient gets, as relative luminance (WCAG's measure of how
    /// light a color looks). White on it has a contrast of 9.5:1.
    static let lightestLuminance = 0.06
    /// Every color is darkened at least this much (kept to this share of its
    /// brightness), so even a dark pick turns deeper and reads as glass.
    static let deepening = 0.55
    /// How far the two ends turn around the color wheel, in degrees, the start one way
    /// and the end the other, so the gradient has some depth rather than being one
    /// color fading.
    static let hueTurn = 14.0
    /// How dark the end is next to the start.
    static let endShade = 0.36

    /// The panel's glass for this color: from `start` at the top left to `end` at the
    /// bottom right.
    var gradient: PanelGradient {
        PanelGradient(start: turningHue(by: Self.hueTurn).deepened(),
                      end: turningHue(by: -Self.hueTurn).deepened().scaled(by: Self.endShade))
    }

    /// WCAG's relative luminance: 0 for black, 1 for white.
    var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// How well white text reads on this color, from 1:1 to 21:1.
    var contrastWithWhite: Double {
        1.05 / (luminance + 0.05)
    }

    func scaled(by share: Double) -> PanelColor {
        PanelColor(red: red * share, green: green * share, blue: blue * share)
    }

    /// The color darkened by `deepening`, or further, as little as it takes to bring
    /// it to `lightestLuminance`.
    func deepened() -> PanelColor {
        let deepest = scaled(by: Self.deepening)
        guard deepest.luminance > Self.lightestLuminance else { return deepest }
        // Luminance only grows with the share, so halve the range until it's found.
        var low = 0.0, high = Self.deepening
        for _ in 0..<30 {
            let middle = (low + high) / 2
            if scaled(by: middle).luminance <= Self.lightestLuminance {
                low = middle
            } else {
                high = middle
            }
        }
        return scaled(by: low)
    }

    /// The same color turned around the color wheel, keeping its saturation and
    /// brightness. A grey has no hue, so it stays as it is.
    func turningHue(by degrees: Double) -> PanelColor {
        let brightest = max(red, green, blue)
        let range = brightest - min(red, green, blue)
        guard range > 0 else { return self }

        var hue: Double
        switch brightest {
        case red: hue = (green - blue) / range
        case green: hue = (blue - red) / range + 2
        default: hue = (red - green) / range + 4
        }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }

        let side = hue / 60
        let middle = range * (1 - abs(side.truncatingRemainder(dividingBy: 2) - 1))
        let lowest = brightest - range
        let (r, g, b): (Double, Double, Double)
        switch side {
        case ..<1: (r, g, b) = (range, middle, 0)
        case ..<2: (r, g, b) = (middle, range, 0)
        case ..<3: (r, g, b) = (0, range, middle)
        case ..<4: (r, g, b) = (0, middle, range)
        case ..<5: (r, g, b) = (middle, 0, range)
        default: (r, g, b) = (range, 0, middle)
        }
        return PanelColor(red: r + lowest, green: g + lowest, blue: b + lowest)
    }
}

/// The two ends of the panel's glass for a picked color.
struct PanelGradient: Equatable {
    let start: PanelColor
    let end: PanelColor
}

/// One of Settings' swatches. Black has no color: the panel as it always was.
struct PanelSwatch: Identifiable {
    let name: String
    let color: PanelColor?

    var id: String { name }

    init(name: String, color: PanelColor?) {
        self.name = name
        self.color = color
    }

    init(name: String, hex: String) {
        self.init(name: name, color: PanelColor(hex: hex))
    }
}

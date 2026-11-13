import Foundation
import Testing
@testable import Polka

/// Settings' Color (FR-24): hex codes, the picker's terms, and the glass made from a color.
struct PanelColorTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - Hex codes

    @Test func aCodeIsReadWithOrWithoutItsHashInAnyCase() throws {
        let expected = PanelColor(red: 0x28 / 255, green: 0x81 / 255, blue: 0xDB / 255)
        for code in ["#2881DB", "2881db", "  #2881Db\n"] {
            #expect(PanelColor(hex: code) == expected)
        }
    }

    @Test func aShortCodeDoublesEachDigit() {
        #expect(PanelColor(hex: "#F80")?.hex == "#FF8800")
        #expect(PanelColor(hex: "fff")?.hex == "#FFFFFF")
    }

    @Test func anythingElseIsNotACode() {
        for text in ["", "#", "#12345", "#1234567", "GGGGGG", "#12 345", "##123456", "0x123456", "-12345"] {
            #expect(PanelColor(hex: text) == nil, "\(text)")
        }
    }

    @Test func aCodeIsWrittenInSixCapitalDigits() throws {
        #expect(try #require(PanelColor(hex: "#2881db")).hex == "#2881DB")
        #expect(PanelColor.black.hex == "#000000")
    }

    // MARK: - Settings

    @Test func thePanelStartsBlack() throws {
        try withDefaults { defaults in
            #expect(ShelfSettings(defaults: defaults).panelColor == nil)
        }
    }

    @Test func aPickedColorIsKeptAsItsCode() throws {
        try withDefaults { defaults in
            ShelfSettings(defaults: defaults).panelColor = PanelColor(hex: "#bf5af2")
            #expect(defaults.string(forKey: ShelfSettings.panelColorKey) == "#BF5AF2")
            #expect(ShelfSettings(defaults: defaults).panelColor == PanelColor(hex: "#BF5AF2"))
        }
    }

    @Test func blackAndUnreadableValuesMeanTheUsualPanel() {
        #expect(ShelfSettings.panelColor(stored: "#000000") == nil)
        #expect(ShelfSettings.panelColor(stored: "#000") == nil)
        #expect(ShelfSettings.panelColor(stored: "purple") == nil)
        #expect(ShelfSettings.storedValue(for: .black) == "")
        #expect(ShelfSettings.storedValue(for: nil) == "")
    }

    // MARK: - The picker's terms

    @Test func huesGoAroundTheWheelFromRed() {
        #expect(PanelColor(hue: 0, saturation: 1, brightness: 1).hex == "#FF0000")
        #expect(PanelColor(hue: 1.0 / 3, saturation: 1, brightness: 1).hex == "#00FF00")
        #expect(PanelColor(hue: 2.0 / 3, saturation: 1, brightness: 1).hex == "#0000FF")
        #expect(PanelColor(hue: 1, saturation: 1, brightness: 1).hex == "#FF0000")
    }

    @Test func noSaturationIsGreyAndNoBrightnessIsBlack() {
        #expect(PanelColor(hue: 0.3, saturation: 0, brightness: 1).hex == "#FFFFFF")
        #expect(PanelColor(hue: 0.3, saturation: 0, brightness: 0.5).hex == "#808080")
        #expect(PanelColor(hue: 0.3, saturation: 1, brightness: 0) == .black)
    }

    @Test func aColorComesBackFromThePickersTerms() throws {
        for code in ["#2881DB", "#FCBA03", "#BF5AF2", "#32D74B", "#FF453A", "#808080"] {
            let color = try #require(PanelColor(hex: code))
            let hsb = color.hsb
            #expect(PanelColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness).hex == code)
        }
    }

    @Test func greysAndBlackHaveNoHue() {
        #expect(PanelColor(red: 0.5, green: 0.5, blue: 0.5).hsb == (0, 0, 0.5))
        #expect(PanelColor.black.hsb == (0, 0, 0))
    }

    // MARK: - The glass

    /// macOS's accent colors, plus the colors hardest on white text.
    private var colors: [PanelColor] {
        ["#0A84FF", "#BF5AF2", "#FF375F", "#FF453A", "#FF9F0A", "#FFD60A", "#32D74B", "#98989D",
         "#FFFFFF", "#FFFF00", "#00FF00", "#00FFFF", "#2881DB", "#102030"].compactMap { PanelColor(hex: $0) }
    }

    @Test func whiteNamesStayReadableOnEveryColor() {
        for color in colors {
            let gradient = color.gradient
            #expect(gradient.start.contrastWithWhite >= 9, "\(color.hex)")
            #expect(gradient.end.contrastWithWhite > gradient.start.contrastWithWhite, "\(color.hex)")
        }
    }

    @Test func thePanelIsNeverThePickedColorNorFlat() {
        for color in colors {
            let gradient = color.gradient
            #expect(gradient.start != color, "\(color.hex)")
            #expect(gradient.start != gradient.end, "\(color.hex)")
            #expect(gradient.start.luminance < color.luminance, "\(color.hex)")
        }
    }

    @Test func aColorThatIsDarkAlreadyIsDeepenedNoFurtherThanTheLeast() throws {
        let navy = try #require(PanelColor(hex: "#102030"))
        let start = navy.turningHue(by: PanelColor.hueTurn).deepened()
        let expected = navy.turningHue(by: PanelColor.hueTurn).scaled(by: PanelColor.deepening)

        #expect(abs(start.luminance - expected.luminance) < 0.0001)
    }

    @Test func theEndsTurnAroundTheColorWheelButGreyStaysGrey() throws {
        let red = PanelColor(red: 1, green: 0, blue: 0)
        // 14° toward yellow brings in some green; the other way, some blue.
        let warmer = red.turningHue(by: 14)
        let cooler = red.turningHue(by: -14)
        #expect(warmer.green > 0.2 && warmer.blue == 0)
        #expect(cooler.blue > 0.2 && cooler.green == 0)

        let grey = PanelColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(grey.turningHue(by: 14) == grey)
    }

    @Test func turningAllTheWayAroundComesBack() throws {
        let purple = try #require(PanelColor(hex: "#BF5AF2"))
        let back = purple.turningHue(by: 200).turningHue(by: 160)
        #expect(abs(back.red - purple.red) < 0.0001)
        #expect(abs(back.green - purple.green) < 0.0001)
        #expect(abs(back.blue - purple.blue) < 0.0001)
    }
}

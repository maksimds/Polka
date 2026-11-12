import AppKit
import Testing
@testable import Polka

/// A large site icon fills its rounded square only when it's a tile made for phone
/// home screens. A bare logo on a see-through background, or any favicon, goes on
/// dark glass with room around it, or on the light card when it's dark.
@MainActor
struct SiteIconStyleTests {
    private let side = 120

    /// A `side` square image: `background` filling it (nil for see-through), with
    /// corners cut round to `cornerRadius`, then a circle in `ink` touching the edges.
    private func image(ink: CGColor, background: CGColor? = nil, cornerRadius: CGFloat = 0) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        if let background {
            context.setFillColor(background)
            context.addPath(CGPath(roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                                   transform: nil))
            context.fillPath()
        }
        context.setFillColor(ink)
        context.fillEllipse(in: square)
        return try #require(context.makeImage())
    }

    private let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private let darkGrey = CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let green = CGColor(red: 0.58, green: 0.75, blue: 0.28, alpha: 1)

    @Test func anIconWithItsOwnBackgroundIsATile() throws {
        // Like GitHub's: a white circle on a dark square.
        #expect(ShelfItemImages.style(of: try image(ink: white, background: darkGrey), isLarge: true) == .tile)
    }

    @Test func aTileThatComesWithRoundedCornersIsStillATile() throws {
        let rounded = try image(ink: white, background: darkGrey, cornerRadius: CGFloat(side) * 0.22)
        #expect(ShelfItemImages.style(of: rounded, isLarge: true) == .tile)
    }

    @Test func aColorfulShapeOnNothingIsALogo() throws {
        // Like Shopify's bag: color on a see-through background, reaching the edges.
        #expect(ShelfItemImages.style(of: try image(ink: green), isLarge: true) == .logo)
        #expect(ShelfItemImages.style(of: try image(ink: white), isLarge: true) == .logo)
    }

    @Test func aDarkShapeOnNothingIsADarkLogo() throws {
        #expect(ShelfItemImages.style(of: try image(ink: black), isLarge: true) == .darkLogo)
    }

    @Test func aFaviconGoesOnGlassLikeALogo() throws {
        // Like LinkedIn's: a colored mark on a see-through background.
        #expect(ShelfItemImages.style(of: try image(ink: green), isLarge: false) == .logo)
    }

    @Test func aSolidFaviconNeverFillsTheSquare() throws {
        // Stretched to the tile's size, a favicon this small would blur.
        #expect(ShelfItemImages.style(of: try image(ink: white, background: darkGrey), isLarge: false) == .logo)
    }

    @Test func aDarkFaviconGoesOnTheLightCard() throws {
        #expect(ShelfItemImages.style(of: try image(ink: black), isLarge: false) == .darkLogo)
    }
}

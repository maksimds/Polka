import AppKit
import Testing
@testable import Polka

/// A tile counts only the visible part of its picture for hover and presses, so the
/// see-through room around a folder or a document icon doesn't count.
@MainActor
struct VisibleBoundsTests {
    private let side = 64

    /// A `side` square image, see-through except `drawn` (in points from the bottom
    /// left, as Core Graphics draws).
    private func image(drawn: CGRect?) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let drawn {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(drawn)
        }
        return try #require(context.makeImage())
    }

    @Test func aDrawingInTheTopLeftIsFoundThereMeasuredFromTheTop() throws {
        // The top-left quarter: from the bottom left, that's the upper half's left side.
        let bounds = ShelfItemImages.visibleBounds(of: try image(drawn: CGRect(x: 0, y: 32, width: 32, height: 32)))
        #expect(bounds == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    @Test func roomAroundADrawingIsLeftOut() throws {
        // Like a folder icon: see-through room above it and at the sides.
        let bounds = ShelfItemImages.visibleBounds(of: try image(drawn: CGRect(x: 8, y: 0, width: 48, height: 48)))
        #expect(bounds == CGRect(x: 0.125, y: 0.25, width: 0.75, height: 0.75))
    }

    @Test func aPictureWithNoRoomIsAllVisible() throws {
        let bounds = ShelfItemImages.visibleBounds(of: try image(drawn: CGRect(x: 0, y: 0, width: 64, height: 64)))
        #expect(bounds == ShelfItemImages.wholeImage)
    }

    @Test func anEmptyPictureCountsAsAllOfIt() throws {
        #expect(ShelfItemImages.visibleBounds(of: try image(drawn: nil)) == ShelfItemImages.wholeImage)
    }
}

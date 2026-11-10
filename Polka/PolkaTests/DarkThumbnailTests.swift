import AppKit
import Testing
@testable import Polka

/// Dark drawings on a transparent background get a white page, so they show on the
/// black shelf. Everything else keeps its plain thumbnail.
@MainActor
struct DarkThumbnailTests {
    /// A 64 × 64 image: `fill` behind (nil for see-through), then a circle in `ink`.
    private func image(ink: CGColor, fill: CGColor? = nil) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        context.setFillColor(ink)
        context.fillEllipse(in: CGRect(x: 12, y: 12, width: 40, height: 40))
        return try #require(context.makeImage())
    }

    private let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private let navy = CGColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1)
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let orange = CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)

    @Test func aBlackOrDarkShapeOnTransparencyGetsAPage() throws {
        #expect(ShelfItemImages.needsLightBackground(try image(ink: black)))
        #expect(ShelfItemImages.needsLightBackground(try image(ink: navy)))
    }

    @Test func lightOrColorfulShapesOnTransparencyStayAsTheyAre() throws {
        #expect(!ShelfItemImages.needsLightBackground(try image(ink: white)))
        #expect(!ShelfItemImages.needsLightBackground(try image(ink: orange)))
    }

    @Test func anOpaqueDarkImageLikeANightPhotoStaysAsItIs() throws {
        #expect(!ShelfItemImages.needsLightBackground(try image(ink: black, fill: navy)))
    }

    @Test func aBlackSVGComesBackOnALightPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = folder.appendingPathComponent("mark.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
            <circle cx="50" cy="50" r="30" fill="#000"/></svg>
            """.utf8).write(to: svg)
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: svg)])

        let thumbnail = try #require(await ShelfItemImages().loadThumbnail(for: store.items[0], side: 52))

        let cgImage = try #require(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(!ShelfItemImages.needsLightBackground(cgImage))
    }
}

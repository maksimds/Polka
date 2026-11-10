import CoreGraphics
import Testing
@testable import Polka

struct NotchGeometryTests {
    // A MacBook screen with an external display above it, as macOS lays them out:
    // the external one starts where the built-in one ends.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let above = CGRect(x: -524, y: 982, width: 2560, height: 1440)
    private let rightOf = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    @Test func thePointerOnTheNotchStaysOnTheBuiltInScreen() {
        let onNotch = CGPoint(x: 756, y: 982)

        #expect(NotchGeometry.frameIndex(containing: onNotch, in: [builtIn, above]) == 0)
        #expect(NotchGeometry.frameIndex(containing: onNotch, in: [above, builtIn]) == 1)
    }

    @Test func movingUpPastTheNotchReachesTheScreenAbove() {
        let justAbove = CGPoint(x: 756, y: 983)

        #expect(NotchGeometry.frameIndex(containing: justAbove, in: [builtIn, above]) == 1)
    }

    @Test func theSharedSideEdgeBelongsToTheScreenOnTheRight() {
        let onEdge = CGPoint(x: 1512, y: 500)

        #expect(NotchGeometry.frameIndex(containing: onEdge, in: [builtIn, rightOf]) == 1)
        #expect(NotchGeometry.frameIndex(containing: CGPoint(x: 1511, y: 500), in: [builtIn, rightOf]) == 0)
    }

    @Test func aPointOffEveryScreenHasNoScreen() {
        #expect(NotchGeometry.frameIndex(containing: CGPoint(x: -2000, y: 0), in: [builtIn, rightOf]) == nil)
    }
}

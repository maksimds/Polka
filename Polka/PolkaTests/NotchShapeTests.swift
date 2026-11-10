import SwiftUI
import Testing
@testable import Polka

struct NotchShapeTests {
    private let body = CGRect(x: 40, y: 0, width: 520, height: 270)

    @Test func theTopCurvesReachOutsideTheBodyByTheirRadius() {
        let bounds = NotchShape(topRadius: 14, bottomRadius: 24).path(in: body).boundingRect

        #expect(bounds.minX == body.minX - 14)
        #expect(bounds.maxX == body.maxX + 14)
        #expect(bounds.minY == body.minY)
        #expect(bounds.maxY == body.maxY)
    }

    @Test func withoutTopCurvesTheShapeIsExactlyTheBody() {
        let bounds = NotchShape(topRadius: 0, bottomRadius: 10).path(in: body).boundingRect

        #expect(bounds == body)
    }

    @Test func oversizedRadiiAreKeptInsideASmallShape() {
        let pill = CGRect(x: 0, y: 0, width: 160, height: 24)
        let bounds = NotchShape(topRadius: 100, bottomRadius: 100).path(in: pill).boundingRect

        // The top curves are capped at half the height, and the bottom never crosses them.
        #expect(bounds.minX == -12)
        #expect(bounds.maxX == 172)
        #expect(bounds.maxY == pill.maxY)
    }
}

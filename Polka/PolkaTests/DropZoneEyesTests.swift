import Foundation
import Testing
@testable import Polka

struct DropZoneEyesTests {
    // MARK: - Blinking

    @Test func theEyesStayOpenUntilTheFirstBlink() {
        #expect(EyeBlink.openness(at: 0) == 1)
        #expect(EyeBlink.openness(at: 0.5) == 1)
        #expect(EyeBlink.openness(at: 0.99) == 1)
    }

    @Test func aBlinkClosesTheEyesAndOpensThemAgain() {
        let start = EyeBlink.first
        let shut = start + EyeBlink.closing + EyeBlink.shut / 2
        let reopened = start + EyeBlink.closing + EyeBlink.shut + EyeBlink.opening + 0.01

        #expect(EyeBlink.openness(at: start + EyeBlink.closing / 2) < 1)
        #expect(EyeBlink.openness(at: shut) == 0)
        #expect(EyeBlink.openness(at: reopened) == 1)
    }

    @Test func theEyesBlinkEveryTwoSeconds() {
        let shut = EyeBlink.first + EyeBlink.closing + EyeBlink.shut / 2

        #expect(EyeBlink.openness(at: shut + 1) == 1)
        #expect(EyeBlink.openness(at: shut + 2) == 0)
        #expect(EyeBlink.openness(at: shut + 4) == 0)
        #expect(EyeBlink.openness(at: shut + 5) == 1)
    }

    @Test func aBlinkIsQuick() {
        #expect(EyeBlink.closing + EyeBlink.shut + EyeBlink.opening <= 0.25)
    }

    // MARK: - Following the pointer

    @Test func thePointerRightOnTheEyesLeavesThemLookingAhead() {
        let eyes = CGPoint(x: 260, y: 53)

        #expect(EyeGaze(from: eyes, to: eyes) == .ahead)
    }

    @Test func theEyesLookTowardThePointer() {
        let eyes = CGPoint(x: 260, y: 53)

        let right = EyeGaze(from: eyes, to: CGPoint(x: 400, y: 53))
        let belowLeft = EyeGaze(from: eyes, to: CGPoint(x: 160, y: 153))

        #expect(right.x > 0)
        #expect(right.y == 0)
        #expect(belowLeft.x < 0)
        #expect(belowLeft.y > 0)
        #expect(abs(belowLeft.x - belowLeft.y * -1) < 0.0001)
    }

    @Test func aFartherPointerTurnsTheEyesFurtherButNeverAllTheWay() {
        let eyes = CGPoint(x: 260, y: 53)

        let near = EyeGaze(from: eyes, to: CGPoint(x: 310, y: 53))
        let halfway = EyeGaze(from: eyes, to: CGPoint(x: 410, y: 53))
        let far = EyeGaze(from: eyes, to: CGPoint(x: 5000, y: 53))

        #expect(near.x < halfway.x)
        #expect(abs(halfway.x - 0.5) < 0.0001)
        #expect(halfway.x < far.x)
        #expect(far.x < 1)
    }
}

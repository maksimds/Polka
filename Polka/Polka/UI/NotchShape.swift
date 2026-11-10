import SwiftUI

/// The panel's outline: a body hanging from the top edge of the screen with rounded
/// bottom corners, and top corners that curve outward into the screen edge, the way
/// the MacBook's own notch meets the menu bar.
///
/// Those outward curves (the "ears") are drawn outside `rect`, so the body keeps
/// exactly the size it's given and only the top edge is wider. Both radii animate,
/// so the shape can morph smoothly between the closed notch and the open panel.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Kept small enough that the curves never cross on a short or narrow shape.
        let top = max(0, min(topRadius, rect.height / 2))
        let bottom = max(0, min(bottomRadius, rect.width / 2, rect.height - top))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        // Left ear, curving down from the screen edge into the body's side.
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        // Right ear.
        path.addQuadCurve(to: CGPoint(x: rect.maxX + top, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

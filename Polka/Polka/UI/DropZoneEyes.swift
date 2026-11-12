import SwiftUI

/// A pair of eyes under the notch while the drop zone is open. They watch the pointer
/// and blink every couple of seconds.
///
/// Drawn after a face on a ball: two solid, rounded eyes with no pupils, so looking
/// somewhere means the whole face turning. The pair slides toward the pointer, the eye
/// on that side shrinks a little as it turns away, and a diagonal look tilts the head.
/// White on the black panel.
struct DropZoneEyes: View {
    /// The pointer in the panel's SwiftUI space (`.global`, from the top left), or nil
    /// if it's unknown. Read on every frame, since no mouse-moved events arrive during
    /// a drag.
    let pointer: @MainActor () -> CGPoint?
    /// True while a drag is over the panel: the eyes open a little wider.
    let isTargeted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Blinks are counted from when the eyes appear. Each opening of the drop zone
    /// builds them afresh.
    @State private var appeared = Date.now

    static let eyeSize = CGSize(width: 12.72, height: 43.2)
    /// From the middle of one eye to the middle of the other, looking straight ahead.
    static let spacing: CGFloat = 28
    /// How far the pair slides when looking all the way to one side.
    static let maxShift = CGSize(width: 6, height: 3)
    /// The head's tilt for a full diagonal look. In practice it stays under 18°.
    static let maxTilt: Double = 36

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let gaze = pointer().map { EyeGaze(from: CGPoint(x: frame.midX, y: frame.midY), to: $0) } ?? .ahead
                let openness = reduceMotion ? 1 : EyeBlink.openness(at: timeline.date.timeIntervalSince(appeared))
                pair(gaze: gaze, openness: openness)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .scaleEffect(isTargeted && !reduceMotion ? 1.1 : 1)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pair(gaze: EyeGaze, openness: CGFloat) -> some View {
        // Turned to one side, the eyes come closer together, as on a ball.
        let spacing = Self.spacing * (1 - 0.18 * abs(gaze.x))
        return ZStack {
            eye(onSide: -1, gaze: gaze, openness: openness)
                .offset(x: -spacing / 2)
            eye(onSide: 1, gaze: gaze, openness: openness)
                .offset(x: spacing / 2)
        }
        // Looking down and to the right leans the head's top to the right, and so on.
        .rotationEffect(.degrees(Self.maxTilt * gaze.x * gaze.y))
        .offset(x: gaze.x * Self.maxShift.width, y: gaze.y * Self.maxShift.height)
    }

    /// `side` is -1 for the left eye and 1 for the right.
    private func eye(onSide side: CGFloat, gaze: EyeGaze, openness: CGFloat) -> some View {
        // The eye on the side being looked toward is further around the ball.
        let depth = 1 - 0.14 * max(0, side * gaze.x)
        // A blink squashes the eye into a line and stretches it a little, cartoon style.
        let squash = 1 - openness
        return Capsule()
            .fill(Color.white)
            .frame(width: Self.eyeSize.width, height: Self.eyeSize.height)
            .scaleEffect(x: depth * (1 + 0.15 * squash),
                         y: depth * max(openness, 0.12))
    }
}

/// Which way the eyes look: toward the pointer, and further the further away it is.
struct EyeGaze: Equatable {
    /// From -1 (all the way left) to 1 (all the way right).
    var x: CGFloat
    /// From -1 (all the way up) to 1 (all the way down), as SwiftUI counts.
    var y: CGFloat

    static let ahead = EyeGaze(x: 0, y: 0)

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    /// A pointer `reach` points away turns the eyes halfway. They get close to all the
    /// way but never reach it, however far the pointer goes.
    init(from eyes: CGPoint, to pointer: CGPoint, reach: CGFloat = 150) {
        let dx = pointer.x - eyes.x
        let dy = pointer.y - eyes.y
        let distance = hypot(dx, dy)
        guard distance > 0.5 else {
            self = .ahead
            return
        }
        let turn = distance / (distance + reach)
        x = dx / distance * turn
        y = dy / distance * turn
    }
}

/// When the eyes blink: every `interval` seconds, the first one a second after they
/// appear, so even a short drag sees one.
enum EyeBlink {
    static let interval: TimeInterval = 2
    static let first: TimeInterval = 1
    /// A quick close, a moment shut, and a slightly slower open.
    static let closing: TimeInterval = 0.07
    static let shut: TimeInterval = 0.03
    static let opening: TimeInterval = 0.1

    /// 1 while the eyes are open, 0 while they're shut.
    static func openness(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed >= first else { return 1 }
        let time = (elapsed - first).truncatingRemainder(dividingBy: interval)
        if time < closing {
            return 1 - ease(time / closing)
        }
        if time < closing + shut {
            return 0
        }
        if time < closing + shut + opening {
            return ease((time - closing - shut) / opening)
        }
        return 1
    }

    /// Starts and ends gently.
    private static func ease(_ progress: Double) -> CGFloat {
        CGFloat(progress * progress * (3 - 2 * progress))
    }
}

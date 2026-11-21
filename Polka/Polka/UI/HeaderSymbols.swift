import AppKit
import SwiftUI

// The header's three buttons and how they move: the + turns into an × while its menu
// is open, the sort arrows part and come back on a press, and the gear spins and
// swells. Each moves inside its glass (`GlassHeaderGlyph`), so the light stays on top.
// With Reduce Motion nothing moves: the + fades into the ×, and the other two only
// brighten for a moment.

/// What a press animates, frame by frame.
struct HeaderPress {
    /// How far each sort arrow moves away from the middle, up or down.
    var spread: CGFloat = 0
    /// The gear's turn, in degrees.
    var angle: Double = 0
    var scale: Double = 1
    /// The brief glow that stands in for movement under Reduce Motion.
    var flash: Double = 0
}

// MARK: - +

/// A + that turns 45° into an × while the menu is open, and back when it closes.
///
/// A keyframe animation, not `.animation(_:value:)`: the menu opens right after the
/// change, and while AppKit tracks it the panel didn't draw an implicit animation at
/// all, so the + stayed a + until the menu closed. Keyframes are drawn frame by frame
/// throughout (checked by capturing a harness window while its menu was open).
struct PlusCrossGlyph: View {
    let isCross: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 0 is the +, 1 the ×. Every run starts from `initialValue`, not from where the
        // last one ended, so each begins with a jump to the other end: without it, the
        // way back started at the + already and the × snapped back.
        KeyframeAnimator(initialValue: 0.0, trigger: isCross) { progress in
            Group {
                if reduceMotion {
                    ZStack {
                        Image(systemName: "plus").opacity(1 - progress)
                        Image(systemName: "xmark").opacity(progress)
                    }
                } else {
                    Image(systemName: "plus")
                        .rotationEffect(.degrees(45 * progress))
                }
            }
            .font(GlassHeaderSymbol.font)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                MoveKeyframe(isCross ? 0 : 1)
                SpringKeyframe(isCross ? 1 : 0,
                               duration: reduceMotion ? 0.2 : 0.35,
                               spring: .init(duration: reduceMotion ? 0.2 : 0.35, bounce: reduceMotion ? 0 : 0.2))
            }
        }
    }
}

// MARK: - Sort

/// The sort symbol, whose arrows part on each press: the up arrow rises, the down
/// arrow drops, and both spring back.
struct SortArrowsSymbol: View {
    /// Counts presses; each new value plays the animation once.
    let presses: Int
    var tint: Color?
    let height: CGFloat
    let isGlowing: Bool

    /// How far each arrow travels.
    static let spread: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KeyframeAnimator(initialValue: HeaderPress(), trigger: presses) { press in
            GlassHeaderGlyph(tint: tint, height: height, isGlowing: isGlowing, flash: press.flash) {
                SplitArrows(spread: press.spread)
            }
        } keyframes: { _ in
            KeyframeTrack(\.spread) {
                MoveKeyframe(0)
                CubicKeyframe(reduceMotion ? 0 : Self.spread, duration: 0.16, startVelocity: 0, endVelocity: 0)
                SpringKeyframe(0, duration: 0.4, spring: .init(duration: 0.4, bounce: 0.25))
            }
            KeyframeTrack(\.flash) { Self.flash(if: reduceMotion) }
        }
    }

    /// A glow that comes and goes in about a third of a second, or nothing.
    @KeyframeTrackContentBuilder<Double>
    static func flash(if wanted: Bool) -> some KeyframeTrackContent<Double> {
        MoveKeyframe(0)
        LinearKeyframe(wanted ? 1 : 0, duration: 0.1)
        LinearKeyframe(0, duration: 0.25)
    }
}

/// `arrow.up.arrow.down` cut down the middle, so each arrow can move on its own
/// while together they're exactly the symbol as it always was.
private struct SplitArrows: View {
    let spread: CGFloat

    var body: some View {
        let symbol = Image(systemName: "arrow.up.arrow.down").font(GlassHeaderSymbol.font)
        ZStack {
            symbol
                .mask { half(leading: true) }
                .offset(y: -spread)
            symbol
                .mask { half(leading: false) }
                .offset(y: spread)
        }
    }

    private func half(leading: Bool) -> some View {
        HStack(spacing: 0) {
            Color.black.opacity(leading ? 1 : 0)
            Color.black.opacity(leading ? 0 : 1)
        }
    }
}

// MARK: - Gear

/// The Settings gear, which spins once and swells a little on each press, shrinking
/// back as the turn ends.
struct GearSymbol: View {
    let presses: Int
    let height: CGFloat
    let isGlowing: Bool

    static let swell = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KeyframeAnimator(initialValue: HeaderPress(), trigger: presses) { press in
            GlassHeaderGlyph(height: height, isGlowing: isGlowing, flash: press.flash) {
                Image(systemName: "gearshape.fill")
                    .font(GlassHeaderSymbol.font)
                    .rotationEffect(.degrees(press.angle))
                    .scaleEffect(press.scale)
            }
        } keyframes: { _ in
            // A full turn, slow at both ends. It starts again from 0, which looks the
            // same as the 360 the last press ended on.
            KeyframeTrack(\.angle) {
                MoveKeyframe(0)
                CubicKeyframe(reduceMotion ? 0 : 360, duration: 0.6, startVelocity: 0, endVelocity: 0)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(1)
                CubicKeyframe(reduceMotion ? 1 : Self.swell, duration: 0.25, startVelocity: 0, endVelocity: 0)
                SpringKeyframe(1, duration: 0.35, spring: .init(duration: 0.35, bounce: 0.2))
            }
            KeyframeTrack(\.flash) { SortArrowsSymbol.flash(if: reduceMotion) }
        }
    }
}

// MARK: - Hover

/// Tells a header button when the pointer is over it, through an AppKit tracking
/// area. SwiftUI's own hover only follows the pointer while the app is active, and
/// Polka almost never is. It takes no clicks (`hitTest` is nil), so they reach the
/// button underneath.
///
/// The shelf's views stay in place while the panel is closed, so the hover is only
/// reported while `isActive` (the shelf is open), and checked afresh when it opens.
struct HeaderHoverArea: NSViewRepresentable {
    let isActive: Bool
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> HeaderHoverView {
        HeaderHoverView()
    }

    func updateNSView(_ view: HeaderHoverView, context: Context) {
        view.onChange = onChange
        view.isActive = isActive
    }
}

final class HeaderHoverView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            // Opened or closed: where's the pointer now? Tracking areas only report
            // crossing an edge, and the pointer may have crossed none.
            report(isActive && isPointerInside)
        }
    }
    private var isHovered = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        report(isActive)
    }

    override func mouseExited(with event: NSEvent) {
        report(false)
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func report(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        // A tick later: this can run while SwiftUI is updating the view.
        DispatchQueue.main.async { [onChange] in onChange?(hovered) }
    }
}

import AppKit
import SwiftUI

/// What the panel is drawn on. Solid black by default, the color of the notch it grows
/// out of. With Settings' Transparency turned up, the open panel (shelf, drop zone and
/// link field) is glass that lets what's behind it show through, blurred, like
/// Finder's sidebar: black lies over the glass, as thin as the setting asks.
///
/// With a color picked in Settings, the color's gradient (`PanelColor.gradient`, a
/// diagonal two-tone deepened so white names stay readable) takes the black's place,
/// with a soft sheen across the top. It's never the picked color itself. Transparency
/// thins it too, but never below `leastTint`, so the color still shows at 100%.
///
/// The closed notch stays solid black either way, and the black gives way to the
/// open panel's background with the shape's own spring as it opens and closes.
struct PanelBackground: View {
    let shape: NotchShape
    /// How see-through the open panel is, from 0 (solid) to 1 (the glass alone, or
    /// lightly tinted with the color). Zero under Reduce Transparency.
    let transparency: Double
    /// The color picked in Settings. Nil is black.
    let color: PanelColor?
    /// The panel is notch-sized: closed, or shrunk for a drag out. Solid then.
    let isClosed: Bool
    /// The shelf is showing. Its shadow waits for the opening to settle.
    let isOpen: Bool

    /// The light along the glass's edge. The top edge is the screen's own, so unlike
    /// Polka's other glass there's no light there: faint down the sides, a little
    /// reflection along the bottom.
    private static let rim = LinearGradient(stops: [
        .init(color: .white.opacity(0), location: 0),
        .init(color: .white.opacity(0.1), location: 0.35),
        .init(color: .white.opacity(0.06), location: 0.75),
        .init(color: .white.opacity(0.22), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// Light falling on the top of the colored glass, gone by the middle. Settings'
    /// preview of the shelf has it too.
    static let sheen = LinearGradient(stops: [
        .init(color: .white.opacity(0.09), location: 0),
        .init(color: .white.opacity(0.02), location: 0.35),
        .init(color: .clear, location: 0.55),
    ], startPoint: .top, endPoint: .bottom)

    /// How much of the color's gradient stays at 100% transparency.
    static let leastTint = 0.3

    private var blackOpacity: Double {
        if isClosed { return 1 }
        return color == nil ? 1 - transparency : 0
    }

    private var tintOpacity: Double {
        isClosed ? 0 : 1 - (1 - Self.leastTint) * transparency
    }

    /// Colored glass always has its rim; black only as far as it's see-through.
    private var rimOpacity: Double {
        if isClosed { return 0 }
        return color == nil ? transparency : 1
    }

    var body: some View {
        ZStack {
            shadow
            if transparency > 0 {
                PanelGlass()
                    // As wide as the ears, which reach past the body's sides.
                    .padding(.horizontal, -NotchShape.openTopRadius)
                    .clipShape(shape)
            }
            if let color {
                ZStack {
                    shape.fill(color.gradient.linear)
                    shape.fill(Self.sheen)
                }
                .opacity(tintOpacity)
            }
            shape.fill(Color.black.opacity(blackOpacity))
            if transparency > 0 || color != nil {
                // Centered on the outline, so half of it, Glass.rimWidth, is inside.
                shape.stroke(Self.rim, lineWidth: Glass.rimWidth * 2)
                    .clipShape(shape)
                    .opacity(rimOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Lifts the open panel off whatever is behind it. Pushed down so it falls below
    /// the panel rather than on the menu bar beside it, and none while closed, where it
    /// would ring the notch. It fades in as the opening settles, not while the shape
    /// grows. The shape is cut out of it, since under see-through glass it would show
    /// through as a dark smudge.
    private var shadow: some View {
        shape.fill(Color.black)
            .animation(isOpen ? .easeOut(duration: 0.2).delay(0.2) : .easeIn(duration: 0.1)) {
                $0.shadow(color: .black.opacity(isClosed ? 0 : 0.3), radius: 10, y: 9)
            }
            .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
            .compositingGroup()
    }
}

extension PanelGradient {
    /// From the top left to the bottom right, in the panel and in Settings' preview of it.
    var linear: LinearGradient {
        LinearGradient(colors: [Color(start), Color(end)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(_ color: PanelColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

/// AppKit's material view, the one behind Finder's sidebar, set to blur what's behind
/// the window (the desktop, other apps, the menu bar) rather than what's in it.
private struct PanelGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PanelGlassView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Left to follow the window, the glass turns flat grey whenever Polka isn't
        // the active app, which is nearly always.
        view.state = .active
        // Dark whatever the system's appearance: everything on the shelf is white and
        // would vanish on light glass.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Takes no presses, so clicks, hover and drops reach the shelf's own views.
private final class PanelGlassView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

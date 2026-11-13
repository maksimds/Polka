import SwiftUI

/// Polka's glass, after iOS 27's Liquid Glass: a see-through body, a little lighter
/// at the top, and a sharp line of light along its edges, brightest where light
/// falls on the top, fading down the sides, with a faint reflection along the
/// bottom.
///
/// Apple's own glass (`glassEffect`) needs macOS 26, so this is drawn by hand. These
/// pieces don't blur what's behind them: the panel is a transparent window, so a blur
/// would show the desktop there, not the panel. The panel's own background can be
/// see-through glass instead (`PanelBackground`, Settings' Transparency), which
/// blurs what's behind the whole window. With Reduce Transparency on, every piece
/// turns solid, as iOS does.
enum Glass {
    /// Between two symbols in the panel's header: +, Sort, Settings.
    static let headerSymbolSpacing: CGFloat = 16
    /// How far past a header symbol a click still counts. Half the spacing, so
    /// neighbors' areas meet without overlapping.
    static let headerClickMargin: CGFloat = 8
    /// How thick the light along an edge is. Thin and sharp, as in iOS 27.
    static let rimWidth: CGFloat = 0.75

    /// The light along a dark glass edge, from top to bottom.
    static let rim = LinearGradient(stops: [
        .init(color: .white.opacity(0.55), location: 0),
        .init(color: .white.opacity(0.14), location: 0.4),
        .init(color: .white.opacity(0.05), location: 0.7),
        .init(color: .white.opacity(0.2), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// The light along a picture's edge, a little stronger than a button's, since a
    /// picture has its own colors to stand out from.
    static let pictureRim = LinearGradient(stops: [
        .init(color: .white.opacity(0.7), location: 0),
        .init(color: .white.opacity(0.18), location: 0.4),
        .init(color: .white.opacity(0.06), location: 0.7),
        .init(color: .white.opacity(0.3), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// The edge of light glass: bright along the top, and a touch of shade along
    /// the bottom, since a light edge doesn't show against a light body.
    static let lightRim = LinearGradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white.opacity(0.35), location: 0.45),
        .init(color: .black.opacity(0.12), location: 1),
    ], startPoint: .top, endPoint: .bottom)
}

/// Dark see-through glass filling `shape`, such as the message's close button, or
/// colored glass with a tint, such as the link field's Add button once it can add.
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color?
    /// How much lighter the top is than the bottom, from 0 (flat) to 1, around the
    /// same middle.
    var gradient: Double
    /// How bright the light along the edge is, from 0 (none) to 1.
    var rimLight: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ shape: S, tint: Color? = nil, gradient: Double = 1, rimLight: Double = 1) {
        self.shape = shape
        self.tint = tint
        self.gradient = gradient
        self.rimLight = rimLight
    }

    var body: some View {
        ZStack {
            if let tint {
                // Mostly the color, so a button keeps it, with glass's light on top.
                shape.fill(tint.opacity(reduceTransparency ? 1 : 0.85))
            }
            if reduceTransparency {
                if tint == nil {
                    shape.fill(Color(white: 0.3))
                }
            } else {
                shape.fill(fill)
                shape.strokeBorder(Glass.rim, lineWidth: Glass.rimWidth)
                    .opacity(rimLight)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// From 0.17 white at the top to 0.06 at the bottom at full gradient. Less
    /// narrows the spread but keeps the middle, so the glass is flatter, not darker.
    private var fill: LinearGradient {
        let middle = 0.115
        let spread = 0.055 * gradient
        return LinearGradient(colors: [.white.opacity(middle + spread), .white.opacity(middle - spread)],
                              startPoint: .top, endPoint: .bottom)
    }
}

/// A symbol in the panel's header (+, Sort, Settings, the link field's ×), made of
/// glass itself, centered on the header's height, which is the notch's. Its frame
/// is just the symbol.
struct GlassHeaderSymbol: View {
    let systemName: String
    /// Colors the glass, as the sort symbol is while a sort is on.
    var tint: Color?
    /// The header's height.
    let height: CGFloat

    /// A little softer than full gloss, so the symbols don't outshine the shelf.
    static let gloss = 0.85

    var body: some View {
        GlassGlyph(gloss: Self.gloss, tint: tint) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(height: height)
    }
}

/// The pin on a pinned tile's picture (FR-21), made of the same glass as the header's
/// symbols, a little smaller, with a slight red tint so it stands out from the white
/// symbols and pictures around it. See-through glass would vanish over a light
/// picture, such as a white page, so a soft dark halo sits behind it; over the dark
/// shelf the halo doesn't show.
struct GlassPinBadge: View {
    /// #FF6B5E: a warm red. Paler, with more white in it, it read as pink.
    static let tint = Color(.sRGB, red: 1, green: 0x6B / 255, blue: 0x5E / 255)

    var body: some View {
        GlassGlyph(gloss: GlassHeaderSymbol.gloss, tint: Self.tint) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.55), radius: 1.5)
        .accessibilityLabel("Pinned")
    }
}

/// The × that removes a tile from the shelf, after the badge iOS 27 puts on an app's
/// corner when you delete it: light grey glass with a dark mark, lifted by a soft
/// shadow. iOS has a minus there; Polka keeps the ×.
struct GlassRemoveBadge: View {
    static let side: CGFloat = 20

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(Color(white: 0.12))
            .frame(width: Self.side, height: Self.side)
            .background {
                ZStack {
                    if reduceTransparency {
                        Circle().fill(Color(white: 0.85))
                    } else {
                        Circle().fill(LinearGradient(colors: [Color(white: 0.94).opacity(0.94),
                                                              Color(white: 0.8).opacity(0.94)],
                                                     startPoint: .top, endPoint: .bottom))
                        Circle().strokeBorder(Glass.lightRim, lineWidth: Glass.rimWidth)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .accessibilityHidden(true)
            }
    }
}

/// The small round × that closes the message, in dark glass.
struct GlassCloseMark: View {
    static let side: CGFloat = 18

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.side, height: Self.side)
            .background(GlassSurface(Circle()))
    }
}

/// Lettering or a symbol made of glass, like the clock on the iOS Lock Screen: a
/// see-through body, light along the top edge of every stroke, and a faint
/// reflection along the bottom.
///
/// The glyph is drawn several times, so a symbol effect such as a bounce goes on the
/// glyph itself; every copy then moves together.
struct GlassGlyph<Glyph: View>: View {
    /// How glossy, from 0 (flat) to 1: how much lighter the top is than the bottom,
    /// and how bright the light along the edges is.
    var gloss: Double = 1
    /// Colors the glass instead of white.
    var tint: Color?
    /// Brighter, as the drop zone's tray is while a drag is over it.
    var isLit = false
    @ViewBuilder let glyph: Glyph

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            glyph.foregroundStyle(tint ?? .white.opacity(isLit ? 1 : 0.85))
        } else {
            glyph
                .foregroundStyle(fill)
                .overlay { edge(shiftedBy: Glass.rimWidth, light: (isLit ? 1 : 0.95) * gloss) }
                .overlay { edge(shiftedBy: -Glass.rimWidth * 0.8, light: 0.35 * gloss) }
        }
    }

    /// Lighter at the top than at the bottom, by as much as the gloss asks. A tint is
    /// stronger than white, so it keeps its color.
    private var fill: LinearGradient {
        let middle = (isLit ? 0.76 : 0.54) + (tint == nil ? 0 : 0.3)
        let spread = 0.14 * gloss
        let color = tint ?? .white
        return LinearGradient(colors: [color.opacity(min(middle + spread, 1)),
                                       color.opacity(min(middle - spread, 1))],
                              startPoint: .top, endPoint: .bottom)
    }

    /// The edges of every stroke that face up (a positive shift) or down: what's left
    /// of the glyph once a copy moved that far is cut out of it.
    private func edge(shiftedBy shift: CGFloat, light: Double) -> some View {
        Color.white.opacity(light)
            .mask {
                glyph
                    .overlay {
                        glyph
                            .offset(y: shift)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The title at the left of the panel's header strip, "Polka" or the link field's
/// "Add Link", in glass lettering, glossy enough to read as glass and no more.
/// 15 pt bold, since the light along the edges is too thin to see on smaller,
/// lighter letters. Never squeezed by its frame.
struct GlassTitle: View {
    let text: String

    var body: some View {
        GlassGlyph(gloss: 0.5) {
            Text(text)
                .font(.system(size: 15, weight: .bold))
        }
        .fixedSize()
    }
}

/// Glass built into a picture, the way iOS 27 makes app icons: a soft sheen across
/// the top and light along the edge. Goes over a site's icon already clipped to
/// `shape`. Nothing here is see-through, so it stays with Reduce Transparency.
struct GlassPictureFinish<S: InsettableShape>: View {
    let shape: S
    /// How strong the sheen across the top is, from 0 (none) to 1.
    var sheen: Double = 1
    /// How bright the light along the edge is, from 0 (none) to 1.
    var rimLight: Double = 1

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.22), location: 0),
                .init(color: .white.opacity(0.06), location: 0.35),
                .init(color: .clear, location: 0.5),
            ], startPoint: .top, endPoint: .bottom))
                .opacity(sheen)
            shape.strokeBorder(Glass.pictureRim, lineWidth: 1)
                .opacity(rimLight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Light frosted glass, the card behind a small site icon. Dark glass would hide a
/// dark icon such as GitHub's, so this one is light, with the same sheen and edge.
struct LightGlassCard<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.86)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(GlassPictureFinish(shape: shape))
    }
}

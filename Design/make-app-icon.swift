// Draws Polka's app icon: the menu bar's tray.full symbol as white glass on a dark macOS tile,
// and writes every size into the app's AppIcon set.
//
// Run from the repo root (it's a script, not part of the app target):
//   swiftc -O Design/make-app-icon.swift -o /tmp/make-app-icon && /tmp/make-app-icon
// An optional argument writes the PNGs to another folder instead, for trying out changes.
//
// The symbol comes from the SF Symbols installed with macOS, so a newer macOS may draw it
// slightly differently. Apple's SF Symbols license doesn't allow symbols in app icons, which
// is fine for a private personal app but would need an original drawing before shipping Polka.

import AppKit
import SwiftUI
import simd

// MARK: - Settings, in points on Apple's 1024 pt macOS icon grid

let canvas = 2048                        // drawn at 2x, then halved down to each size
let k = CGFloat(canvas) / 1024           // pixels per grid point
let symbolName = "tray.full"
let symbolWeight = NSFont.Weight.semibold
let symbolWidth: CGFloat = 500           // width of the tray on the 824 pt tile
let symbolLift: CGFloat = 10             // raised a little so it sits centered with its shadow

let bevelSoftness: Float = 13            // how far in from the edge the glass rounds over
let bevelTilt: Float = 3.2               // how steeply the edge turns away
let keyLight = simd_normalize(SIMD3<Float>(-0.35, 0.8, 0.55))
let gloss: Float = 0.5                   // 1 is polished, 0 is matte
let glassBody: Float = 0.92              // the glass's own color: milky white
let tileTop: CGFloat = 0.16              // the dark tile's grey at the top and bottom
let tileBottom: CGFloat = 0.07
let tileReflection: Float = 0.10         // how bright the tile looks reflected in the glass's lower edges
let shadowStrength: Float = 1.6          // the symbol's shadow, stronger than on white so it shows on the dark tile

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Polka/Polka/Assets.xcassets/AppIcon.appiconset"

// MARK: - Helpers

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Three box blurs in a row, close to a Gaussian with sigma ≈ radius.
func blur(_ src: [Float], _ w: Int, _ radius: Int) -> [Float] {
    var a = src
    var b = [Float](repeating: 0, count: src.count)
    let h = src.count / w
    let inv = 1 / Float(2 * radius + 1)
    for _ in 0..<3 {
        for y in 0..<h {                                  // horizontal
            let row = y * w
            var acc: Float = 0
            for i in 0...radius { acc += a[row + min(i, w - 1)] }
            for x in 0..<w {
                b[row + x] = acc * inv
                if x + radius + 1 < w { acc += a[row + x + radius + 1] }
                if x - radius >= 0 { acc -= a[row + x - radius] }
            }
        }
        for x in 0..<w {                                  // vertical
            var acc: Float = 0
            for i in 0...radius { acc += b[min(i, h - 1) * w + x] }
            for y in 0..<h {
                a[y * w + x] = acc * inv
                if y + radius + 1 < h { acc += b[(y + radius + 1) * w + x] }
                if y - radius >= 0 { acc -= b[(y - radius) * w + x] }
            }
        }
    }
    return a
}

/// A premultiplied RGBA image from a grey level and a coverage per pixel.
func image(grey: [Float], alpha: [Float], w: Int) -> CGImage {
    let ctx = makeContext(w)
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * w * 4)
    for i in 0..<(w * w) {
        let a = min(max(alpha[i], 0), 1)
        let c = UInt8(min(max(grey[i], 0), 1) * a * 255 + 0.5)
        px[i * 4] = c; px[i * 4 + 1] = c; px[i * 4 + 2] = c
        px[i * 4 + 3] = UInt8(a * 255 + 0.5)
    }
    return ctx.makeImage()!
}

// MARK: - The symbol's shape

/// The symbol's coverage (0 to 1 per pixel, rows top to bottom), sized and centered on the canvas.
func symbolCoverage() -> [Float] {
    func render(pointSize: CGFloat) -> [Float] {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: symbolWeight)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        let ctx = makeContext(canvas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = symbol.size
        symbol.draw(in: NSRect(x: (CGFloat(canvas) - s.width) / 2, y: (CGFloat(canvas) - s.height) / 2,
                               width: s.width, height: s.height))
        NSGraphicsContext.restoreGraphicsState()
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: canvas * canvas * 4)
        return (0..<(canvas * canvas)).map { Float(px[$0 * 4 + 3]) / 255 }
    }
    func bounds(_ cov: [Float]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var b = (minX: canvas, maxX: 0, minY: canvas, maxY: 0)
        for y in 0..<canvas { for x in 0..<canvas where cov[y * canvas + x] > 0.5 {
            b.minX = min(b.minX, x); b.maxX = max(b.maxX, x); b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
        } }
        return b
    }
    // Render once to measure, then again at the size that gives the wanted width.
    let first = bounds(render(pointSize: 400))
    let pointSize = 400 * symbolWidth * k / CGFloat(first.maxX - first.minX + 1)
    let cov = render(pointSize: pointSize)
    let b = bounds(cov)
    let dx = canvas / 2 - (b.minX + b.maxX + 1) / 2
    let dy = canvas / 2 - (b.minY + b.maxY + 1) / 2 - Int(symbolLift * k)
    var moved = [Float](repeating: 0, count: cov.count)
    for y in 0..<canvas { for x in 0..<canvas {
        let sx = x - dx, sy = y - dy
        if sx >= 0, sx < canvas, sy >= 0, sy < canvas { moved[y * canvas + x] = cov[sy * canvas + sx] }
    } }
    print("tray: \(b.maxX - b.minX + 1) x \(b.maxY - b.minY + 1) px at \(canvas), point size \(Int(pointSize))")
    return moved
}

// MARK: - White glass

/// Shades the symbol as rounded white glass: a milky body, edges that reflect a bright
/// studio light above, the dark room around it and the dark tile below, and a sharp
/// highlight from the key light.
func glassShade(_ cov: [Float]) -> [Float] {
    let w = canvas
    let sigma = bevelSoftness * Float(k)
    let height = blur(cov, w, Int(sigma))
    let steep = bevelTilt * sigma * 2.5066           // undoes the blur's slope so bevelTilt is the edge's slope
    let view = SIMD3<Float>(0, 0, 1)
    let half = simd_normalize(keyLight + view)

    // The tray's top and bottom rows, for the sheen across its upper part.
    var top = w, bottom = 0
    for y in 0..<w { for x in stride(from: 0, to: w, by: 4) where cov[y * w + x] > 0.5 { top = min(top, y); bottom = max(bottom, y) } }

    var grey = [Float](repeating: 0, count: cov.count)
    for y in 1..<(w - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            if cov[i] <= 0 { continue }
            let gx = (height[i + 1] - height[i - 1]) * 0.5
            let gyUp = (height[i - w] - height[i + w]) * 0.5
            let n = simd_normalize(SIMD3<Float>(-gx * steep, -gyUp * steep, 1))
            let r = SIMD3<Float>(2 * n.z * n.x, 2 * n.z * n.y, 2 * n.z * n.z - 1)   // reflected view ray

            // What the glass reflects: a bright light strip above, a dimmer one on the left,
            // the dark tile below, and a dark room straight ahead. Hard edges on the lights
            // are what make it read as glass rather than plastic.
            // Less gloss dims the lights and softens their edges.
            let edge = 0.06 + 0.12 * (1 - gloss)
            let above = smoothstep(0.78, 0.78 + edge, r.y) * (1 - smoothstep(0.96, 0.99, r.y)) * 14 * gloss
            let left = smoothstep(-0.78, -0.78 - edge, r.x) * smoothstep(-0.2, 0.3, r.y) * 6 * gloss
            let tile = smoothstep(-0.40, -0.40 - edge, r.y) * tileReflection * (0.5 + 0.5 * gloss)
            let env = 0.03 + above + left + tile
            let fresnel = 0.04 + 0.96 * powf(1 - n.z, 5)             // glass: little head-on, a lot at grazing angles

            let body: Float = glassBody
            var c = body * (1 - fresnel) + fresnel * env
            let nh = max(simd_dot(n, half), 0)
            c += (powf(nh, 500) * 1.6 + powf(nh, 40) * 0.05) * gloss

            // A faint sheen over the upper part, like light across a polished face.
            let t = Float(y - top) / Float(max(bottom - top, 1))
            c += 0.05 * (1 - smoothstep(0.0, 0.6, t)) * n.z * gloss

            grey[i] = c
        }
    }
    return grey
}

// MARK: - The icon

func drawMaster() -> CGImage {
    let ctx = makeContext(canvas)
    let tileRect = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let tile = RoundedRectangle(cornerRadius: 185.4 * k, style: .continuous).path(in: tileRect).cgPath

    // The dark tile with the standard macOS icon shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(tile); ctx.setFillColor(CGColor(gray: tileBottom, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: tileTop, alpha: 1), CGColor(gray: tileBottom, alpha: 1)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])

    let cov = symbolCoverage()
    let zero = [Float](repeating: 0, count: cov.count)

    // Shadows on the tile: a wide soft one and a tight one where the glass meets it.
    let soft = blur(cov, canvas, Int(22 * k)).map { $0 * 0.30 * shadowStrength }
    ctx.draw(image(grey: zero, alpha: soft, w: canvas),
             in: CGRect(x: 0, y: -20 * k, width: CGFloat(canvas), height: CGFloat(canvas)))
    let tight = blur(cov, canvas, Int(4 * k)).map { $0 * 0.35 * shadowStrength }
    ctx.draw(image(grey: zero, alpha: tight, w: canvas),
             in: CGRect(x: 0, y: -5 * k, width: CGFloat(canvas), height: CGFloat(canvas)))

    ctx.draw(image(grey: glassShade(cov), alpha: cov, w: canvas),
             in: CGRect(x: 0, y: 0, width: CGFloat(canvas), height: CGFloat(canvas)))
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// Halves the image until it reaches `size`, so every step averages neighbouring pixels.
func scaled(_ src: CGImage, to size: Int) -> CGImage {
    var img = src
    while img.width > size {
        let next = max(img.width / 2, size)
        let ctx = makeContext(next)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: next, height: next))
        img = ctx.makeImage()!
    }
    return img
}

func writePNG(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// Each size the AppIcon set asks for, at 1x and 2x. The names match its Contents.json.
let master = drawMaster()
for points in [16, 32, 128, 256, 512] {
    writePNG(scaled(master, to: points), "icon_\(points)x\(points).png")
    writePNG(scaled(master, to: points * 2), "icon_\(points)x\(points)@2x.png")
}
print("wrote icons to \(outDir)")

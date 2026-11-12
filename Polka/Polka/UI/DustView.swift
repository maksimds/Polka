import MetalKit
import SwiftUI

/// Removed tiles turning to dust, after Telegram's delete animation: a picture of the
/// tile breaks into grains from left to right, which rise and fade (`DustEffect.metal`).
///
/// The shelf hands each removed tile's picture to `scatter(_:scale:at:within:)`, then
/// hides the tile. The dust's first frame looks exactly like the tile, so the swap
/// can't be seen.
@MainActor
final class DustField {
    /// True while the dust's view is in the panel and Metal can run it. Otherwise
    /// (in tests, or on a Mac without Metal) removed tiles shrink away instead.
    var canScatter: Bool { view?.window != nil }

    /// Where the dust's view is, in SwiftUI's `.global` space (the panel's hosting
    /// view), to place tiles measured there.
    fileprivate var frame: CGRect = .zero
    fileprivate weak var view: DustMetalView?

    /// Starts `picture`, drawn at `scale` pixels per point, turning to dust with its
    /// top left at `origin`. Only the part inside `visibleArea` is used, so a tile half
    /// scrolled out of sight doesn't show its hidden half as dust. Both are in
    /// SwiftUI's `.global` space.
    func scatter(_ picture: CGImage, scale: CGFloat, at origin: CGPoint, within visibleArea: CGRect) {
        guard let view else { return }
        view.scatter(picture,
                     scale: scale,
                     at: CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY),
                     within: visibleArea.offsetBy(dx: -frame.minX, dy: -frame.minY))
    }

    /// Fades the dust out quickly, as the panel closes.
    func clear() {
        view?.clear()
    }
}

/// Where a picture's dust goes and which of its pixels it uses: the picture placed
/// with its top left at `origin`, on the pixel grid so the dust's first frame matches
/// the tile exactly, and cut down to what shows inside `visibleArea`.
struct DustPlacement: Equatable {
    /// In the picture's pixels, from its top left, as `CGImage.cropping(to:)` takes it.
    let crop: CGRect
    /// Where the cropped picture goes, in points.
    let frame: CGRect

    /// Nil when none of the picture shows.
    init?(pictureWidth: Int, pictureHeight: Int, scale: CGFloat, origin: CGPoint, visibleArea: CGRect) {
        guard pictureWidth > 0, pictureHeight > 0, scale > 0 else { return nil }
        let placed = CGRect(x: (origin.x * scale).rounded() / scale,
                            y: (origin.y * scale).rounded() / scale,
                            width: CGFloat(pictureWidth) / scale,
                            height: CGFloat(pictureHeight) / scale)
        let shown = placed.intersection(visibleArea)
        guard !shown.isNull else { return nil }
        // Whole pixels of the picture.
        let left = ((shown.minX - placed.minX) * scale).rounded()
        let top = ((shown.minY - placed.minY) * scale).rounded()
        let right = ((shown.maxX - placed.minX) * scale).rounded()
        let bottom = ((shown.maxY - placed.minY) * scale).rounded()
        guard right - left >= 1, bottom - top >= 1 else { return nil }
        crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        frame = CGRect(x: placed.minX + left / scale,
                       y: placed.minY + top / scale,
                       width: crop.width / scale,
                       height: crop.height / scale)
    }
}

/// The view the dust is drawn in, laid over the whole panel. It takes no clicks, and
/// draws nothing outside `outline`, the panel's shape in its own space.
struct DustOverlay: View {
    let field: DustField
    let outline: Path

    var body: some View {
        DustRepresentable(field: field, outline: outline)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                field.frame = frame
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct DustRepresentable: NSViewRepresentable {
    let field: DustField
    let outline: Path

    func makeNSView(context: Context) -> NSView {
        // Without Metal there's nothing to draw, and removed tiles shrink away instead.
        guard let pipelines = DustPipelines.shared else { return NSView() }
        let view = DustMetalView(pipelines: pipelines)
        view.outline = outline
        field.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? DustMetalView)?.outline = outline
    }
}

// MARK: - Metal

/// The compiled shaders, made once. Nil if this Mac can't run them.
@MainActor
final class DustPipelines {
    static let shared = DustPipelines()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let scatter: MTLComputePipelineState
    let drift: MTLComputePipelineState
    let draw: MTLRenderPipelineState

    private init?() {
        do {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary(),
                  let scatterFunction = library.makeFunction(name: "dustScatter"),
                  let driftFunction = library.makeFunction(name: "dustDrift"),
                  let vertexFunction = library.makeFunction(name: "dustGrainVertex"),
                  let fragmentFunction = library.makeFunction(name: "dustGrainFragment") else {
                Log.app.error("Dust: Metal or its shaders aren't available")
                return nil
            }
            let drawing = MTLRenderPipelineDescriptor()
            drawing.vertexFunction = vertexFunction
            drawing.fragmentFunction = fragmentFunction
            let color = drawing.colorAttachments[0]!
            color.pixelFormat = DustMetalView.pixelFormat
            // Premultiplied colors, each grain over what's under it.
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.device = device
            self.queue = queue
            scatter = try device.makeComputePipelineState(function: scatterFunction)
            drift = try device.makeComputePipelineState(function: driftFunction)
            draw = try device.makeRenderPipelineState(descriptor: drawing)
        } catch {
            Log.app.error("Dust: couldn't build its pipelines: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Matches `DustGrain` in DustEffect.metal.
struct DustGrain {
    var offset: SIMD2<Float>
    var velocity: SIMD2<Float>
    var life: Float
    var padding: Float
}

/// Matches `DustPiece` in DustEffect.metal.
struct DustPiece {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var grid: SIMD2<UInt32>
    var phase: Float
    var step: Float
    var seed: UInt32
    var padding: Float = 0
}

/// Draws the dust with Metal while any is in the air, and sits paused and empty
/// otherwise.
final class DustMetalView: MTKView {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// Simulation time runs this much faster than real time, as in Telegram's.
    static let simulationSpeed = 2.0
    /// How long a tile's dust lasts, in real seconds: the front takes 0.8 s to cross
    /// it, and the last grains it frees live up to 1.5 s of simulation time
    /// (`sweepDuration` and `longestLife` in DustEffect.metal).
    static let duration = 0.8 + 1.5 / simulationSpeed

    /// The panel's shape in this view. No grain is drawn outside it.
    var outline: Path? {
        didSet {
            if outline != oldValue { outlineMask = nil }
        }
    }

    private struct Piece {
        let picture: MTLTexture
        let grains: MTLBuffer
        let frame: CGRect
        let grid: SIMD2<UInt32>
        let seed: UInt32
        /// Real seconds since the tile was removed.
        var phase: Double = 0
        var isScattered = false

        var grainCount: Int { Int(grid.x * grid.y) }
    }

    private let pipelines: DustPipelines
    private var pieces: [Piece] = []
    private var lastFrameTime: CFTimeInterval?
    /// `outline` drawn at the drawable's size, white inside. Made again when either changes.
    private var outlineMask: MTLTexture?

    init(pipelines: DustPipelines) {
        self.pipelines = pipelines
        super.init(frame: .zero, device: pipelines.device)
        colorPixelFormat = Self.pixelFormat
        // The pictures are turned into Display P3, so the colors match the tiles.
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        // Drawn only while there's dust, at the display's full rate.
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 120
        // Each frame shows in the same Core Animation transaction as the rest of the
        // window. So the dust's first frame appears together with the tile being
        // hidden, never a frame early or late.
        presentsWithTransaction = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks, hover and drops pass through to the tiles below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// See-through wherever there's no dust. Set again here in case the Metal layer
    /// was only made once the view joined the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        matchLayerScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchLayerScale()
    }

    /// Gives the Metal layer the window's scale. AppKit leaves it at 0 when the window
    /// starts out with no size, as the panel does, and a layer at scale 0 shows nothing
    /// at all, although every frame is drawn.
    private func matchLayerScale() {
        guard let scale = window?.backingScaleFactor, scale > 0, layer?.contentsScale != scale else { return }
        layer?.contentsScale = scale
    }

    /// `origin` and `visibleArea` in this view's points.
    func scatter(_ picture: CGImage, scale: CGFloat, at origin: CGPoint, within visibleArea: CGRect) {
        guard let placement = DustPlacement(pictureWidth: picture.width, pictureHeight: picture.height,
                                            scale: scale, origin: origin, visibleArea: visibleArea),
              let shown = picture.cropping(to: placement.crop),
              let texture = Self.texture(from: shown, device: pipelines.device) else { return }
        let frame = placement.frame
        // One grain per point.
        let grid = SIMD2<UInt32>(UInt32(max(1, frame.width.rounded())),
                                 UInt32(max(1, frame.height.rounded())))
        let length = Int(grid.x * grid.y) * MemoryLayout<DustGrain>.stride
        guard let grains = pipelines.device.makeBuffer(length: length, options: .storageModePrivate) else { return }
        pieces.append(Piece(picture: texture,
                            grains: grains,
                            frame: frame,
                            grid: grid,
                            seed: UInt32.random(in: .min ... .max)))
        // Dust that was fading out with a closing panel comes back for the new tile.
        alphaValue = 1
        matchLayerScale()
        // The first frame right away, inside the current transaction, then one per
        // display refresh until the dust is gone.
        draw()
        isPaused = false
    }

    /// A tenth of a second's fade, the same as the shelf's as the panel closes, then
    /// the dust is gone.
    func clear() {
        guard !pieces.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.pieces.removeAll()
            self.draw()
            self.alphaValue = 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        // A long gap, such as a stall, counts as one ordinary frame, so the dust
        // doesn't jump.
        let elapsed = lastFrameTime.map { min(now - $0, 1.0 / 30) } ?? 0
        lastFrameTime = now
        for index in pieces.indices {
            pieces[index].phase += elapsed
        }
        pieces.removeAll { $0.phase >= Self.duration }
        // With the dust gone, this frame clears the view and the drawing stops.
        defer {
            if pieces.isEmpty {
                isPaused = true
                lastFrameTime = nil
            }
        }

        guard bounds.width > 0, bounds.height > 0,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = pipelines.queue.makeCommandBuffer() else { return }

        let viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        let step = Float(elapsed * Self.simulationSpeed)
        if !pieces.isEmpty, let compute = commands.makeComputeCommandEncoder() {
            for index in pieces.indices {
                var piece = uniforms(for: pieces[index], viewSize: viewSize, step: step)
                compute.setBuffer(pieces[index].grains, offset: 0, index: 0)
                compute.setBytes(&piece, length: MemoryLayout<DustPiece>.stride, index: 1)
                if !pieces[index].isScattered {
                    pieces[index].isScattered = true
                    dispatch(pipelines.scatter, count: pieces[index].grainCount, on: compute)
                }
                if step > 0 {
                    dispatch(pipelines.drift, count: pieces[index].grainCount, on: compute)
                }
            }
            compute.endEncoding()
        }

        // The pass clears to transparent, so with no pieces left this frame is empty.
        if let render = commands.makeRenderCommandEncoder(descriptor: pass) {
            if !pieces.isEmpty, let mask = mask() {
                render.setRenderPipelineState(pipelines.draw)
                render.setFragmentTexture(mask, index: 1)
                for index in pieces.indices {
                    var piece = uniforms(for: pieces[index], viewSize: viewSize, step: step)
                    render.setVertexBuffer(pieces[index].grains, offset: 0, index: 0)
                    render.setVertexBytes(&piece, length: MemoryLayout<DustPiece>.stride, index: 1)
                    render.setFragmentTexture(pieces[index].picture, index: 0)
                    render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                          instanceCount: pieces[index].grainCount)
                }
            }
            render.endEncoding()
        }
        // What `presentsWithTransaction` asks for: wait until the GPU has the work,
        // then present inside the current transaction.
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }

    private func uniforms(for piece: Piece, viewSize: SIMD2<Float>, step: Float) -> DustPiece {
        DustPiece(origin: SIMD2(Float(piece.frame.minX), Float(piece.frame.minY)),
                  size: SIMD2(Float(piece.frame.width), Float(piece.frame.height)),
                  viewSize: viewSize,
                  grid: piece.grid,
                  phase: Float(piece.phase),
                  step: step,
                  seed: piece.seed)
    }

    private func dispatch(_ pipeline: MTLComputePipelineState, count: Int, on encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    }

    // MARK: - Textures

    /// The panel's outline at the drawable's size, white inside and black outside.
    /// The whole view counts as inside until an outline is set.
    private func mask() -> MTLTexture? {
        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)
        if let outlineMask, outlineMask.width == width, outlineMask.height == height {
            return outlineMask
        }
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Points, y down, as the outline is drawn in SwiftUI.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / bounds.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(outline?.cgPath ?? CGPath(rect: bounds, transform: nil))
        context.fillPath()
        outlineMask = Self.texture(from: context, pixelFormat: .r8Unorm, bytesPerPixel: 1, device: pipelines.device)
        return outlineMask
    }

    /// `image` as premultiplied BGRA in Display P3, the format the view draws in.
    private static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return texture(from: context, pixelFormat: pixelFormat, bytesPerPixel: 4, device: device)
    }

    /// A bitmap's pixels as a texture. A bitmap's first row is its top, as a
    /// texture's is.
    private static func texture(from context: CGContext, pixelFormat: MTLPixelFormat,
                                bytesPerPixel: Int, device: MTLDevice) -> MTLTexture? {
        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: context.width,
                                                                  height: context.height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, context.width, context.height),
                        mipmapLevel: 0,
                        withBytes: data,
                        bytesPerRow: context.bytesPerRow)
        return texture
    }
}

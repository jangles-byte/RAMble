import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

/// One CPU-side particle instance. Layout matches `ParticleIn` in the shaders.
public struct Particle {
    public var position: SIMD2<Float>   // points, origin bottom-left
    public var velocity: SIMD2<Float>
    public var color: SIMD4<Float>      // linear RGBA
    public var size: Float              // radius in points
    public var glow: Float              // 0…1 extra emission
    public var shape: Shape
    private var _pad: Float = 0

    public enum Shape: Float {
        case disc = 0
        case square = 1
        case streak = 2
    }

    public init(position: SIMD2<Float>, velocity: SIMD2<Float> = .zero,
                color: SIMD4<Float>, size: Float, glow: Float = 0, shape: Shape = .disc) {
        self.position = position
        self.velocity = velocity
        self.color = color
        self.size = size
        self.glow = glow
        self.shape = shape
    }
}

struct SceneUniforms {
    var viewport: SIMD2<Float>
    var globalAlpha: Float
    var time: Float
    var sceneScale: Float
}

struct CompositeUniforms {
    var bloomStrength: Float
    var exposure: Float
    var vignette: Float
    var aberration: Float
}

/// Reusable HDR Metal renderer.
///
/// Particles render emissive light into an rgba16Float accumulation buffer
/// (bright cores exceed 1.0), persistent trails fade between frames, a
/// three-octave bloom chain spreads the HDR overflow, and a filmic composite
/// tone-maps and grades the result into the transparent drawable. Drives the
/// active `AnimationPlugin` each frame.
public final class Renderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice

    /// Scene bounds in points (plugins position particles in this space).
    public private(set) var bounds = SIMD2<Float>(1, 1)
    public var theme: Theme = Themes.glass {
        didSet { if theme != oldValue { activePlugin?.themeDidChange(theme) } }
    }
    /// Overall overlay opacity 0…1.
    public var globalAlpha: Float = 1.0
    /// Scale factor applied to the scene (settings "scale").
    public var sceneScale: Float = 1.0

    public var activePlugin: AnimationPlugin? {
        didSet {
            guard activePlugin !== oldValue else { return }
            activePlugin?.prepare(bounds: bounds, theme: theme)
            lastWorld = (SIMD2(.nan, .nan), SIMD2(.nan, .nan))  // resend world
        }
    }
    /// Latest state snapshot; assigned by the coordinator on the main thread.
    public var currentState = SystemState()

    private static let hdrFormat = MTLPixelFormat.rgba16Float
    private static let drawableFormat = MTLPixelFormat.bgra8Unorm

    private let commandQueue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let fadePipeline: MTLRenderPipelineState
    private let thresholdPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let blur: MPSImageGaussianBlur

    // HDR scene + a three-level bloom mip chain (½, ¼, ⅛ resolution).
    private var accumTexture: MTLTexture?
    private var brightTexture: MTLTexture?     // ½ res, bright-pass output
    private var bloomHalf: MTLTexture?         // ½ res, tight glow
    private var quarterTexture: MTLTexture?    // ¼ res downsample
    private var bloomQuarter: MTLTexture?      // ¼ res, medium glow
    private var eighthTexture: MTLTexture?     // ⅛ res downsample
    private var bloomEighth: MTLTexture?       // ⅛ res, wide glow

    // Triple-buffered particle instance buffers.
    private static let maxParticles = 32_768
    private static let inflightCount = 3
    private var particleBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflightSemaphore = DispatchSemaphore(value: Renderer.inflightCount)

    private var frameParticles: [Particle] = []
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastWorld = (min: SIMD2<Float>(.nan, .nan), max: SIMD2<Float>(.nan, .nan))

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.setupFailed("makeCommandQueue failed")
        }
        commandQueue = queue

        let library = try device.makeLibrary(source: ShaderSource.library, options: nil)

        func pipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat,
                      configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { _ in })
        throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            configure(desc.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        particlePipeline = try pipeline(vertex: "particle_vertex", fragment: "particle_fragment",
                                        pixelFormat: Self.hdrFormat) {
            $0.isBlendingEnabled = true
            $0.rgbBlendOperation = .add
            $0.alphaBlendOperation = .add
            $0.sourceRGBBlendFactor = .one          // fragment premultiplies
            $0.destinationRGBBlendFactor = .one     // additive HDR accumulation
            $0.sourceAlphaBlendFactor = .one
            $0.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        // Trail fade: dst *= blendColor (source factor zero).
        fadePipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "fade_fragment",
                                    pixelFormat: Self.hdrFormat) {
            $0.isBlendingEnabled = true
            $0.rgbBlendOperation = .add
            $0.alphaBlendOperation = .add
            $0.sourceRGBBlendFactor = .zero
            $0.destinationRGBBlendFactor = .blendColor
            $0.sourceAlphaBlendFactor = .zero
            $0.destinationAlphaBlendFactor = .blendAlpha
        }
        thresholdPipeline = try pipeline(vertex: "fullscreen_vertex",
                                         fragment: "threshold_fragment",
                                         pixelFormat: Self.hdrFormat)
        copyPipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "copy_fragment",
                                    pixelFormat: Self.hdrFormat)
        compositePipeline = try pipeline(vertex: "fullscreen_vertex",
                                         fragment: "composite_fragment",
                                         pixelFormat: Self.drawableFormat)

        blur = MPSImageGaussianBlur(device: device, sigma: 3.5)
        blur.edgeMode = .clamp

        for _ in 0..<Self.inflightCount {
            guard let buffer = device.makeBuffer(
                length: MemoryLayout<Particle>.stride * Self.maxParticles,
                options: .storageModeShared) else {
                throw RendererError.setupFailed("particle buffer allocation failed")
            }
            particleBuffers.append(buffer)
        }
        super.init()
    }

    // MARK: - Plugin API

    /// Queue particles for this frame. Called by plugins from `render(renderer:)`.
    public func submit(_ particles: [Particle]) {
        frameParticles.append(contentsOf: particles)
        if frameParticles.count > Self.maxParticles {
            frameParticles.removeLast(frameParticles.count - Self.maxParticles)
        }
    }

    public func submit(_ particle: Particle) {
        if frameParticles.count < Self.maxParticles { frameParticles.append(particle) }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let scale = view.window?.backingScaleFactor ?? 2
        bounds = SIMD2(Float(size.width / scale), Float(size.height / scale))
        accumTexture = nil  // rebuild offscreen textures at the new size
        activePlugin?.prepare(bounds: bounds, theme: theme)
        lastWorld = (SIMD2(.nan, .nan), SIMD2(.nan, .nan))      // resend world
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 1.0 / 15.0))  // clamp long stalls
        lastFrameTime = now

        if bounds.x <= 1 {
            let size = view.bounds.size
            bounds = SIMD2(Float(size.width), Float(size.height))
            // The plugin was prepared against the placeholder bounds; rebuild
            // its scene now that the real view size is known.
            activePlugin?.prepare(bounds: bounds, theme: theme)
            lastWorld = (SIMD2(.nan, .nan), SIMD2(.nan, .nan))
        }

        // The screen's edges in scene coordinates: scaling in NDC keeps the
        // scene centered, so at scale < 1 the world extends past the scene
        // (things can fall out of the scene box and land on the real screen
        // bottom); at scale > 1 the world is a window into the scene.
        let scale = max(sceneScale, 0.05)
        let half = bounds * 0.5
        let extent = bounds / (2 * scale)
        let worldMin = half - extent
        let worldMax = half + extent
        if worldMin != lastWorld.min || worldMax != lastWorld.max {
            lastWorld = (worldMin, worldMax)
            activePlugin?.worldChanged(worldMin: worldMin, worldMax: worldMax)
        }

        var state = currentState
        state.stress = state.stress.clamped01
        activePlugin?.update(state: state, deltaTime: dt)

        frameParticles.removeAll(keepingCapacity: true)
        activePlugin?.render(renderer: self)

        guard let drawable = view.currentDrawable else { return }
        ensureTextures(for: drawable.texture)
        guard let accum = accumTexture, let bright = brightTexture,
              let bloomH = bloomHalf, let quarter = quarterTexture,
              let bloomQ = bloomQuarter, let eighth = eighthTexture, let bloomE = bloomEighth,
              inflightSemaphore.wait(timeout: .now() + .milliseconds(50)) == .success,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.addCompletedHandler { [inflightSemaphore] _ in
            inflightSemaphore.signal()
        }

        let buffer = particleBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % Self.inflightCount
        let count = min(frameParticles.count, Self.maxParticles)
        if count > 0 {
            frameParticles.withUnsafeBufferPointer { src in
                buffer.contents().copyMemory(from: src.baseAddress!,
                                             byteCount: MemoryLayout<Particle>.stride * count)
            }
        }

        let uniforms = SceneUniforms(viewport: bounds,
                                     globalAlpha: globalAlpha,
                                     time: Float(now - startTime),
                                     sceneScale: max(sceneScale, 0.05))

        encodeFrame(commandBuffer, particles: buffer, count: count, uniforms: uniforms,
                    into: view.currentRenderPassDescriptor, target: nil)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encodes the full HDR pipeline — trail fade + particles into accum, the
    /// bloom mip chain, then the filmic composite. Composite target is either
    /// an existing render-pass descriptor (the live drawable) or `target`
    /// (offscreen snapshots).
    private func encodeFrame(_ commandBuffer: MTLCommandBuffer,
                             particles buffer: MTLBuffer, count: Int,
                             uniforms: SceneUniforms,
                             into passDescriptor: MTLRenderPassDescriptor?,
                             target: MTLTexture?) {
        guard let accum = accumTexture, let bright = brightTexture,
              let bloomH = bloomHalf, let quarter = quarterTexture,
              let bloomQ = bloomQuarter, let eighth = eighthTexture,
              let bloomE = bloomEighth else { return }
        var uniforms = uniforms

        // Pass 1: fade previous frame (trails), then draw particles into accum.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = accum
        scenePass.colorAttachments[0].loadAction = .load
        scenePass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            let p = activePlugin?.preferredTrailPersistence ?? theme.trailPersistence
            encoder.setRenderPipelineState(fadePipeline)
            encoder.setBlendColor(red: p, green: p, blue: p, alpha: p)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if count > 0 {
                encoder.setRenderPipelineState(particlePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride,
                                       index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: count)
            }
            encoder.endEncoding()
        }

        // Pass 2: bright-pass, then build the bloom mip chain.
        var threshold: Float = 0.62
        fullscreen(commandBuffer, pipeline: thresholdPipeline, into: bright,
                   textures: [accum]) { encoder in
            encoder.setFragmentBytes(&threshold, length: 4, index: 0)
        }
        // Downsample bright → ¼ → ⅛ (linear-filtered copies).
        fullscreen(commandBuffer, pipeline: copyPipeline, into: quarter, textures: [bright])
        fullscreen(commandBuffer, pipeline: copyPipeline, into: eighth, textures: [quarter])
        // Blur each octave. Progressively lower res = progressively wider glow.
        blur.encode(commandBuffer: commandBuffer, sourceTexture: bright, destinationTexture: bloomH)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: quarter, destinationTexture: bloomQ)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: eighth, destinationTexture: bloomE)

        // Pass 3: filmic composite + post-grade.
        let rpd: MTLRenderPassDescriptor
        if let passDescriptor { rpd = passDescriptor }
        else if let target {
            rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
        } else { return }

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            var comp = CompositeUniforms(
                bloomStrength: min(theme.glowIntensity, 1.25),
                exposure: 1.0,
                vignette: 0.32,
                aberration: 0.004)
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(accum, index: 0)
            encoder.setFragmentTexture(bloomH, index: 1)
            encoder.setFragmentTexture(bloomQ, index: 2)
            encoder.setFragmentTexture(bloomE, index: 3)
            encoder.setFragmentBytes(&comp, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    // MARK: - Offscreen snapshot (headless; for previews and marketing shots)

    /// Renders `plugin` under `state`/`theme` to a still image, warming the
    /// simulation for `warmupFrames` so trails and populations build up.
    /// Runs entirely offscreen — no window, no screen-recording permission.
    public func snapshot(plugin: AnimationPlugin, theme: Theme, state: SystemState,
                         sizePoints: SIMD2<Int>, scaleFactor: Int = 2,
                         warmupFrames: Int = 180, intensity: Float = 1.4) -> CGImage? {
        self.theme = theme
        self.globalAlpha = 1
        self.sceneScale = 1
        bounds = SIMD2(Float(sizePoints.x), Float(sizePoints.y))
        var s = state
        s.intensity = intensity
        currentState = s

        let pxW = sizePoints.x * scaleFactor, pxH = sizePoints.y * scaleFactor
        let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.drawableFormat, width: pxW, height: pxH, mipmapped: false)
        targetDesc.usage = [.renderTarget, .shaderRead]
        targetDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDesc) else { return nil }
        ensureTextures(for: target)

        activePlugin = plugin
        plugin.prepare(bounds: bounds, theme: theme)

        let buffer = particleBuffers[0]
        for _ in 0..<max(warmupFrames, 1) {
            plugin.update(state: s, deltaTime: 1.0 / 60.0)
            frameParticles.removeAll(keepingCapacity: true)
            plugin.render(renderer: self)
            let count = min(frameParticles.count, Self.maxParticles)
            if count > 0 {
                frameParticles.withUnsafeBufferPointer { src in
                    buffer.contents().copyMemory(from: src.baseAddress!,
                                                 byteCount: MemoryLayout<Particle>.stride * count)
                }
            }
            guard let cb = commandQueue.makeCommandBuffer() else { return nil }
            let uniforms = SceneUniforms(viewport: bounds, globalAlpha: 1,
                                         time: Float(0), sceneScale: 1)
            encodeFrame(cb, particles: buffer, count: count, uniforms: uniforms,
                        into: nil, target: target)
            cb.commit()
            cb.waitUntilCompleted()
        }
        return Self.cgImage(from: target)
    }

    private static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let rowBytes = w * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * h)
        texture.getBytes(&raw, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs, bitmapInfo: info.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// Run a fullscreen-triangle pass into `target`, binding `textures` as
    /// fragment inputs 0…n and letting the caller set any extra bytes.
    private func fullscreen(_ commandBuffer: MTLCommandBuffer,
                            pipeline: MTLRenderPipelineState,
                            into target: MTLTexture,
                            textures: [MTLTexture],
                            configure: (MTLRenderCommandEncoder) -> Void = { _ in }) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (i, tex) in textures.enumerated() { encoder.setFragmentTexture(tex, index: i) }
        configure(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureTextures(for drawableTexture: MTLTexture) {
        let w = drawableTexture.width
        let h = drawableTexture.height
        if let accum = accumTexture, accum.width == w, accum.height == h { return }

        func makeTexture(_ width: Int, _ height: Int) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.hdrFormat, width: max(1, width), height: max(1, height),
                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        accumTexture = makeTexture(w, h)
        brightTexture = makeTexture(w / 2, h / 2)
        bloomHalf = makeTexture(w / 2, h / 2)
        quarterTexture = makeTexture(w / 4, h / 4)
        bloomQuarter = makeTexture(w / 4, h / 4)
        eighthTexture = makeTexture(w / 8, h / 8)
        bloomEighth = makeTexture(w / 8, h / 8)

        // Clear the accumulation texture once so trails start from transparency.
        if let accum = accumTexture,
           let cb = commandQueue.makeCommandBuffer() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = accum
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cb.commit()
        }
    }
}

public enum RendererError: Error {
    case setupFailed(String)
}

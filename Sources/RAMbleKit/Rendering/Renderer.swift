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
}

/// Reusable Metal renderer: instanced particle quads, persistent trail
/// accumulation, bright-pass + Gaussian bloom, and alpha composite into a
/// transparent drawable. Drives the active `AnimationPlugin` each frame.
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
        }
    }
    /// Latest state snapshot; assigned by the coordinator on the main thread.
    public var currentState = SystemState()

    private let commandQueue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let fadePipeline: MTLRenderPipelineState
    private let thresholdPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let blur: MPSImageGaussianBlur

    private var accumTexture: MTLTexture?
    private var brightTexture: MTLTexture?
    private var bloomTexture: MTLTexture?

    // Triple-buffered particle instance buffers.
    private static let maxParticles = 32_768
    private static let inflightCount = 3
    private var particleBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflightSemaphore = DispatchSemaphore(value: Renderer.inflightCount)

    private var frameParticles: [Particle] = []
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.setupFailed("makeCommandQueue failed")
        }
        commandQueue = queue

        let library = try device.makeLibrary(source: ShaderSource.library, options: nil)
        let pixelFormat = MTLPixelFormat.bgra8Unorm

        func pipeline(vertex: String, fragment: String,
                      configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void)
        throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            configure(desc.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        particlePipeline = try pipeline(vertex: "particle_vertex", fragment: "particle_fragment") {
            $0.isBlendingEnabled = true
            $0.rgbBlendOperation = .add
            $0.alphaBlendOperation = .add
            $0.sourceRGBBlendFactor = .one          // fragment premultiplies
            $0.destinationRGBBlendFactor = .one     // additive glow accumulation
            $0.sourceAlphaBlendFactor = .one
            $0.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        // Trail fade: dst *= blendColor (fragment output is ignored via .zero).
        fadePipeline = try pipeline(vertex: "fullscreen_vertex", fragment: "fade_fragment") {
            $0.isBlendingEnabled = true
            $0.rgbBlendOperation = .add
            $0.alphaBlendOperation = .add
            $0.sourceRGBBlendFactor = .zero
            $0.destinationRGBBlendFactor = .blendColor
            $0.sourceAlphaBlendFactor = .zero
            $0.destinationAlphaBlendFactor = .blendAlpha
        }
        thresholdPipeline = try pipeline(vertex: "fullscreen_vertex",
                                         fragment: "threshold_fragment") { _ in }
        compositePipeline = try pipeline(vertex: "fullscreen_vertex",
                                         fragment: "composite_fragment") { _ in }

        blur = MPSImageGaussianBlur(device: device, sigma: 6.0)
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
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 1.0 / 15.0))  // clamp long stalls
        lastFrameTime = now

        if bounds.x <= 1 {
            let size = view.bounds.size
            bounds = SIMD2(Float(size.width), Float(size.height))
        }

        var state = currentState
        state.stress = state.stress.clamped01
        activePlugin?.update(state: state, deltaTime: dt)

        frameParticles.removeAll(keepingCapacity: true)
        activePlugin?.render(renderer: self)

        guard let drawable = view.currentDrawable else { return }
        ensureTextures(for: drawable.texture)
        guard let accum = accumTexture, let bright = brightTexture,
              let bloomTex = bloomTexture,
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

        var uniforms = SceneUniforms(viewport: bounds / max(sceneScale, 0.05),
                                     globalAlpha: globalAlpha,
                                     time: Float(now - startTime))

        // Pass 1: fade previous frame (trails), then draw particles into accum.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = accum
        scenePass.colorAttachments[0].loadAction = .load
        scenePass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            let p = theme.trailPersistence
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

        // Pass 2: bright-pass threshold into half-res texture.
        if theme.glowIntensity > 0.01 {
            let thresholdPass = MTLRenderPassDescriptor()
            thresholdPass.colorAttachments[0].texture = bright
            thresholdPass.colorAttachments[0].loadAction = .dontCare
            thresholdPass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: thresholdPass) {
                var threshold: Float = 0.25
                encoder.setRenderPipelineState(thresholdPipeline)
                encoder.setFragmentTexture(accum, index: 0)
                encoder.setFragmentBytes(&threshold, length: 4, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            blur.encode(commandBuffer: commandBuffer, sourceTexture: bright,
                        destinationTexture: bloomTex)
        }

        // Pass 3: composite accum + bloom into the transparent drawable.
        if let rpd = view.currentRenderPassDescriptor,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            var strength = theme.glowIntensity
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(accum, index: 0)
            encoder.setFragmentTexture(bloomTex, index: 1)
            encoder.setFragmentBytes(&strength, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureTextures(for drawableTexture: MTLTexture) {
        let w = drawableTexture.width
        let h = drawableTexture.height
        if let accum = accumTexture, accum.width == w, accum.height == h { return }

        func makeTexture(width: Int, height: Int) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height),
                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        accumTexture = makeTexture(width: w, height: h)
        brightTexture = makeTexture(width: w / 4, height: h / 4)
        bloomTexture = makeTexture(width: w / 4, height: h / 4)

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

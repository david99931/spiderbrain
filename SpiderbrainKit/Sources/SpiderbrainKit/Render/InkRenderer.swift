import Foundation
import Metal
import QuartzCore
import simd

/// Draws ink into a `CAMetalLayer` in two passes.
///
/// **Pass A** renders every triangle into an offscreen MSAA target at full opacity.
/// **Pass B** composites that resolved texture onto the drawable exactly once, at
/// the ink's real alpha.
///
/// The reason for two passes is the double-blend problem: a translucent stroke that
/// crosses itself - a tight loop, a hard reversal, the dot on a lowercase i -
/// composites twice at the crossing and produces a visible dark blotch. Rendering
/// opaque and applying alpha once at composite time removes it entirely.
///
/// The cost is that one composite carries one alpha, so this pass structure assumes
/// a single ink style on screen at a time. That holds for M1. When several alphas
/// coexist, group strokes by style and composite per group.
public final class InkRenderer {

    public struct Stats {
        public var liveVertexCount = 0
        public var committedVertexCount = 0
        public var lastFrameMilliseconds: Double = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var inkPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    private var multisampleTexture: MTLTexture?
    private var resolveTexture: MTLTexture?
    private var textureSize: CGSize = .zero

    private var liveBuffer: MTLBuffer?
    private var liveVertexCount = 0
    private var committedBuffer: MTLBuffer?
    private var committedVertexCount = 0

    private let sampleCount = 4

    public private(set) var stats = Stats()

    /// Background colour of the page.
    public var pageColor = MTLClearColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1.0)

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        guard buildPipelines() else { return nil }
    }

    public var metalDevice: MTLDevice { device }

    private func buildPipelines() -> Bool {
        do {
            let library = try device.makeLibrary(source: InkShaders.source, options: nil)

            let inkDescriptor = MTLRenderPipelineDescriptor()
            inkDescriptor.vertexFunction = library.makeFunction(name: "ink_vertex")
            inkDescriptor.fragmentFunction = library.makeFunction(name: "ink_fragment")
            inkDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            inkDescriptor.rasterSampleCount = sampleCount
            // Straight replace. Coverage antialiasing comes from MSAA, not blending,
            // so self-overlap cannot compound.
            inkDescriptor.colorAttachments[0].isBlendingEnabled = false
            inkPipeline = try device.makeRenderPipelineState(descriptor: inkDescriptor)

            let compositeDescriptor = MTLRenderPipelineDescriptor()
            compositeDescriptor.vertexFunction = library.makeFunction(name: "composite_vertex")
            compositeDescriptor.fragmentFunction = library.makeFunction(name: "composite_fragment")
            compositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Premultiplied source-over.
            compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
            compositeDescriptor.colorAttachments[0].rgbBlendOperation = .add
            compositeDescriptor.colorAttachments[0].alphaBlendOperation = .add
            compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            compositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            compositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)

            return true
        } catch {
            assertionFailure("Shader compilation failed: \(error)")
            return false
        }
    }

    // MARK: - Geometry upload

    /// Replace the in-progress stroke. Called every frame while the pen is down.
    public func setLiveGeometry(_ vertices: [InkVertex]) {
        liveVertexCount = vertices.count
        liveBuffer = makeBuffer(vertices, reusing: liveBuffer)
        stats.liveVertexCount = vertices.count
    }

    /// Replace all finished strokes. Called once when a stroke ends.
    ///
    /// M1 keeps every committed stroke as live geometry and re-uploads the lot. That
    /// is fine for a page of scribble and wrong for a document - M2 replaces this
    /// with tile rasterisation so committed ink stops being re-tessellated at all.
    public func setCommittedGeometry(_ vertices: [InkVertex]) {
        committedVertexCount = vertices.count
        committedBuffer = makeBuffer(vertices, reusing: committedBuffer)
        stats.committedVertexCount = vertices.count
    }

    private func makeBuffer(_ vertices: [InkVertex], reusing existing: MTLBuffer?) -> MTLBuffer? {
        guard !vertices.isEmpty else { return existing }
        let length = MemoryLayout<InkVertex>.stride * vertices.count
        if let existing, existing.length >= length {
            existing.contents().copyMemory(from: vertices, byteCount: length)
            return existing
        }
        // Over-allocate so a growing stroke does not reallocate every frame.
        let capacity = max(length * 2, 64 * 1024)
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
            return nil
        }
        buffer.contents().copyMemory(from: vertices, byteCount: length)
        return buffer
    }

    // MARK: - Drawing

    public func draw(in layer: CAMetalLayer, alpha: Double, cameraOffset: Vec2 = .zero, cameraZoom: Float = 1.0) {
        let started = CACurrentMediaTime()

        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureTargets(size: size)

        guard
            let drawable = layer.nextDrawable(),
            let multisampleTexture,
            let resolveTexture,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        // --- Pass A: all ink, opaque, into the offscreen layer.
        let inkPass = MTLRenderPassDescriptor()
        inkPass.colorAttachments[0].texture = multisampleTexture
        inkPass.colorAttachments[0].resolveTexture = resolveTexture
        inkPass.colorAttachments[0].loadAction = .clear
        inkPass.colorAttachments[0].storeAction = .multisampleResolve
        inkPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: inkPass) {
            encoder.setRenderPipelineState(inkPipeline)

            // Viewport in points, matching the coordinates the tessellator emitted.
            var viewport = SIMD2<Float>(
                Float(size.width / layer.contentsScale),
                Float(size.height / layer.contentsScale)
            )
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

            // Camera transform for world-to-view conversion.
            var cameraUniforms = SIMD4<Float>(
                Float(cameraOffset.x),
                Float(cameraOffset.y),
                cameraZoom,
                0  // padding
            )
            encoder.setVertexBytes(&cameraUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)

            if let committedBuffer, committedVertexCount > 0 {
                encoder.setVertexBuffer(committedBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: committedVertexCount
                )
            }
            if let liveBuffer, liveVertexCount > 0 {
                encoder.setVertexBuffer(liveBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: liveVertexCount
                )
            }
            encoder.endEncoding()
        }

        // --- Pass B: page colour, then the ink layer composited once at real alpha.
        let screenPass = MTLRenderPassDescriptor()
        screenPass.colorAttachments[0].texture = drawable.texture
        screenPass.colorAttachments[0].loadAction = .clear
        screenPass.colorAttachments[0].storeAction = .store
        screenPass.colorAttachments[0].clearColor = pageColor

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(resolveTexture, index: 0)
            var inkAlpha = Float(clamp(alpha, 0, 1))
            encoder.setFragmentBytes(&inkAlpha, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        stats.lastFrameMilliseconds = (CACurrentMediaTime() - started) * 1000
    }

    private func ensureTargets(size: CGSize) {
        guard size != textureSize else { return }
        textureSize = size

        let msaa = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        msaa.textureType = .type2DMultisample
        msaa.sampleCount = sampleCount
        msaa.usage = .renderTarget
        msaa.storageMode = .private
        multisampleTexture = device.makeTexture(descriptor: msaa)

        let resolve = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        resolve.usage = [.renderTarget, .shaderRead]
        resolve.storageMode = .private
        resolveTexture = device.makeTexture(descriptor: resolve)
    }
}

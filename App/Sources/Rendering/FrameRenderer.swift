import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Compiled pipeline for the YUV -> display shader.
struct MetalPipeline {
    let state: MTLRenderPipelineState

    enum PipelineError: Error {
        case missingFunction(String)
    }

    static func make(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws -> MetalPipeline {
        let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
        guard let vertex = library.makeFunction(name: "vertex_main") else {
            throw PipelineError.missingFunction("vertex_main")
        }
        guard let fragment = library.makeFunction(name: "fragment_main") else {
            throw PipelineError.missingFunction("fragment_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return MetalPipeline(state: try device.makeRenderPipelineState(descriptor: descriptor))
    }
}

/// GPU objects that must stay alive until the command buffer completes: the CVMetalTextures
/// (and through them the pixel buffer) are released in the completion handler (plan 5.2,
/// "OutOfBuffers").
struct FrameResources: @unchecked Sendable {
    let frame: Frame
    let lumaRef: CVMetalTexture
    let chromaRef: CVMetalTexture
    let luma: MTLTexture
    let chroma: MTLTexture
}

private struct VertexUniforms {
    var imageSize: SIMD2<Float>
    var viewSize: SIMD2<Float>
}

private struct FragmentUniforms {
    var black: Float
    var white: Float
    var invGamma: Float
    var red: Float
    var color: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// Draws the latest camera frame with the display transform and stretch (D-04, D-10).
///
/// `submit(_:)` may be called from any queue; `draw(descriptor:drawable:)` is called by the view
/// on the main thread. Only the newest frame is kept, so a slow GPU drops frames instead of
/// building latency.
final class FrameRenderer: @unchecked Sendable {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MetalPipeline
    private let textureCache: CVMetalTextureCache
    private let performance: PerformanceMonitor?
    private let log = AppLog.app

    private let lock = NSLock()
    private var latest: Frame?
    private var params = RenderParams.initial
    private var frameNotifier: (@Sendable () -> Void)?
    private var lastPresentedTimestamp: Double?
    private var drawCount = 0

    init?(performance: PerformanceMonitor?) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            AppLog.app.error("Metal is not available on this device")
            return nil
        }
        let pipeline: MetalPipeline
        do {
            pipeline = try MetalPipeline.make(device: device)
        } catch {
            AppLog.app.error("Metal shader compilation failed: \(error.localizedDescription)")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            AppLog.app.error("CVMetalTextureCacheCreate failed")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.textureCache = cache
        self.performance = performance
    }

    // MARK: - Inputs

    /// Stores the newest frame and asks the view to redraw.
    func submit(_ frame: Frame) {
        let notifier = lock.withLock { () -> (@Sendable () -> Void)? in
            latest = frame
            return frameNotifier
        }
        notifier?()
    }

    func setParams(_ newValue: RenderParams) {
        lock.withLock { params = newValue }
    }

    /// Called (from any queue) whenever a new frame arrived.
    func setFrameNotifier(_ notifier: (@Sendable () -> Void)?) {
        lock.withLock { frameNotifier = notifier }
    }

    // MARK: - Drawing

    /// Draws the latest frame into `drawable` (main thread, from the view's delegate).
    func draw(descriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        let (frame, params, isNew) = lock.withLock { () -> (Frame?, RenderParams, Bool) in
            let isNew = latest.map { $0.timestamp != lastPresentedTimestamp } ?? false
            if let latest { lastPresentedTimestamp = latest.timestamp }
            drawCount += 1
            return (latest, self.params, isNew)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let resources = encode(frame: frame, params: params, descriptor: descriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)

        let performance = self.performance
        let timestamp = frame?.timestamp
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(resources) {}
            if isNew, let timestamp {
                performance?.framePresented(framePTS: timestamp, now: CACurrentMediaTime())
            }
        }
        commandBuffer.commit()

        if lock.withLock({ drawCount % 30 == 0 }) {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    /// Encodes one render pass. Returns the resources that must outlive the command buffer.
    @discardableResult
    func encode(
        frame: Frame?, params: RenderParams, descriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) -> FrameResources? {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        defer { encoder.endEncoding() }
        guard let frame, let resources = makeResources(for: frame) else { return nil }

        encoder.setRenderPipelineState(pipeline.state)

        var matrix = params.matrix
        if matrix.count < 12 { matrix = RenderParams.identityMatrix }
        matrix.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setVertexBytes(base, length: 12 * MemoryLayout<Float>.stride, index: 0)
            }
        }
        var vertex = VertexUniforms(
            imageSize: SIMD2(Float(frame.width), Float(frame.height)), viewSize: params.viewSize
        )
        encoder.setVertexBytes(&vertex, length: MemoryLayout<VertexUniforms>.stride, index: 1)

        var fragment = FragmentUniforms(
            black: params.blackPoint, white: params.whitePoint,
            invGamma: 1 / max(params.gamma, 0.05),
            red: params.redMode ? 1 : 0, color: params.colorMode ? 1 : 0
        )
        encoder.setFragmentBytes(&fragment, length: MemoryLayout<FragmentUniforms>.stride, index: 0)
        encoder.setFragmentTexture(resources.luma, index: 0)
        encoder.setFragmentTexture(resources.chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return resources
    }

    private func makeResources(for frame: Frame) -> FrameResources? {
        let buffer = frame.pixelBuffer
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }

        var lumaRef: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &lumaRef
        )
        var chromaRef: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &chromaRef
        )
        guard lumaStatus == kCVReturnSuccess, chromaStatus == kCVReturnSuccess,
              let lumaRef, let chromaRef,
              let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef) else {
            log.error("CVMetalTextureCache: luma status \(lumaStatus), chroma status \(chromaStatus)")
            return nil
        }
        return FrameResources(frame: frame, lumaRef: lumaRef, chromaRef: chromaRef, luma: luma, chroma: chroma)
    }
}

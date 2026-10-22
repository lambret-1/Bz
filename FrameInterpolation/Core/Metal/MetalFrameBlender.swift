import Metal
import CoreVideo
import OSLog

/// Metal 帧混合器：使用 GPU 做简单 alpha 混合，用于快速模式
/// IOSurface 零拷贝 + PixelBufferPool 复用 + GPU 状态检查，避免黑帧
final class MetalFrameBlender {
    static let shared: MetalFrameBlender? = MetalFrameBlender()

    private let helper: MetalComputeHelper
    private let pipeline: MTLComputePipelineState
    private let logger = Logger(subsystem: "com.lambret.bz", category: "MetalFrameBlender")

    // 输出 buffer 复用池
    private let outputPool = PixelBufferPool()
    private var configuredWidth = 0
    private var configuredHeight = 0

    private init?() {
        guard let metalHelper = MetalComputeHelper.shared,
              let library = metalHelper.device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "simple_blend"),
              let pipeline = try? metalHelper.device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.helper = metalHelper
        self.pipeline = pipeline
    }

    /// 混合两帧：result = frame0 * alpha + frame1 * (1-alpha)
    /// - Parameters:
    ///   - frame0: 第一帧（BGRA8Unorm，IOSurface-backed）
    ///   - frame1: 第二帧（BGRA8Unorm，IOSurface-backed）
    ///   - alpha: 混合系数，0.5 为平均混合
    /// - Returns: 混合后的新 CVPixelBuffer，失败返回 nil（调用方回退CPU）
    func blend(frame0: CVPixelBuffer, frame1: CVPixelBuffer, alpha: Float = 0.5) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        guard width > 0, height > 0 else { return nil }

        // 尺寸变化时重新配置输出池
        if width != configuredWidth || height != configuredHeight {
            outputPool.configure(width: width, height: height, minBufferCount: 8)
            configuredWidth = width
            configuredHeight = height
        }

        // 从池取输出 buffer（IOSurface-backed，支持零拷贝）
        guard let output = outputPool.makeBuffer() else {
            logger.error("从PixelBufferPool获取输出buffer失败")
            return nil
        }

        // 三张纹理全部走 IOSurface 零拷贝，无 CPU/GPU 来回拷贝
        guard let tex0 = helper.makeIOSurfaceTexture(from: frame0, usage: .shaderRead),
              let tex1 = helper.makeIOSurfaceTexture(from: frame1, usage: .shaderRead),
              let texOut = helper.makeIOSurfaceTexture(from: output, usage: [.shaderRead, .shaderWrite]) else {
            logger.error("创建IOSurface纹理失败")
            return nil
        }

        // 执行 Metal compute
        guard let commandBuffer = helper.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(tex0, index: 0)
        encoder.setTexture(tex1, index: 1)
        encoder.setTexture(texOut, index: 2)
        var alphaValue = alpha
        encoder.setBytes(&alphaValue, length: MemoryLayout<Float>.size, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 关键：检查 GPU 执行状态，失败返回 nil（调用方回退CPU），不返回黑帧
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            logger.error("Metal blend GPU执行失败: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public), status: \(commandBuffer.status.rawValue, privacy: .public)")
            return nil
        }

        // texOut 直接写在 output 的 IOSurface 上，不需要 helper.copy() 回拷
        return output
    }
}

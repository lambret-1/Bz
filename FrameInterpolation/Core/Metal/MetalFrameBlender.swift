import Metal
import CoreVideo

/// Metal 帧混合器：使用 GPU 做简单 alpha 混合，用于快速模式
/// 替代 CPU 逐字节混合，降低 CPU 占用并提升速度
final class MetalFrameBlender {
    static let shared = MetalFrameBlender()

    private let helper = MetalComputeHelper.shared
    private let pipeline: MTLComputePipelineState

    private init?() {
        guard let library = helper.device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "simple_blend"),
              let pipeline = try? helper.device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.pipeline = pipeline
    }

    /// 混合两帧：result = frame0 * alpha + frame1 * (1-alpha)
    /// - Parameters:
    ///   - frame0: 第一帧（BGRA8Unorm）
    ///   - frame1: 第二帧（BGRA8Unorm）
    ///   - alpha: 混合系数，0.5 为平均混合
    /// - Returns: 混合后的新 CVPixelBuffer，失败返回 nil
    func blend(frame0: CVPixelBuffer, frame1: CVPixelBuffer, alpha: Float = 0.5) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        guard width > 0, height > 0 else { return nil }

        // 创建输出 pixelBuffer
        var outputBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &outputBuffer) == kCVReturnSuccess,
              let output = outputBuffer else {
            return nil
        }

        // 创建输入纹理（从 pixelBuffer 上传数据）
        guard let tex0 = helper.makeTexture(from: frame0, usage: .shaderRead),
              let tex1 = helper.makeTexture(from: frame1, usage: .shaderRead) else {
            return nil
        }

        // 创建输出纹理：独立的 .shared 纹理，不绑定 output pixelBuffer
        // 避免 IOSurface 隐式同步导致的间歇性全黑
        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outDescriptor.usage = [.shaderWrite]
        outDescriptor.storageMode = .shared
        guard let texOut = helper.device.makeTexture(descriptor: outDescriptor) else {
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

        // 用信号量等待完成，确保 GPU 写入对 CPU 可见
        let semaphore = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
        commandBuffer.commit()
        semaphore.wait()

        guard commandBuffer.status == .completed else {
            return nil
        }

        // 从输出纹理拷回 pixelBuffer
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        guard let dstAddr = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)

        texOut.getBytes(
            dstAddr,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        return output
    }
}

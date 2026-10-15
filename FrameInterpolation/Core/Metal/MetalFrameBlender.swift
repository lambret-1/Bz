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

        // 创建纹理
        guard let tex0 = helper.makeTexture(from: frame0, usage: .shaderRead),
              let tex1 = helper.makeTexture(from: frame1, usage: .shaderRead),
              let texOut = helper.makeTexture(from: output, usage: [.shaderRead, .shaderWrite]) else {
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

        // 从输出纹理拷回 pixelBuffer
        helper.copy(texture: texOut, to: output)

        return output
    }
}

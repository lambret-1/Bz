import CoreML
import CoreVideo
import Metal
import OSLog

/// 帧插值器：Metal 预处理 → Core ML 推理 → Metal 后处理
/// 输入前后两帧，输出中间帧
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为空转
final class FrameInterpolator {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "FrameInterpolator")

    // MARK: - 模型与 Metal 资源
    private let model: MLModel
    private let context: MetalContext
    private let preprocessPipeline: MTLComputePipelineState
    private let sigmoidPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private let blendPipeline: MTLComputePipelineState

    // MARK: - 配置
    /// 模型固定输入宽度
    let inputWidth: Int
    /// 模型固定输入高度
    let inputHeight: Int
    /// 输出缓冲区池
    private let outputPool: PixelBufferPool

    // MARK: - 初始化
    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(forResource: "RIFE_Lite", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: modelURL, configuration: {
                  let config = MLModelConfiguration()
                  config.computeUnits = .all // 允许使用 ANE / GPU / CPU
                  return config
              }()) else {
            // 模型文件不存在时返回 nil，调用方降级为空转
            return nil
        }
        self.model = model

        // 2. 初始化 Metal 上下文与计算管线
        let context = MetalContext.shared
        guard let pre = context.makePipeline(named: "bgra_to_nchw"),
              let sig = context.makePipeline(named: "sigmoid_mask"),
              let warp = context.makePipeline(named: "warp_frame"),
              let blend = context.makePipeline(named: "blend_frames") else {
            return nil
        }
        self.context = context
        self.preprocessPipeline = pre
        self.sigmoidPipeline = sig
        self.warpPipeline = warp
        self.blendPipeline = blend

        // 3. 模型固定输入尺寸（需与转换脚本一致）
        self.inputWidth = 512
        self.inputHeight = 512

        // 4. 输出缓冲区池
        self.outputPool = PixelBufferPool()
        outputPool.configure(width: inputWidth, height: inputHeight)

        logger.info("FrameInterpolator 初始化成功，模型输入: \(inputWidth)x\(inputHeight)")
    }

    // MARK: - 公开方法
    /// 输入前后两帧，输出中间帧
    /// - Parameters:
    ///   - frame0: 前一帧（CVPixelBuffer，32BGRA）
    ///   - frame1: 后一帧（CVPixelBuffer，32BGRA）
    /// - Returns: 中间帧（CVPixelBuffer，32BGRA），失败返回 nil
    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> CVPixelBuffer? {
        // 1. 预处理：缩放到模型输入尺寸 + BGRA → NCHW Float16
        guard let input0 = makeInputArray(from: frame0),
              let input1 = makeInputArray(from: frame1) else {
            logger.error("预处理失败")
            return nil
        }

        // 2. Core ML 推理
        guard let output = try? model.prediction(from: [
            "frame0": input0,
            "frame1": input1
        ]) else {
            logger.error("Core ML 推理失败")
            return nil
        }

        guard let flowArray = output.featureValue(for: "flow")?.multiArrayValue,
              let maskArray = output.featureValue(for: "mask")?.multiArrayValue else {
            logger.error("模型输出缺少 flow 或 mask")
            return nil
        }

        // 3. Metal 后处理：Sigmoid → Warp → Blend
        return postprocess(
            frame0: frame0,
            frame1: frame1,
            flow: flowArray,
            mask: maskArray
        )
    }

    // MARK: - 预处理
    /// 将 CVPixelBuffer 转换为模型输入的 MLMultiArray（NCHW Float16）
    /// 当前使用 CPU 循环实现，后续可优化为 Metal 零拷贝
    private func makeInputArray(from pixelBuffer: CVPixelBuffer) -> MLMultiArray? {
        // 缩放到模型输入尺寸
        guard let resized = resize(pixelBuffer: pixelBuffer, width: inputWidth, height: inputHeight) else {
            return nil
        }

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
            dataType: .float16
        ) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(resized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(resized, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(resized) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(resized)

        // BGRA → NCHW Float16，归一化到 [0, 1]
        let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: inputWidth * inputHeight * 3)
        let planeSize = inputWidth * inputHeight

        for y in 0..<inputHeight {
            for x in 0..<inputWidth {
                let offset = y * bytesPerRow + x * 4
                let b = Float16(base.load(fromByteOffset: offset, as: UInt8.self)) / 255.0
                let g = Float16(base.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255.0
                let r = Float16(base.load(fromByteOffset: offset + 2, as: UInt8.self)) / 255.0
                let idx = y * inputWidth + x
                ptr[idx] = r
                ptr[planeSize + idx] = g
                ptr[2 * planeSize + idx] = b
            }
        }

        return array
    }

    // MARK: - 后处理
    /// Metal 后处理：对掩码执行 Sigmoid，分别 Warp 前后帧，按掩码混合
    /// 当前为占位实现：直接返回第二帧，验证管线连通性
    /// 完整 Metal Warp + Blend 实现见资料7
    private func postprocess(
        frame0: CVPixelBuffer,
        frame1: CVPixelBuffer,
        flow: MLMultiArray,
        mask: MLMultiArray
    ) -> CVPixelBuffer? {
        // TODO: 资料7补全完整 Metal 后处理
        // 1. 将 mask 从 MLMultiArray 拷贝到 Metal 缓冲区
        // 2. sigmoid_mask 着色器：对掩码执行 Sigmoid
        // 3. warp_frame 着色器：用 flow 对 frame0 做前向 warp，对 frame1 做反向 warp
        // 4. blend_frames 着色器：按掩码混合两个 warp 后的帧
        // 5. 输出到 outputPool 的缓冲区

        // 占位：返回第二帧，确保管线可运行
        return frame1
    }

    // MARK: - 缩放
    /// 将 CVPixelBuffer 缩放到指定尺寸
    /// 当前使用 vImage 实现，后续可优化为 Metal
    private func resize(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        // 如果尺寸一致，直接返回
        if CVPixelBufferGetWidth(pixelBuffer) == width &&
           CVPixelBufferGetHeight(pixelBuffer) == height {
            return pixelBuffer
        }

        // 创建输出缓冲区
        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            return nil
        }

        // 使用 vImage 缩放
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }

        var srcBuffer = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        var dstBuffer = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(output)
        )

        let scaleError = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        if scaleError != kvImageNoError {
            logger.error("vImage 缩放失败，错误码: \(scaleError)")
            return nil
        }

        return output
    }
}

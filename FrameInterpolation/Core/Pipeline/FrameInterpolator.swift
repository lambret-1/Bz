import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

/// 帧插值器：预处理 → Core ML 推理 → 后处理
/// RIFE 4.22 Lite 模型直接输出中间帧，无需额外 Metal Warp/Blend
/// 输入前后两帧，输出中间帧（尺寸与输入一致）
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为空转
final class FrameInterpolator {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "FrameInterpolator")

    // MARK: - 模型与 Metal 资源
    private let model: MLModel
    private let context: MetalContext

    // MARK: - 配置
    /// 模型固定输入宽度
    let modelInputWidth = 512
    /// 模型固定输入高度
    let modelInputHeight = 512

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

        // 2. 初始化 Metal 上下文（预处理/后处理后续可优化为 Metal）
        self.context = MetalContext.shared

        logger.info("FrameInterpolator 初始化成功，模型输入: \(modelInputWidth)x\(modelInputHeight)")
    }

    // MARK: - 公开方法
    /// 输入前后两帧，输出中间帧
    /// - Parameters:
    ///   - frame0: 前一帧（CVPixelBuffer，32BGRA）
    ///   - frame1: 后一帧（CVPixelBuffer，32BGRA）
    /// - Returns: 中间帧（CVPixelBuffer，32BGRA，尺寸与输入一致），失败返回 nil
    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> CVPixelBuffer? {
        let originalWidth = CVPixelBufferGetWidth(frame0)
        let originalHeight = CVPixelBufferGetHeight(frame0)

        // 1. 预处理：缩放到 512x512 + BGRA → NCHW Float16
        guard let input0 = makeInputArray(from: frame0),
              let input1 = makeInputArray(from: frame1) else {
            logger.error("预处理失败")
            return nil
        }

        // 2. Core ML 推理
        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
            "frame0": input0,
            "frame1": input1
        ]), let output = try? model.prediction(from: featureProvider) else {
            logger.error("Core ML 推理失败")
            return nil
        }

        guard let outputArray = output.featureValue(for: "interpolatedFrame")?.multiArrayValue else {
            logger.error("模型输出缺少 interpolatedFrame")
            return nil
        }

        // 3. 后处理：NCHW Float16 → BGRA + 缩放到原始尺寸
        return makeOutputPixelBuffer(from: outputArray, width: originalWidth, height: originalHeight)
    }

    // MARK: - 预处理
    /// 将 CVPixelBuffer 转换为模型输入的 MLMultiArray（NCHW Float16，512x512）
    private func makeInputArray(from pixelBuffer: CVPixelBuffer) -> MLMultiArray? {
        // 缩放到模型输入尺寸
        guard let resized = resize(pixelBuffer: pixelBuffer, width: modelInputWidth, height: modelInputHeight) else {
            return nil
        }

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: modelInputHeight), NSNumber(value: modelInputWidth)],
            dataType: .float16
        ) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(resized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(resized, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(resized) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(resized)

        // BGRA → NCHW Float16，归一化到 [0, 1]
        let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: modelInputWidth * modelInputHeight * 3)
        let planeSize = modelInputWidth * modelInputHeight

        for y in 0..<modelInputHeight {
            for x in 0..<modelInputWidth {
                let offset = y * bytesPerRow + x * 4
                let b = Float16(base.load(fromByteOffset: offset, as: UInt8.self)) / 255.0
                let g = Float16(base.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255.0
                let r = Float16(base.load(fromByteOffset: offset + 2, as: UInt8.self)) / 255.0
                let idx = y * modelInputWidth + x
                ptr[idx] = r
                ptr[planeSize + idx] = g
                ptr[2 * planeSize + idx] = b
            }
        }

        return array
    }

    // MARK: - 后处理
    /// 将模型输出的 MLMultiArray（NCHW Float16）转换为 BGRA CVPixelBuffer，并缩放到指定尺寸
    private func makeOutputPixelBuffer(from array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
        // 先创建 512x512 的 BGRA 缓冲区
        var modelOutputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: modelInputWidth,
            kCVPixelBufferHeightKey as String: modelInputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(nil, modelInputWidth, modelInputHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &modelOutputBuffer)
        guard status == kCVReturnSuccess, let outputBuffer = modelOutputBuffer else {
            logger.error("创建输出缓冲区失败")
            return nil
        }

        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(outputBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)

        // NCHW Float16 → BGRA，反归一化到 [0, 255]
        let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: modelInputWidth * modelInputHeight * 3)
        let planeSize = modelInputWidth * modelInputHeight

        for y in 0..<modelInputHeight {
            for x in 0..<modelInputWidth {
                let idx = y * modelInputWidth + x
                let r = min(max(Int(Float(ptr[idx]) * 255.0), 0), 255)
                let g = min(max(Int(Float(ptr[planeSize + idx]) * 255.0), 0), 255)
                let b = min(max(Int(Float(ptr[2 * planeSize + idx]) * 255.0), 0), 255)
                let offset = y * bytesPerRow + x * 4
                base.storeBytes(of: UInt8(b), toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: UInt8(g), toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: UInt8(r), toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self) // Alpha
            }
        }

        // 如果目标尺寸与模型输出尺寸不同，缩放
        if width == modelInputWidth && height == modelInputHeight {
            return outputBuffer
        }

        return resize(pixelBuffer: outputBuffer, width: width, height: height)
    }

    // MARK: - 缩放
    /// 使用 vImage 将 CVPixelBuffer 缩放到指定尺寸
    private func resize(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(pixelBuffer) == width &&
           CVPixelBufferGetHeight(pixelBuffer) == height {
            return pixelBuffer
        }

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            logger.error("创建缩放缓冲区失败")
            return nil
        }

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

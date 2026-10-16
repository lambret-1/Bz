import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - PiperSR 超分引擎

/// PiperSR 2x 超分引擎
/// 纯 CPU 预处理（避免 Metal 着色器兼容性问题），输入输出尺寸从模型描述动态读取
/// 模型文件缺失或类型不兼容时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class PiperSREngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "PiperSREngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .piperSR
    let inputWidth: Int
    let inputHeight: Int
    let scaleFactor: Int = 2

    // MARK: - 私有属性

    private let model: MLModel
    /// 输出 PixelBuffer 复用池
    private let pool = PixelBufferPool()

    /// 模型输出的实际通道数（通常为 3）
    private let outputChannels: Int
    /// 模型输出的实际高度
    private let outputHeight: Int
    /// 模型输出的实际宽度
    private let outputWidth: Int
    /// 模型期望的输入数据类型
    private let inputDataType: MLMultiArrayDataType
    /// 模型输出数据类型
    private let outputDataType: MLMultiArrayDataType

    // MARK: - 初始化

    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.piperSR.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            return nil
        }
        self.model = model

        // 2. 验证模型输入输出类型必须为 multiArray
        guard let inputDesc = model.modelDescription.inputDescriptionsByName["input"],
              let outputDesc = model.modelDescription.outputDescriptionsByName["clip_0"] else {
            return nil
        }
        guard inputDesc.multiArrayConstraint != nil,
              outputDesc.multiArrayConstraint != nil else {
            logger.error("模型输入输出类型不是 multiArray，无法处理")
            return nil
        }

        // 3. 读取输入数据类型和尺寸
        if let descDataType = inputDesc.multiArrayConstraint?.dataType {
            inputDataType = descDataType
        } else {
            inputDataType = .float16
        }

        // 输入尺寸：优先从模型描述读取，处理动态尺寸（-1）的情况
        if let shape = inputDesc.multiArrayConstraint?.shape as? [Int], shape.count >= 4 {
            let h = shape[2]
            let w = shape[3]
            inputHeight = h > 0 ? h : 360
            inputWidth = w > 0 ? w : 640
        } else {
            inputHeight = 360
            inputWidth = 640
        }

        // 4. 读取输出数据类型和尺寸
        if let descDataType = outputDesc.multiArrayConstraint?.dataType {
            outputDataType = descDataType
        } else {
            outputDataType = .float16
        }

        if let shape = outputDesc.multiArrayConstraint?.shape as? [Int], shape.count >= 4 {
            outputChannels = shape[1] > 0 ? shape[1] : 3
            let h = shape[2]
            let w = shape[3]
            outputHeight = h > 0 ? h : inputHeight * 2
            outputWidth = w > 0 ? w : inputWidth * 2
        } else {
            outputChannels = 3
            outputHeight = inputHeight * 2
            outputWidth = inputWidth * 2
        }

        // 5. 配置输出 PixelBufferPool
        pool.configure(width: outputWidth, height: outputHeight, format: kCVPixelFormatType_32BGRA)

        logger.info("PiperSR 初始化成功，输入: \(self.inputWidth)x\(self.inputHeight) \(self.inputDataType.rawValue)，输出: \(self.outputWidth)x\(self.outputHeight) \(self.outputDataType.rawValue)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 2x 超分
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // 1. 若输入尺寸不符，先缩放到模型输入尺寸
        var inputFrame = pixelBuffer
        var resizedBuffer: CVPixelBuffer?
        if srcWidth != inputWidth || srcHeight != inputHeight {
            resizedBuffer = resize(pixelBuffer: pixelBuffer, width: inputWidth, height: inputHeight)
            guard let resized = resizedBuffer else {
                logger.error("输入帧缩放失败")
                return nil
            }
            inputFrame = resized
        }

        // 2. CPU 预处理：BGRA → NCHW（Float16 或 Float32）
        guard let inputArray = makeInputArray(from: inputFrame) else {
            logger.error("创建输入 MLMultiArray 失败")
            return nil
        }

        // 3. Core ML 推理
        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "clip_0")?.multiArrayValue else {
            logger.error("Core ML 推理失败")
            return nil
        }

        // 4. 验证输出尺寸
        let expectedCount = outputChannels * outputHeight * outputWidth
        guard outputArray.count >= expectedCount else {
            logger.error("输出尺寸不匹配，期望: \(expectedCount)，实际: \(outputArray.count)")
            return nil
        }

        // 5. NCHW → BGRA CVPixelBuffer
        guard let outputBuffer = makePixelBuffer(from: outputArray) else {
            logger.error("输出 PixelBuffer 创建失败")
            return nil
        }

        // 6. 复制颜色空间附件
        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)

        return outputBuffer
    }

    // MARK: - CPU 预处理：BGRA CVPixelBuffer → NCHW MLMultiArray

    private func makeInputArray(from pixelBuffer: CVPixelBuffer) -> MLMultiArray? {
        let shape: [NSNumber] = [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)]
        guard let inputArray = try? MLMultiArray(shape: shape, dataType: inputDataType) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        let plane = inputWidth * inputHeight

        switch inputDataType {
        case .float16:
            let dst = inputArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<inputHeight {
                let rowOffset = y * srcBytesPerRow
                for x in 0..<inputWidth {
                    let pixelOffset = rowOffset + x * 4
                    let idx = y * inputWidth + x
                    // BGRA → NCHW，归一化到 [0,1]
                    dst[0 * plane + idx] = Float16(Float(src[pixelOffset + 2]) / 255.0) // R
                    dst[1 * plane + idx] = Float16(Float(src[pixelOffset + 1]) / 255.0) // G
                    dst[2 * plane + idx] = Float16(Float(src[pixelOffset + 0]) / 255.0) // B
                }
            }
        case .float32:
            let dst = inputArray.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<inputHeight {
                let rowOffset = y * srcBytesPerRow
                for x in 0..<inputWidth {
                    let pixelOffset = rowOffset + x * 4
                    let idx = y * inputWidth + x
                    dst[0 * plane + idx] = Float(src[pixelOffset + 2]) / 255.0 // R
                    dst[1 * plane + idx] = Float(src[pixelOffset + 1]) / 255.0 // G
                    dst[2 * plane + idx] = Float(src[pixelOffset + 0]) / 255.0 // B
                }
            }
        default:
            logger.error("不支持的输入数据类型: \(inputDataType.rawValue)")
            return nil
        }

        return inputArray
    }

    // MARK: - NCHW MLMultiArray → BGRA CVPixelBuffer

    private func makePixelBuffer(from array: MLMultiArray) -> CVPixelBuffer? {
        if let outputBuffer = pool.makeBuffer() {
            return fillPixelBuffer(outputBuffer, from: array)
        }

        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let result = buffer else {
            return nil
        }
        return fillPixelBuffer(result, from: array)
    }

    private func fillPixelBuffer(_ outputBuffer: CVPixelBuffer, from array: MLMultiArray) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(outputBuffer) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        let plane = outputWidth * outputHeight
        let totalPixels = min(plane, array.count / max(outputChannels, 1))

        switch array.dataType {
        case .float16:
            let srcPtr = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for idx in 0..<totalPixels {
                let y = idx / outputWidth
                let x = idx % outputWidth
                let pixelOffset = y * dstBytesPerRow + x * 4
                let rIdx = 0 * plane + idx
                let gIdx = 1 * plane + idx
                let bIdx = 2 * plane + idx
                guard rIdx < array.count, gIdx < array.count, bIdx < array.count else { break }
                dst[pixelOffset + 0] = clampFloat16ToUInt8(srcPtr[bIdx])
                dst[pixelOffset + 1] = clampFloat16ToUInt8(srcPtr[gIdx])
                dst[pixelOffset + 2] = clampFloat16ToUInt8(srcPtr[rIdx])
                dst[pixelOffset + 3] = 255
            }
        case .float32:
            let srcPtr = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for idx in 0..<totalPixels {
                let y = idx / outputWidth
                let x = idx % outputWidth
                let pixelOffset = y * dstBytesPerRow + x * 4
                let rIdx = 0 * plane + idx
                let gIdx = 1 * plane + idx
                let bIdx = 2 * plane + idx
                guard rIdx < array.count, gIdx < array.count, bIdx < array.count else { break }
                dst[pixelOffset + 0] = clampFloatToUInt8(srcPtr[bIdx])
                dst[pixelOffset + 1] = clampFloatToUInt8(srcPtr[gIdx])
                dst[pixelOffset + 2] = clampFloatToUInt8(srcPtr[rIdx])
                dst[pixelOffset + 3] = 255
            }
        default:
            logger.error("不支持的输出数据类型: \(array.dataType.rawValue)")
            return nil
        }

        return outputBuffer
    }

    private func clampFloat16ToUInt8(_ value: Float16) -> UInt8 {
        let f = Float(value)
        if f.isNaN || f.isInfinite { return 0 }
        let clamped = max(0.0, min(1.0, f))
        return UInt8(clamped * 255.0)
    }

    private func clampFloatToUInt8(_ value: Float32) -> UInt8 {
        if value.isNaN || value.isInfinite { return 0 }
        let clamped = max(0.0, min(1.0, value))
        return UInt8(clamped * 255.0)
    }

    // MARK: - vImage 缩放

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

        let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            return nil
        }

        return output
    }

    // MARK: - 颜色空间附件复制

    private func copyColorSpaceAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        let colorKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferChromaLocationTopFieldKey
        ]
        for key in colorKeys {
            if let unmanagedValue = CVBufferGetAttachment(src, key, nil) {
                let value = unmanagedValue.takeUnretainedValue()
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
    }
}

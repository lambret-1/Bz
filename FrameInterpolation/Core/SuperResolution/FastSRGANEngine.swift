import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - PiperSR 超分引擎

/// PiperSR 2x 超分引擎
/// 640×360 全帧推理，ANE 原生，2x 放大输出 1280×720
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class FastSRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "PiperSREngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .fastSRGAN
    let inputWidth: Int = 640
    let inputHeight: Int = 360
    let scaleFactor: Int = 2

    // MARK: - 私有属性

    private let model: MLModel
    /// 模型输入数据类型（float16 或 float32）
    private let inputDataType: MLMultiArrayDataType
    /// 模型输出数据类型
    private let outputDataType: MLMultiArrayDataType

    /// 取消标志
    private var isCancelledFlag = false

    // MARK: - 初始化

    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.fastSRGAN.modelFileName,
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

        // 2. 读取输入输出数据类型
        let inputDesc = model.modelDescription.inputDescriptionsByName["input"]
        let outputDesc = model.modelDescription.outputDescriptionsByName["output"]

        if let descDataType = inputDesc?.multiArrayConstraint?.dataType {
            inputDataType = descDataType
        } else {
            inputDataType = .float16
        }

        if let descDataType = outputDesc?.multiArrayConstraint?.dataType {
            outputDataType = descDataType
        } else {
            outputDataType = .float16
        }

        logger.info("PiperSR 引擎初始化成功，输入: \(self.inputWidth)x\(self.inputHeight)，放大: \(self.scaleFactor)x，输入类型: \(self.inputDataType.rawValue)，输出类型: \(self.outputDataType.rawValue)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 2x 超分（全帧推理）
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let outputWidth = srcWidth * scaleFactor
        let outputHeight = srcHeight * scaleFactor

        // 1. 将输入帧缩放到模型要求的 640×360
        guard let resizedInput = resizePixelBuffer(pixelBuffer, width: inputWidth, height: inputHeight) else {
            logger.error("输入缩放失败")
            return nil
        }

        // 2. 填充输入 MLMultiArray
        guard let inputArray = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
            dataType: inputDataType
        ) else {
            logger.error("创建输入数组失败")
            return nil
        }

        guard fillInputArray(inputArray, from: resizedInput) else {
            logger.error("填充输入数组失败")
            return nil
        }

        // 3. 模型推理
        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "output")?.multiArrayValue else {
            logger.error("CoreML 推理失败")
            return nil
        }

        // 4. 输出 MLMultiArray → CVPixelBuffer（1280×720）
        guard let modelOutput = createOutputBuffer(from: outputArray, width: inputWidth * scaleFactor, height: inputHeight * scaleFactor) else {
            logger.error("创建输出缓冲区失败")
            return nil
        }

        // 5. 输出缩放到目标尺寸（srcWidth*2 × srcHeight*2）
        guard let finalOutput = resizePixelBuffer(modelOutput, width: outputWidth, height: outputHeight) else {
            logger.error("输出缩放失败")
            return nil
        }

        // 6. 复制颜色空间附件
        copyColorSpaceAttachments(from: pixelBuffer, to: finalOutput)

        return finalOutput
    }

    /// 取消处理
    func cancel() { isCancelledFlag = true }

    // MARK: - 像素缓冲缩放（vImage）

    private func resizePixelBuffer(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var destBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &destBuffer) == kCVReturnSuccess,
              let dest = destBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        var srcBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source),
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )

        var vImageDestBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(dest),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(dest)
        )

        vImageScale_ARGB8888(&srcBuffer, &vImageDestBuffer, nil, vImage_Flags(kvImageHighQualityResampling))

        return dest
    }

    // MARK: - 输入填充（BGRA → NCHW MLMultiArray）

    private func fillInputArray(_ array: MLMultiArray, from source: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(source) else { return false }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        let plane = inputWidth * inputHeight

        switch inputDataType {
        case .float16:
            let dst = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<inputHeight {
                for x in 0..<inputWidth {
                    let srcOffset = y * srcBytesPerRow + x * 4
                    let idx = y * inputWidth + x
                    // BGRA → RGB，归一化到 [0,1]
                    dst[0 * plane + idx] = Float16(Float(src[srcOffset + 2]) / 255.0) // R
                    dst[1 * plane + idx] = Float16(Float(src[srcOffset + 1]) / 255.0) // G
                    dst[2 * plane + idx] = Float16(Float(src[srcOffset + 0]) / 255.0) // B
                }
            }
        case .float32:
            let dst = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<inputHeight {
                for x in 0..<inputWidth {
                    let srcOffset = y * srcBytesPerRow + x * 4
                    let idx = y * inputWidth + x
                    dst[0 * plane + idx] = Float(src[srcOffset + 2]) / 255.0 // R
                    dst[1 * plane + idx] = Float(src[srcOffset + 1]) / 255.0 // G
                    dst[2 * plane + idx] = Float(src[srcOffset + 0]) / 255.0 // B
                }
            }
        default:
            logger.error("不支持的输入数据类型: \(self.inputDataType.rawValue)")
            return false
        }

        return true
    }

    // MARK: - 输出 MLMultiArray → CVPixelBuffer

    private func createOutputBuffer(from array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let result = buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(result) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        let plane = width * height

        switch array.dataType {
        case .float16:
            let src = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let pixelOffset = y * dstBytesPerRow + x * 4
                    let r = Float(src[0 * plane + idx])
                    let g = Float(src[1 * plane + idx])
                    let b = Float(src[2 * plane + idx])
                    dst[pixelOffset + 0] = UInt8(max(0, min(255, Int((b * 255).rounded()))))
                    dst[pixelOffset + 1] = UInt8(max(0, min(255, Int((g * 255).rounded()))))
                    dst[pixelOffset + 2] = UInt8(max(0, min(255, Int((r * 255).rounded()))))
                    dst[pixelOffset + 3] = 255
                }
            }
        case .float32:
            let src = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let pixelOffset = y * dstBytesPerRow + x * 4
                    let r = src[0 * plane + idx]
                    let g = src[1 * plane + idx]
                    let b = src[2 * plane + idx]
                    dst[pixelOffset + 0] = UInt8(max(0, min(255, Int((b * 255).rounded()))))
                    dst[pixelOffset + 1] = UInt8(max(0, min(255, Int((g * 255).rounded()))))
                    dst[pixelOffset + 2] = UInt8(max(0, min(255, Int((r * 255).rounded()))))
                    dst[pixelOffset + 3] = 255
                }
            }
        default:
            logger.error("不支持的输出数据类型: \(array.dataType.rawValue)")
            return nil
        }

        return result
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

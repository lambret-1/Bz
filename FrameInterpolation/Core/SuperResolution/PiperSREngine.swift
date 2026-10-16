import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

// MARK: - PiperSR 超分引擎

/// PiperSR 2x 超分引擎
/// 输入输出尺寸从模型描述动态读取，避免硬编码不匹配导致崩溃
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class PiperSREngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "PiperSREngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .piperSR
    let inputWidth: Int
    let inputHeight: Int
    let scaleFactor: Int = 2

    // MARK: - 私有属性

    private let model: MLModel
    private let helper = MetalComputeHelper.shared
    private let commandQueue: MTLCommandQueue
    private let preprocessPipeline: MTLComputePipelineState

    /// 输入 MTLBuffer（NCHW Float16）
    private let inputBuffer: MTLBuffer
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

        // 2. 从模型描述动态读取输入输出尺寸
        let inputDesc = model.modelDescription.inputDescriptionsByName["input"]
        let outputDesc = model.modelDescription.outputDescriptionsByName["clip_0"]

        // 输入数据类型：优先从模型描述读取
        if let descDataType = inputDesc?.multiArrayConstraint?.dataType {
            inputDataType = descDataType
        } else {
            inputDataType = .float16
        }

        // 输入尺寸：优先从模型描述读取，失败时使用默认 640x360
        if let shape = inputDesc?.multiArrayConstraint?.shape as? [Int], shape.count >= 4 {
            inputHeight = shape[2]
            inputWidth = shape[3]
        } else {
            inputHeight = 360
            inputWidth = 640
        }

        // 输出尺寸：优先从模型描述读取
        if let shape = outputDesc?.multiArrayConstraint?.shape as? [Int], shape.count >= 4 {
            outputChannels = shape[1]
            outputHeight = shape[2]
            outputWidth = shape[3]
        } else {
            outputChannels = 3
            outputHeight = inputHeight * 2
            outputWidth = inputWidth * 2
        }

        // 3. 初始化 Metal 预处理管线
        guard let queue = helper.device.makeCommandQueue(),
              let library = helper.device.makeDefaultLibrary(),
              let preprocessFunc = library.makeFunction(name: "bgra_to_nchw"),
              let preprocessPipeline = try? helper.device.makeComputePipelineState(function: preprocessFunc) else {
            return nil
        }
        self.commandQueue = queue
        self.preprocessPipeline = preprocessPipeline

        // 4. 预分配输入 MTLBuffer（NCHW Float16）
        let plane = inputWidth * inputHeight
        let inputBytes = plane * 3 * MemoryLayout<Float16>.size
        guard let inputBuffer = helper.device.makeBuffer(length: inputBytes, options: .storageModeShared) else {
            return nil
        }
        self.inputBuffer = inputBuffer

        // 5. 配置输出 PixelBufferPool
        pool.configure(width: outputWidth, height: outputHeight, format: kCVPixelFormatType_32BGRA)

        logger.info("PiperSR 引擎初始化成功，输入: \(self.inputWidth)x\(self.inputHeight)，输出: \(self.outputWidth)x\(self.outputHeight)，通道: \(self.outputChannels)")
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

        // 2. Metal 预处理：BGRA → NCHW Float16
        guard let inputTexture = helper.makeIOSurfaceTexture(from: inputFrame, usage: .shaderRead),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.error("创建预处理纹理或命令缓冲失败")
            return nil
        }

        encodePreprocess(commandBuffer: commandBuffer, source: inputTexture)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 检查 GPU 执行结果
        if commandBuffer.status != .completed {
            logger.error("Metal 预处理执行失败，状态: \(commandBuffer.status.rawValue)")
            return nil
        }

        // 3. 创建 MLMultiArray 并推理
        // 使用模型期望的数据类型，避免类型不匹配导致崩溃
        let shape: [NSNumber] = [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)]
        guard let inputArray = try? MLMultiArray(shape: shape, dataType: inputDataType) else {
            logger.error("创建输入 MLMultiArray 失败，类型: \(inputDataType.rawValue)")
            return nil
        }

        // 安全拷贝：Metal 输出是 Float16，若模型期望 Float32 需转换
        if inputDataType == .float16 {
            let copyLength = min(inputBuffer.length, inputArray.count * MemoryLayout<Float16>.size)
            memcpy(inputArray.dataPointer, inputBuffer.contents(), copyLength)
        } else if inputDataType == .float32 {
            // Float16 → Float32 转换
            let srcPtr = inputBuffer.contents().assumingMemoryBound(to: Float16.self)
            let dstPtr = inputArray.dataPointer.assumingMemoryBound(to: Float32.self)
            let count = min(inputBuffer.length / MemoryLayout<Float16>.size, inputArray.count)
            for i in 0..<count {
                dstPtr[i] = Float(srcPtr[i])
            }
        }

        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "clip_0")?.multiArrayValue else {
            logger.error("Core ML 推理失败")
            return nil
        }

        // 4. 验证输出尺寸和数据类型，避免越界访问导致崩溃
        let expectedCount = outputChannels * outputHeight * outputWidth
        guard outputArray.count >= expectedCount else {
            logger.error("模型输出尺寸不匹配，期望: \(expectedCount)，实际: \(outputArray.count)")
            return nil
        }

        // 5. NCHW Float16 → BGRA CVPixelBuffer
        guard let outputBuffer = makePixelBuffer(from: outputArray) else {
            logger.error("输出 PixelBuffer 创建失败")
            return nil
        }

        // 6. 复制颜色空间附件
        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)

        return outputBuffer
    }

    // MARK: - Metal 预处理编码

    private func encodePreprocess(commandBuffer: MTLCommandBuffer, source: MTLTexture) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(preprocessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)

        var width = UInt32(inputWidth)
        var height = UInt32(inputHeight)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)

        let threadGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGrid = MTLSize(
            width: (inputWidth + 15) / 16,
            height: (inputHeight + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadgroup: threadGroup)
        encoder.endEncoding()
    }

    // MARK: - NCHW Float16 → BGRA CVPixelBuffer

    private func makePixelBuffer(from array: MLMultiArray) -> CVPixelBuffer? {
        // 从池中获取输出缓冲区
        if let outputBuffer = pool.makeBuffer() {
            return fillPixelBuffer(outputBuffer, from: array)
        }

        // 池不可用时直接创建
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

        // 根据输出数据类型选择读取方式，避免类型不匹配导致崩溃
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

    /// 将 Float16 值钳制到 [0,1] 并转换为 UInt8 [0,255]
    private func clampFloat16ToUInt8(_ value: Float16) -> UInt8 {
        let f = Float(value)
        if f.isNaN || f.isInfinite { return 0 }
        let clamped = max(0.0, min(1.0, f))
        return UInt8(clamped * 255.0)
    }

    /// 将 Float32 值钳制到 [0,1] 并转换为 UInt8 [0,255]
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

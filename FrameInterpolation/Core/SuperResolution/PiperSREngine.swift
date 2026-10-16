import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

// MARK: - PiperSR 超分引擎

/// PiperSR 2x 超分引擎
/// 固定输入 640×360，输出 1280×720，ANE 原生优化
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class PiperSREngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "PiperSREngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .piperSR
    let inputWidth: Int = 640
    let inputHeight: Int = 360
    let scaleFactor: Int = 2

    // MARK: - 私有属性

    private let model: MLModel
    private let helper = MetalComputeHelper.shared
    private let commandQueue: MTLCommandQueue
    private let preprocessPipeline: MTLComputePipelineState

    /// 预分配输入 MTLBuffer（640×360×3×Float16）
    private let inputBuffer: MTLBuffer
    /// PixelBuffer 复用池
    private let pool = PixelBufferPool()

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

        // 2. 初始化 Metal 预处理管线（复用 bgra_to_nchw shader）
        guard let queue = helper.device.makeCommandQueue(),
              let library = helper.device.makeDefaultLibrary(),
              let preprocessFunc = library.makeFunction(name: "bgra_to_nchw"),
              let preprocessPipeline = try? helper.device.makeComputePipelineState(function: preprocessFunc) else {
            return nil
        }
        self.commandQueue = queue
        self.preprocessPipeline = preprocessPipeline

        // 3. 预分配输入 MTLBuffer
        let plane = inputWidth * inputHeight
        let inputBytes = plane * 3 * MemoryLayout<Float16>.size
        guard let inputBuffer = helper.device.makeBuffer(length: inputBytes, options: .storageModeShared) else {
            return nil
        }
        self.inputBuffer = inputBuffer

        // 4. 配置输出 PixelBufferPool
        pool.configure(width: inputWidth * scaleFactor, height: inputHeight * scaleFactor, format: kCVPixelFormatType_32BGRA)

        logger.info("PiperSR 引擎初始化成功，输入: \(self.inputWidth)x\(self.inputHeight)，输出: \(self.inputWidth * self.scaleFactor)x\(self.inputHeight * self.scaleFactor)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 2x 超分
    /// - Parameter pixelBuffer: 输入帧（32BGRA），尺寸应为 640×360，不符时先缩放
    /// - Returns: 1280×720 的 32BGRA 帧，失败返回 nil
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

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

        // 3. 创建 MLMultiArray 并推理
        let shape: [NSNumber] = [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)]
        guard let inputArray = try? MLMultiArray(shape: shape, dataType: .float16) else {
            logger.error("创建输入 MLMultiArray 失败")
            return nil
        }
        memcpy(inputArray.dataPointer, inputBuffer.contents(), inputBuffer.length)

        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "output")?.multiArrayValue else {
            logger.error("Core ML 推理失败")
            return nil
        }

        // 4. NCHW Float16 → BGRA CVPixelBuffer
        let outputWidth = inputWidth * scaleFactor
        let outputHeight = inputHeight * scaleFactor
        guard let outputBuffer = makePixelBuffer(from: outputArray, width: outputWidth, height: outputHeight) else {
            logger.error("输出 PixelBuffer 创建失败")
            return nil
        }

        // 5. 复制颜色空间附件
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
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadGroup: threadGroup)
        encoder.endEncoding()
    }

    // MARK: - NCHW Float16 → BGRA CVPixelBuffer

    private func makePixelBuffer(from array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
        // 从池中获取输出缓冲区（池已配置为输出尺寸）
        if let outputBuffer = pool.makeBuffer() {
            return fillPixelBuffer(outputBuffer, from: array, width: width, height: height)
        }

        // 池不可用时直接创建
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
        return fillPixelBuffer(result, from: array, width: width, height: height)
    }

    private func fillPixelBuffer(_ outputBuffer: CVPixelBuffer, from array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(outputBuffer) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        let plane = width * height
        let srcPtr = array.dataPointer.assumingMemoryBound(to: Float16.self)

        // NCHW → BGRA：R通道=plane*0, G通道=plane*1, B通道=plane*2
        for y in 0..<height {
            let rowOffset = y * dstBytesPerRow
            for x in 0..<width {
                let idx = y * width + x
                // 钳制到 [0,1] 再转 [0,255]
                let r = clampFloat16ToUInt8(srcPtr[0 * plane + idx])
                let g = clampFloat16ToUInt8(srcPtr[1 * plane + idx])
                let b = clampFloat16ToUInt8(srcPtr[2 * plane + idx])
                let pixelOffset = rowOffset + x * 4
                dst[pixelOffset + 0] = b  // BGRA: B
                dst[pixelOffset + 1] = g  // G
                dst[pixelOffset + 2] = r  // R
                dst[pixelOffset + 3] = 255 // A
            }
        }

        return outputBuffer
    }

    /// 将 Float16 值钳制到 [0,1] 并转换为 UInt8 [0,255]
    private func clampFloat16ToUInt8(_ value: Float16) -> UInt8 {
        let f = Float(value)
        let clamped = max(0.0, min(1.0, f))
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

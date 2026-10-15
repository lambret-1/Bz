import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

/// 帧插值器：Metal 预处理 → Core ML 光流估计 → Metal 后处理（Warp + Blend）
/// RIFE 4.22 Lite 模型输出光流与掩码，warp 和 blend 由 Metal Compute 完成
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为空转
final class FrameInterpolator {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "FrameInterpolator")

    // MARK: - Metal 资源
    private let helper = MetalComputeHelper.shared
    private let commandQueue: MTLCommandQueue
    private let preprocessPipeline: MTLComputePipelineState
    private let sigmoidPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private let blendPipeline: MTLComputePipelineState
    private let rgbaToBgraPipeline: MTLComputePipelineState

    // MARK: - Core ML 模型
    private let model: MLModel

    // MARK: - 配置
    /// 模型固定输入宽度
    let modelInputWidth = 512
    /// 模型固定输入高度
    let modelInputHeight = 512

    // MARK: - 预分配 MTLBuffer
    private let frame0Buffer: MTLBuffer
    private let frame1Buffer: MTLBuffer
    private let flowBuffer: MTLBuffer
    private let maskBuffer: MTLBuffer

    // MARK: - PixelBuffer 复用池
    private let pool = PixelBufferPool()

    // MARK: - 初始化
    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(forResource: "RIFE_Lite", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: modelURL, configuration: {
                  let config = MLModelConfiguration()
                  config.computeUnits = .all
                  return config
              }()) else {
            return nil
        }
        self.model = model

        // 2. 初始化 Metal 计算管线
        guard let queue = helper.device.makeCommandQueue(),
              let library = helper.device.makeDefaultLibrary(),
              let pre = library.makeFunction(name: "bgra_to_nchw"),
              let sig = library.makeFunction(name: "sigmoid_mask"),
              let warp = library.makeFunction(name: "warp_frame"),
              let blend = library.makeFunction(name: "blend_frames"),
              let rgb2bgra = library.makeFunction(name: "rgba_to_bgra") else {
            logger.error("Metal 函数加载失败")
            return nil
        }
        self.commandQueue = queue

        do {
            self.preprocessPipeline = try helper.device.makeComputePipelineState(function: pre)
            self.sigmoidPipeline = try helper.device.makeComputePipelineState(function: sig)
            self.warpPipeline = try helper.device.makeComputePipelineState(function: warp)
            self.blendPipeline = try helper.device.makeComputePipelineState(function: blend)
            self.rgbaToBgraPipeline = try helper.device.makeComputePipelineState(function: rgb2bgra)
        } catch {
            logger.error("Metal 管线创建失败: \(error.localizedDescription)")
            return nil
        }

        // 3. 预分配 MTLBuffer
        let plane = modelInputWidth * modelInputHeight
        let frameBytes = plane * 3 * MemoryLayout<Float16>.size
        let flowBytes = plane * 4 * MemoryLayout<Float16>.size
        let maskBytes = plane * 1 * MemoryLayout<Float16>.size

        guard let f0 = helper.device.makeBuffer(length: frameBytes, options: .storageModeShared),
              let f1 = helper.device.makeBuffer(length: frameBytes, options: .storageModeShared),
              let fl = helper.device.makeBuffer(length: flowBytes, options: .storageModeShared),
              let mk = helper.device.makeBuffer(length: maskBytes, options: .storageModeShared) else {
            logger.error("MTLBuffer 分配失败")
            return nil
        }
        self.frame0Buffer = f0
        self.frame1Buffer = f1
        self.flowBuffer = fl
        self.maskBuffer = mk

        // 4. 配置输出 PixelBufferPool
        pool.configure(width: modelInputWidth, height: modelInputHeight, format: kCVPixelFormatType_32BGRA)

        logger.info("FrameInterpolator 初始化成功，模型输入: \(self.modelInputWidth)x\(self.modelInputHeight)，Metal 后处理已启用")
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

        // 1. 缩放到模型输入尺寸 512x512
        guard let resized0 = resize(pixelBuffer: frame0, width: modelInputWidth, height: modelInputHeight),
              let resized1 = resize(pixelBuffer: frame1, width: modelInputWidth, height: modelInputHeight) else {
            logger.error("输入帧缩放失败")
            return nil
        }

        // 2. 创建 Metal 纹理
        guard let tex0 = helper.makeTexture(from: resized0),
              let tex1 = helper.makeTexture(from: resized1) else {
            logger.error("创建输入纹理失败")
            return nil
        }

        // 3. Metal 预处理：BGRA → NCHW Float16
        guard let preprocessBuffer = commandQueue.makeCommandBuffer() else { return nil }
        encodePreprocess(commandBuffer: preprocessBuffer, source: tex0, dstBuffer: frame0Buffer)
        encodePreprocess(commandBuffer: preprocessBuffer, source: tex1, dstBuffer: frame1Buffer)
        preprocessBuffer.commit()
        preprocessBuffer.waitUntilCompleted()

        // 4. Core ML 推理（光流估计）
        guard let input0 = makeMultiArray(from: frame0Buffer, shape: [1, 3, NSNumber(value: modelInputHeight), NSNumber(value: modelInputWidth)]),
              let input1 = makeMultiArray(from: frame1Buffer, shape: [1, 3, NSNumber(value: modelInputHeight), NSNumber(value: modelInputWidth)]),
              let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
                  "frame0": input0,
                  "frame1": input1
              ]),
              let output = try? model.prediction(from: featureProvider) else {
            logger.error("Core ML 推理失败")
            return nil
        }

        guard let flowArray = output.featureValue(for: "flow")?.multiArrayValue,
              let maskArray = output.featureValue(for: "mask")?.multiArrayValue else {
            logger.error("模型输出缺少 flow 或 mask")
            return nil
        }

        // 5. 将 MLMultiArray 拷贝到 MTLBuffer
        copyToBuffer(multiArray: flowArray, buffer: flowBuffer)
        copyToBuffer(multiArray: maskArray, buffer: maskBuffer)

        // 6. Metal 后处理：Sigmoid → Warp → Warp → Blend → RGBA→BGRA
        guard let postprocessBuffer = commandQueue.makeCommandBuffer() else { return nil }

        guard let warped0 = helper.makeEmptyTexture(width: modelInputWidth, height: modelInputHeight),
              let warped1 = helper.makeEmptyTexture(width: modelInputWidth, height: modelInputHeight),
              let blended = helper.makeEmptyTexture(width: modelInputWidth, height: modelInputHeight),
              let outputBGRA = helper.makeEmptyTexture(width: modelInputWidth, height: modelInputHeight, format: .bgra8Unorm) else {
            logger.error("创建后处理纹理失败")
            return nil
        }

        // Sigmoid mask
        encodeSigmoid(commandBuffer: postprocessBuffer)

        // Warp：RIFE 输出的光流已是 t=0.5 对应的位移，直接使用无需再乘系数
        // frame0 用正向光流（前2通道），frame1 用反向光流（后2通道）
        encodeWarp(commandBuffer: postprocessBuffer, source: tex0, destination: warped0, scale: 1.0, channelOffset: 0)
        encodeWarp(commandBuffer: postprocessBuffer, source: tex1, destination: warped1, scale: 1.0, channelOffset: 2)

        // Blend
        encodeBlend(commandBuffer: postprocessBuffer, warped0: warped0, warped1: warped1, output: blended)

        // RGBA → BGRA
        encodeRgbaToBgra(commandBuffer: postprocessBuffer, source: blended, destination: outputBGRA)

        postprocessBuffer.commit()
        postprocessBuffer.waitUntilCompleted()

        // 7. 从纹理拷贝到 PixelBuffer
        guard let outputBuffer = pool.makeBuffer() else {
            logger.error("从 PixelBufferPool 获取缓冲区失败")
            return nil
        }
        helper.copy(texture: outputBGRA, to: outputBuffer)

        // 8. 缩放到原始尺寸
        if originalWidth == modelInputWidth && originalHeight == modelInputHeight {
            return outputBuffer
        }
        return resize(pixelBuffer: outputBuffer, width: originalWidth, height: originalHeight)
    }

    // MARK: - Metal 编码：预处理
    private func encodePreprocess(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        dstBuffer: MTLBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(preprocessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(dstBuffer, offset: 0, index: 0)

        var width = UInt32(modelInputWidth)
        var height = UInt32(modelInputHeight)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)

        dispatch2D(encoder: encoder, width: modelInputWidth, height: modelInputHeight)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Sigmoid
    private func encodeSigmoid(commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(sigmoidPipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)

        var count = UInt32(modelInputWidth * modelInputHeight)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)

        let threadGroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadGrid = MTLSize(width: (modelInputWidth * modelInputHeight + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadgroup: threadGroup)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Warp
    private func encodeWarp(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        scale: Float,
        channelOffset: UInt32
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(warpPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(flowBuffer, offset: 0, index: 0)

        var width = UInt32(modelInputWidth)
        var height = UInt32(modelInputHeight)
        var s = scale
        var offset = channelOffset
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.setBytes(&s, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&offset, length: MemoryLayout<UInt32>.size, index: 4)

        dispatch2D(encoder: encoder, width: modelInputWidth, height: modelInputHeight)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Blend
    private func encodeBlend(
        commandBuffer: MTLCommandBuffer,
        warped0: MTLTexture,
        warped1: MTLTexture,
        output: MTLTexture
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(blendPipeline)
        encoder.setTexture(warped0, index: 0)
        encoder.setTexture(warped1, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)

        var width = UInt32(modelInputWidth)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)

        dispatch2D(encoder: encoder, width: modelInputWidth, height: modelInputHeight)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：RGBA → BGRA
    private func encodeRgbaToBgra(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(rgbaToBgraPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)

        dispatch2D(encoder: encoder, width: modelInputWidth, height: modelInputHeight)
        encoder.endEncoding()
    }

    // MARK: - 通用 2D 线程组分发
    private func dispatch2D(encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        let threadGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGrid = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadgroup: threadGroup)
    }

    // MARK: - MLMultiArray <-> MTLBuffer
    private func makeMultiArray(from buffer: MTLBuffer, shape: [NSNumber]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: shape, dataType: .float16) else { return nil }
        memcpy(array.dataPointer, buffer.contents(), min(buffer.length, array.count * MemoryLayout<Float16>.size))
        return array
    }

    private func copyToBuffer(multiArray: MLMultiArray, buffer: MTLBuffer) {
        let byteCount = multiArray.count * MemoryLayout<Float16>.size
        memcpy(buffer.contents(), multiArray.dataPointer, min(byteCount, buffer.length))
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

import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

// MARK: - Real-ESRGAN 超分引擎

/// Real-ESRGAN x4v3 超分引擎
/// 4x 放大，128×128 瓦片拼接（带羽化融合），适合极低清素材（480p 及以下）
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 128
    let inputHeight: Int = 128
    let scaleFactor: Int = 4

    // MARK: - 瓦片配置

    /// 瓦片尺寸（输入空间）
    private let tileSize = 128
    /// 瓦片步长（输入空间），重叠 = tileSize - tileStride
    private let tileStride = 96
    /// 边缘羽化宽度（输出空间），用于瓦片拼接时平滑过渡
    private let featherWidth = 16

    // MARK: - 私有属性

    private let model: MLModel
    private let helper = MetalComputeHelper.shared
    private let commandQueue: MTLCommandQueue
    private let preprocessPipeline: MTLComputePipelineState

    /// 预分配单瓦片输入 MTLBuffer（128×128×3×Float16）
    private let tileInputBuffer: MTLBuffer

    /// 取消标志
    private var isCancelledFlag = false

    // MARK: - 初始化

    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
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

        // 3. 预分配瓦片输入 MTLBuffer
        let plane = tileSize * tileSize
        let inputBytes = plane * 3 * MemoryLayout<Float16>.size
        guard let buffer = helper.device.makeBuffer(length: inputBytes, options: .storageModeShared) else {
            return nil
        }
        self.tileInputBuffer = buffer

        logger.info("RealESRGAN 引擎初始化成功，瓦片: \(self.tileSize)x\(self.tileSize)，步长: \(self.tileStride)，放大: \(self.scaleFactor)x")
    }

    // MARK: - 公开方法

    /// 对单帧执行 4x 超分（瓦片拼接）
    /// - Parameter pixelBuffer: 输入帧（32BGRA）
    /// - Returns: 4x 放大后的 32BGRA 帧，失败返回 nil
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let outputWidth = srcWidth * scaleFactor
        let outputHeight = srcHeight * scaleFactor
        let pixelCount = outputWidth * outputHeight

        // 1. Float 累加器（3通道 + 权重）
        var accumR = [Float](repeating: 0, count: pixelCount)
        var accumG = [Float](repeating: 0, count: pixelCount)
        var accumB = [Float](repeating: 0, count: pixelCount)
        var accumW = [Float](repeating: 0, count: pixelCount)

        // 2. 计算瓦片网格
        let cols = max((srcWidth - tileSize + tileStride - 1) / tileStride + 1, 1)
        let rows = max((srcHeight - tileSize + tileStride - 1) / tileStride + 1, 1)
        let outputTileSize = tileSize * scaleFactor

        // 3. 逐瓦片推理并累加
        for row in 0..<rows {
            for col in 0..<cols {
                if isCancelledFlag { return nil }

                let srcX = min(col * tileStride, max(srcWidth - tileSize, 0))
                let srcY = min(row * tileStride, max(srcHeight - tileSize, 0))

                // 提取瓦片
                guard let tile = extractTile(from: pixelBuffer, x: srcX, y: srcY, width: tileSize, height: tileSize) else {
                    logger.error("提取瓦片失败 (\(col),\(row))")
                    continue
                }

                // 推理瓦片
                guard let upscaledTile = processTile(tile) else {
                    logger.error("瓦片推理失败 (\(col),\(row))")
                    continue
                }

                // 累加到 Float 缓冲区（带羽化权重）
                let dstX = srcX * scaleFactor
                let dstY = srcY * scaleFactor
                accumulateTile(
                    upscaledTile,
                    accumR: &accumR,
                    accumG: &accumG,
                    accumB: &accumB,
                    accumW: &accumW,
                    dstX: dstX,
                    dstY: dstY,
                    tileSize: outputTileSize,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            }
        }

        // 4. 归一化并创建输出 CVPixelBuffer
        guard let outputBuffer = createOutputBuffer(
            width: outputWidth,
            height: outputHeight,
            accumR: &accumR,
            accumG: &accumG,
            accumB: &accumB,
            accumW: &accumW
        ) else {
            logger.error("创建输出缓冲区失败")
            return nil
        }

        // 5. 复制颜色空间附件
        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)

        return outputBuffer
    }

    /// 取消处理
    func cancel() { isCancelledFlag = true }

    // MARK: - 单瓦片处理

    private func processTile(_ tile: CVPixelBuffer) -> CVPixelBuffer? {
        // 1. Metal 预处理：BGRA → NCHW Float16
        guard let tileTexture = helper.makeIOSurfaceTexture(from: tile, usage: .shaderRead),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        encodePreprocess(commandBuffer: commandBuffer, source: tileTexture)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 2. 创建 MLMultiArray
        let shape: [NSNumber] = [1, 3, NSNumber(value: tileSize), NSNumber(value: tileSize)]
        guard let inputArray = try? MLMultiArray(shape: shape, dataType: .float16) else {
            return nil
        }
        memcpy(inputArray.dataPointer, tileInputBuffer.contents(), tileInputBuffer.length)

        // 3. Core ML 推理
        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "output")?.multiArrayValue else {
            return nil
        }

        // 4. NCHW Float16 → BGRA（带 Clamp，Real-ESRGAN GAN 输出会超出 [0,1]）
        let outTileSize = tileSize * scaleFactor
        return makeTilePixelBuffer(from: outputArray, width: outTileSize, height: outTileSize)
    }

    // MARK: - Metal 预处理编码

    private func encodePreprocess(commandBuffer: MTLCommandBuffer, source: MTLTexture) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(preprocessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(tileInputBuffer, offset: 0, index: 0)

        var width = UInt32(tileSize)
        var height = UInt32(tileSize)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)

        let threadGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGrid = MTLSize(
            width: (tileSize + 15) / 16,
            height: (tileSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadGroup: threadGroup)
        encoder.endEncoding()
    }

    // MARK: - 瓦片提取

    private func extractTile(from source: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) -> CVPixelBuffer? {
        var tileBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &tileBuffer) == kCVReturnSuccess,
              let tile = tileBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(tile, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(tile, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(tile) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(tile)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        for row in 0..<height {
            let srcOffset = (y + row) * srcBytesPerRow + x * 4
            let dstOffset = row * dstBytesPerRow
            memcpy(dst.advanced(by: dstOffset), src.advanced(by: srcOffset), width * 4)
        }

        return tile
    }

    // MARK: - 瓦片输出转换（NCHW Float16 → BGRA，带 Clamp）

    private func makeTilePixelBuffer(from array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
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
        let srcPtr = array.dataPointer.assumingMemoryBound(to: Float16.self)

        for y in 0..<height {
            let rowOffset = y * dstBytesPerRow
            for x in 0..<width {
                let idx = y * width + x
                let r = clampFloat16ToUInt8(srcPtr[0 * plane + idx])
                let g = clampFloat16ToUInt8(srcPtr[1 * plane + idx])
                let b = clampFloat16ToUInt8(srcPtr[2 * plane + idx])
                let pixelOffset = rowOffset + x * 4
                dst[pixelOffset + 0] = b
                dst[pixelOffset + 1] = g
                dst[pixelOffset + 2] = r
                dst[pixelOffset + 3] = 255
            }
        }

        return result
    }

    // MARK: - 瓦片累加（Float 累加器，带羽化权重）

    private func accumulateTile(
        _ tile: CVPixelBuffer,
        accumR: inout [Float],
        accumG: inout [Float],
        accumB: inout [Float],
        accumW: inout [Float],
        dstX: Int,
        dstY: Int,
        tileSize: Int,
        outputWidth: Int,
        outputHeight: Int
    ) {
        CVPixelBufferLockBaseAddress(tile, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }

        guard let tileBase = CVPixelBufferGetBaseAddress(tile) else { return }
        let tilePtr = tileBase.assumingMemoryBound(to: UInt8.self)
        let tileBytesPerRow = CVPixelBufferGetBytesPerRow(tile)

        for ty in 0..<tileSize {
            let outY = dstY + ty
            guard outY >= 0 && outY < outputHeight else { continue }
            let yWeight = featherWeight(position: ty, size: tileSize)

            for tx in 0..<tileSize {
                let outX = dstX + tx
                guard outX >= 0 && outX < outputWidth else { continue }

                let xWeight = featherWeight(position: tx, size: tileSize)
                let weight = xWeight * yWeight
                guard weight > 0 else { continue }

                let tileIdx = ty * tileBytesPerRow + tx * 4
                let outIdx = outY * outputWidth + outX

                accumB[outIdx] += Float(tilePtr[tileIdx + 0]) * weight
                accumG[outIdx] += Float(tilePtr[tileIdx + 1]) * weight
                accumR[outIdx] += Float(tilePtr[tileIdx + 2]) * weight
                accumW[outIdx] += weight
            }
        }
    }

    /// 计算边缘羽化权重（0~1），中心区域为1，边缘线性衰减
    private func featherWeight(position: Int, size: Int) -> Float {
        let fw = featherWidth
        if position < fw {
            return Float(position + 1) / Float(fw + 1)
        } else if position >= size - fw {
            return Float(size - position) / Float(fw + 1)
        } else {
            return 1.0
        }
    }

    // MARK: - 创建输出缓冲区（归一化 Float 累加器 → BGRA）

    private func createOutputBuffer(
        width: Int,
        height: Int,
        accumR: inout [Float],
        accumG: inout [Float],
        accumB: inout [Float],
        accumW: inout [Float]
    ) -> CVPixelBuffer? {
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

        for y in 0..<height {
            let rowOffset = y * dstBytesPerRow
            for x in 0..<width {
                let idx = y * width + x
                let w = accumW[idx]
                let pixelOffset = rowOffset + x * 4

                if w > 0 {
                    let b = accumB[idx] / w
                    let g = accumG[idx] / w
                    let r = accumR[idx] / w
                    dst[pixelOffset + 0] = UInt8(max(0, min(255, Int(b.rounded()))))
                    dst[pixelOffset + 1] = UInt8(max(0, min(255, Int(g.rounded()))))
                    dst[pixelOffset + 2] = UInt8(max(0, min(255, Int(r.rounded()))))
                } else {
                    dst[pixelOffset + 0] = 0
                    dst[pixelOffset + 1] = 0
                    dst[pixelOffset + 2] = 0
                }
                dst[pixelOffset + 3] = 255
            }
        }

        return result
    }

    // MARK: - 工具方法

    /// 将 Float16 值钳制到 [0,1] 并转换为 UInt8 [0,255]
    private func clampFloat16ToUInt8(_ value: Float16) -> UInt8 {
        let f = Float(value)
        let clamped = max(0.0, min(1.0, f))
        return UInt8(clamped * 255.0)
    }

    /// 颜色空间附件复制
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

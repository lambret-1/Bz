import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

// MARK: - Real-ESRGAN 超分引擎

/// Real-ESRGAN x4 超分引擎
/// 4x 放大，512×512 瓦片拼接（带羽化融合），适合极低清素材（480p 及以下）
/// 使用 Core ML image 类型输入输出，自动处理颜色空间转换
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 512
    let inputHeight: Int = 512
    let scaleFactor: Int = 4

    // MARK: - 瓦片配置

    /// 瓦片尺寸（输入空间）
    private let tileSize = 512
    /// 瓦片步长（输入空间），重叠 = tileSize - tileStride
    private let tileStride = 384
    /// 边缘羽化宽度（输出空间），用于瓦片拼接时平滑过渡
    private let featherWidth = 64

    // MARK: - 私有属性

    private let model: MLModel
    private let helper = MetalComputeHelper.shared

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

                // 提取瓦片（512x512）
                guard let tile = extractTile(from: pixelBuffer, x: srcX, y: srcY, width: tileSize, height: tileSize) else {
                    logger.error("提取瓦片失败 (\(col),\(row))")
                    continue
                }

                // 推理瓦片（使用 image 类型输入输出）
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

    // MARK: - 单瓦片处理（Core ML image 类型）

    private func processTile(_ tile: CVPixelBuffer) -> CVPixelBuffer? {
        // 使用 CVPixelBuffer 作为 image 类型输入，Core ML 自动处理颜色空间转换
        guard let inputFeature = try? MLDictionaryFeatureProvider(dictionary: [
            "input": MLFeatureValue(pixelBuffer: tile)
        ]), let prediction = try? model.prediction(from: inputFeature),
              let outputPixelBuffer = prediction.featureValue(for: "activation_out")?.imageBufferValue else {
            logger.error("Core ML 推理失败或输出类型错误")
            return nil
        }

        // 输出是 2048x2048 BGRA CVPixelBuffer，直接深拷贝返回
        return deepCopyPixelBuffer(outputPixelBuffer)
    }

    // MARK: - CVPixelBuffer 深拷贝

    private func deepCopyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var resultBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs, &resultBuffer) == kCVReturnSuccess,
              let result = resultBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        guard let srcAddr = CVPixelBufferGetBaseAddress(source),
              let dstAddr = CVPixelBufferGetBaseAddress(result) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let bytesPerRow = min(srcBytesPerRow, dstBytesPerRow)

        for row in 0..<height {
            memcpy(dstAddr.advanced(by: row * dstBytesPerRow),
                   srcAddr.advanced(by: row * srcBytesPerRow),
                   bytesPerRow)
        }

        return result
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
                    // Real-ESRGAN GAN 输出需 Clamp，累加归一化后钳制到 [0,255]
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

import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - Real-ESRGAN x4v3 轻量版超分引擎（ImageType零拷贝版）

/// Real-ESRGAN General-x4v3 轻量版 4x 超分引擎
/// ImageType 输入输出：直接喂 CVPixelBuffer，零拷贝，消除 MLMultiArray 转换开销
/// 128×128 瓦片拼接（带羽化融合），适合极低清素材（480p 及以下）
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 128
    let inputHeight: Int = 128
    let scaleFactor: Int = 4

    // MARK: - 瓦片配置

    /// 瓦片步长（输入空间），重叠 = tileSize - tileStride
    private let tileStride = 96
    /// 边缘羽化宽度（输出空间），用于瓦片拼接时平滑过渡
    private let featherWidth = 32

    // MARK: - 私有属性

    private let model: MLModel
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

        logger.info("RealESRGAN x4v3 ImageType引擎初始化成功，瓦片: \(self.inputWidth)x\(self.inputHeight)，步长: \(self.tileStride)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 4x 超分（128×128 瓦片拼接，ImageType零拷贝）
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
        let cols = max((srcWidth - inputWidth + tileStride - 1) / tileStride + 1, 1)
        let rows = max((srcHeight - inputHeight + tileStride - 1) / tileStride + 1, 1)
        let outputTileSize = inputWidth * scaleFactor

        // 3. 逐瓦片推理并累加（ImageType零拷贝）
        for row in 0..<rows {
            for col in 0..<cols {
                if isCancelledFlag { return nil }

                let srcX = min(col * tileStride, max(srcWidth - inputWidth, 0))
                let srcY = min(row * tileStride, max(srcHeight - inputHeight, 0))

                // 从原帧裁剪128x128瓦片
                guard let tileBuffer = cropPixelBuffer(pixelBuffer, x: srcX, y: srcY, width: inputWidth, height: inputHeight) else {
                    logger.error("瓦片裁剪失败 (\(col),\(row))")
                    continue
                }

                // ImageType零拷贝推理
                guard let outputBuffer = predictTile(tileBuffer) else {
                    logger.error("瓦片推理失败 (\(col),\(row))")
                    continue
                }

                // 累加到 Float 缓冲区（带羽化权重）
                let dstX = srcX * scaleFactor
                let dstY = srcY * scaleFactor
                accumulateOutputBuffer(
                    outputBuffer,
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

    // MARK: - 瓦片裁剪（从原帧裁剪指定区域为新的CVPixelBuffer）

    private func cropPixelBuffer(_ source: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) -> CVPixelBuffer? {
        var croppedBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(source), attrs, &croppedBuffer) == kCVReturnSuccess,
              let cropped = croppedBuffer else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(cropped, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(cropped, [])
        }

        guard let srcAddr = CVPixelBufferGetBaseAddress(source),
              let dstAddr = CVPixelBufferGetBaseAddress(cropped) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(cropped)
        let srcStart = srcAddr.advanced(by: y * srcBytesPerRow + x * 4)

        // 逐行拷贝（处理stride差异）
        for row in 0..<height {
            memcpy(dstAddr.advanced(by: row * dstBytesPerRow),
                   srcStart.advanced(by: row * srcBytesPerRow),
                   min(width * 4, dstBytesPerRow))
        }

        return cropped
    }

    // MARK: - 单瓦片推理（ImageType零拷贝）

    private func predictTile(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let inputFeature = MLFeatureValue(pixelBuffer: inputBuffer)
        guard let inputProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputFeature]),
              let prediction = try? model.prediction(from: inputProvider),
              let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue else {
            return nil
        }
        return outputBuffer
    }

    // MARK: - 瓦片累加（从输出CVPixelBuffer读取BGRA，带羽化权重）

    private func accumulateOutputBuffer(
        _ outputBuffer: CVPixelBuffer,
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
        guard CVPixelBufferLockBaseAddress(outputBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }

        guard let srcAddr = CVPixelBufferGetBaseAddress(outputBuffer) else { return }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let src = srcAddr.assumingMemoryBound(to: UInt8.self)

        for ty in 0..<tileSize {
            for tx in 0..<tileSize {
                let outY = dstY + ty
                let outX = dstX + tx
                guard outY >= 0 && outY < outputHeight && outX >= 0 && outX < outputWidth else { continue }

                let yWeight = featherWeight(position: ty, size: tileSize)
                let xWeight = featherWeight(position: tx, size: tileSize)
                let weight = xWeight * yWeight
                guard weight > 0 else { continue }

                let srcOffset = ty * srcBytesPerRow + tx * 4
                let outIdx = outY * outputWidth + outX

                // BGRA → RGB
                accumR[outIdx] += Float(src[srcOffset + 2]) * weight
                accumG[outIdx] += Float(src[srcOffset + 1]) * weight
                accumB[outIdx] += Float(src[srcOffset + 0]) * weight
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
                    // GAN 输出需 Clamp，累加归一化后钳制到 [0,255]
                    let b = accumB[idx] / w
                    let g = accumG[idx] / w
                    let r = accumR[idx] / w
                    dst[pixelOffset + 0] = UInt8(max(0, min(255, Int((b * 255).rounded()))))
                    dst[pixelOffset + 1] = UInt8(max(0, min(255, Int((g * 255).rounded()))))
                    dst[pixelOffset + 2] = UInt8(max(0, min(255, Int((r * 255).rounded()))))
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

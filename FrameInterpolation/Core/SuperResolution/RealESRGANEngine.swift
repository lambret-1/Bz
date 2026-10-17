import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - Real-ESRGAN x4v3 轻量版超分引擎（单线程稳定版+computeUnits可切换）

/// Real-ESRGAN General-x4v3 轻量版 4x 超分引擎
/// 单线程串行推理（避免ANE多线程竞争和瓦片缓冲区数据竞争）
/// 支持通过 computeUnits 切换 .all / .cpuAndGPU 验证ANE回退问题
final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 128
    let inputHeight: Int = 128
    let scaleFactor: Int = 4

    // MARK: - 瓦片配置

    private let tileStride = 96
    private let featherWidth = 32

    // MARK: - 私有属性

    private let model: MLModel
    private var isCancelledFlag = false
    /// 复用的瓦片输入缓冲区
    private var reusableTileBuffer: CVPixelBuffer?

    // MARK: - 初始化

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            return nil
        }

        let config = MLModelConfiguration()
        // 默认使用CPU+GPU，避开ANE↔CPU跨芯片搬运（PixelShuffle→depth_to_space回退）
        config.computeUnits = .cpuAndGPU
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            return nil
        }
        self.model = model

        reusableTileBuffer = createTileBuffer(width: inputWidth, height: inputHeight)

        logger.info("RealESRGAN x4v3 引擎初始化成功（computeUnits: cpuAndGPU）")
    }

    // MARK: - 公开方法

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let outputWidth = srcWidth * scaleFactor
        let outputHeight = srcHeight * scaleFactor
        let pixelCount = outputWidth * outputHeight

        var accumR = [Float](repeating: 0, count: pixelCount)
        var accumG = [Float](repeating: 0, count: pixelCount)
        var accumB = [Float](repeating: 0, count: pixelCount)
        var accumW = [Float](repeating: 0, count: pixelCount)

        let cols = max((srcWidth - inputWidth + tileStride - 1) / tileStride + 1, 1)
        let rows = max((srcHeight - inputHeight + tileStride - 1) / tileStride + 1, 1)
        let outputTileSize = inputWidth * scaleFactor

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        for row in 0..<rows {
            for col in 0..<cols {
                if isCancelledFlag { return nil }

                let srcX = min(col * tileStride, max(srcWidth - inputWidth, 0))
                let srcY = min(row * tileStride, max(srcHeight - inputHeight, 0))

                autoreleasepool {
                    guard let tileBuffer = reusableTileBuffer else { return }
                    fillTileBuffer(tileBuffer, from: src, srcBytesPerRow: srcBytesPerRow, x: srcX, y: srcY)

                    guard let outputBuffer = predictTile(tileBuffer) else { return }

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
        }

        guard let outputBuffer = createOutputBuffer(
            width: outputWidth,
            height: outputHeight,
            accumR: &accumR,
            accumG: &accumG,
            accumB: &accumB,
            accumW: &accumW
        ) else {
            return nil
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)
        return outputBuffer
    }

    func cancel() { isCancelledFlag = true }

    // MARK: - 瓦片缓冲区创建与填充

    private func createTileBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func fillTileBuffer(_ tile: CVPixelBuffer, from src: UnsafePointer<UInt8>, srcBytesPerRow: Int, x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(tile, [])
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(tile) else { return }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(tile)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        let srcStart = src.advanced(by: y * srcBytesPerRow + x * 4)

        for row in 0..<inputHeight {
            memcpy(dst.advanced(by: row * dstBytesPerRow),
                   srcStart.advanced(by: row * srcBytesPerRow),
                   min(inputWidth * 4, dstBytesPerRow))
        }
    }

    // MARK: - 单瓦片推理

    private func predictTile(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let inputFeature = MLFeatureValue(pixelBuffer: inputBuffer)
        guard let inputProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputFeature]),
              let prediction = try? model.prediction(from: inputProvider),
              let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue else {
            return nil
        }
        return outputBuffer
    }

    // MARK: - 瓦片累加

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

                accumR[outIdx] += Float(src[srcOffset + 2]) / 255.0 * weight
                accumG[outIdx] += Float(src[srcOffset + 1]) / 255.0 * weight
                accumB[outIdx] += Float(src[srcOffset + 0]) / 255.0 * weight
                accumW[outIdx] += weight
            }
        }
    }

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

    // MARK: - 创建输出缓冲区

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

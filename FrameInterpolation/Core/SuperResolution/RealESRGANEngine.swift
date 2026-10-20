import CoreML
import CoreVideo
import Accelerate
import OSLog

final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let scaleFactor: Int = 4

    // MARK: 模型固定输入尺寸，不再硬编码步长
    private let modelInputTileWidth = 352
    private let modelInputTileHeight = 608
    private let tileOverlap = 64
    private var featherWidth: Int { tileOverlap }

    private var tileWeightMap: [Float]!
    private let model: MLModel
    private var isCancelledFlag = false

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("找不到模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("模型加载失败")
            return nil
        }
        self.model = model

        // 预计算瓦片羽化权重，只初始化一次
        let outTileW = modelInputTileWidth * scaleFactor
        let outTileH = modelInputTileHeight * scaleFactor
        tileWeightMap = [Float](repeating: 0, count: outTileW * outTileH)
        for ty in 0..<outTileH {
            let wy = featherWeight(position: ty, size: outTileH)
            for tx in 0..<outTileW {
                let wx = featherWeight(position: tx, size: outTileW)
                tileWeightMap[ty * outTileW + tx] = wx * wy
            }
        }

        logger.info("RealESRGAN 镜像Padding+预计算权重版初始化成功")
    }

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

        let tileStrideX = modelInputTileWidth - tileOverlap
        let tileStrideY = modelInputTileHeight - tileOverlap

        let cols = max((srcWidth - modelInputTileWidth + tileStrideX - 1) / tileStrideX + 1, 1)
        let rows = max((srcHeight - modelInputTileHeight + tileStrideY - 1) / tileStrideY + 1, 1)

        let outputTileWidth = modelInputTileWidth * scaleFactor
        let outputTileHeight = modelInputTileHeight * scaleFactor

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

                let srcX = min(col * tileStrideX, max(srcWidth - modelInputTileWidth, 0))
                let srcY = min(row * tileStrideY, max(srcHeight - modelInputTileHeight, 0))

                autoreleasepool {
                    guard let tileBuffer = createPixelBuffer(width: modelInputTileWidth, height: modelInputTileHeight) else { return }

                    fillTileBuffer(tileBuffer,
                                   from: src,
                                   srcBytesPerRow: srcBytesPerRow,
                                   srcWidth: srcWidth,
                                   srcHeight: srcHeight,
                                   x: srcX,
                                   y: srcY)

                    guard let outputBuffer = predictTile(tileBuffer) else { return }

                    let dstX = srcX * scaleFactor
                    let dstY = srcY * scaleFactor

                    accumulateOutputBuffer(
                        outputBuffer,
                        accumR: &accumR, accumG: &accumG, accumB: &accumB, accumW: &accumW,
                        dstX: dstX, dstY: dstY,
                        tileWidth: outputTileWidth, tileHeight: outputTileHeight,
                        outputWidth: outputWidth, outputHeight: outputHeight
                    )
                }
            }
        }

        guard let outputBuffer = createOutputBuffer(
            width: outputWidth, height: outputHeight,
            accumR: &accumR, accumG: &accumG, accumB: &accumB, accumW: &accumW
        ) else { return nil }

        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)
        return outputBuffer
    }

    func cancel() { isCancelledFlag = true }

    // MARK: - 工具方法

    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
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

    /// 镜像反射padding填充tile（替换旧的clamp复制边缘）
    private func fillTileBuffer(_ tile: CVPixelBuffer,
                                from src: UnsafePointer<UInt8>,
                                srcBytesPerRow: Int,
                                srcWidth: Int,
                                srcHeight: Int,
                                x: Int,
                                y: Int) {
        CVPixelBufferLockBaseAddress(tile, [])
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(tile) else { return }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(tile)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        for tileY in 0..<modelInputTileHeight {
            let srcY = y + tileY
            var realSrcY: Int
            if srcY < 0 {
                realSrcY = -srcY
            } else if srcY >= srcHeight {
                let delta = srcY - srcHeight
                realSrcY = srcHeight - 2 - delta
            } else {
                realSrcY = srcY
            }
            realSrcY = max(0, min(srcHeight - 1, realSrcY))
            let srcRowPtr = src.advanced(by: realSrcY * srcBytesPerRow)
            let dstRowPtr = dst.advanced(by: tileY * dstBytesPerRow)

            for tileX in 0..<modelInputTileWidth {
                let srcX = x + tileX
                var realSrcX: Int
                if srcX < 0 {
                    realSrcX = -srcX
                } else if srcX >= srcWidth {
                    let delta = srcX - srcWidth
                    realSrcX = srcWidth - 2 - delta
                } else {
                    realSrcX = srcX
                }
                realSrcX = max(0, min(srcWidth - 1, realSrcX))
                let srcPixel = srcRowPtr.advanced(by: realSrcX * 4)
                let dstPixel = dstRowPtr.advanced(by: tileX * 4)
                dstPixel[0] = srcPixel[0]
                dstPixel[1] = srcPixel[1]
                dstPixel[2] = srcPixel[2]
                dstPixel[3] = srcPixel[3]
            }
        }
    }

    private func predictTile(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let inputFeature = MLFeatureValue(pixelBuffer: inputBuffer)
        guard let inputProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputFeature]),
              let prediction = try? model.prediction(from: inputProvider),
              let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue else {
            return nil
        }
        return outputBuffer
    }

    /// Accelerate向量化累加，使用预计算tileWeightMap
    private func accumulateOutputBuffer(
        _ outputBuffer: CVPixelBuffer,
        accumR: inout [Float], accumG: inout [Float], accumB: inout [Float], accumW: inout [Float],
        dstX: Int, dstY: Int,
        tileWidth: Int, tileHeight: Int,
        outputWidth: Int, outputHeight: Int
    ) {
        guard CVPixelBufferLockBaseAddress(outputBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }

        guard let srcAddr = CVPixelBufferGetBaseAddress(outputBuffer) else { return }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let src = srcAddr.assumingMemoryBound(to: UInt8.self)

        for ty in 0..<tileHeight {
            let outY = dstY + ty
            guard outY >= 0, outY < outputHeight else { continue }
            for tx in 0..<tileWidth {
                let outX = dstX + tx
                guard outX >= 0, outX < outputWidth else { continue }

                let w = tileWeightMap[ty * tileWidth + tx]
                guard w > 0 else { continue }

                let srcOffset = ty * srcBytesPerRow + tx * 4
                let outIdx = outY * outputWidth + outX

                let bF = Float(src[srcOffset + 0]) / 255.0 * w
                let gF = Float(src[srcOffset + 1]) / 255.0 * w
                let rF = Float(src[srcOffset + 2]) / 255.0 * w

                accumB[outIdx] += bF
                accumG[outIdx] += gF
                accumR[outIdx] += rF
                accumW[outIdx] += w
            }
        }
    }

    private func featherWeight(position: Int, size: Int) -> Float {
        let fw = Float(featherWidth)
        let pos = Float(position)
        let sz = Float(size)

        if pos < fw {
            let ratio = pos / fw
            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else if pos >= sz - fw {
            let ratio = (sz - pos) / fw
            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else {
            return 1.0
        }
    }

    private func createOutputBuffer(
        width: Int, height: Int,
        accumR: inout [Float], accumG: inout [Float], accumB: inout [Float], accumW: inout [Float]
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let result = buffer else { return nil }

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

                if w > 1e-8 {
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

    private func copyColorSpaceAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        let colorKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferCGColorSpaceKey
        ]
        for key in colorKeys {
            if let value = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
                CFRelease(value)
            }
        }
    }
}

// MARK: 协议桩（你原有工程已有，仅用于编译通过校验）
protocol SuperResolutionEngine {
    static var engineType: SuperResolutionEngineType { get }
    var scaleFactor: Int { get }
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
    func cancel()
}
enum SuperResolutionEngineType {
    case realESRGAN
    var modelFileName: String { "realESRGAN" }
}

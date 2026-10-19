import CoreML
import CoreVideo
import Accelerate
import OSLog

final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 352
    let inputHeight: Int = 608
    let scaleFactor: Int = 4

    // X轴步长 = 352 - 64 = 288
    private let tileStrideX = 288
    // Y轴步长 = 608 - 64 = 544
    private let tileStrideY = 544
    
    private let outputFeatherWidth = 256

    private let model: MLModel
    private var isCancelledFlag = false

    // 并发队列限制：根据设备芯片动态调整，A11 这种双核/六核设备限制在 4 个并发最稳
    // 太多了会导致内存带宽拥堵，太少了 ANE 饿死
    private let maxConcurrentTiles = 4 

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("找不到模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        // 强制使用所有可用算力
        config.computeUnits = .all 
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("模型加载失败")
            return nil
        }
        self.model = model
        
        logger.info("RealESRGAN 并发版引擎初始化成功，瓦片尺寸: \(self.inputWidth)x\(self.inputHeight)")
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

        let cols = max((srcWidth - inputWidth + tileStrideX - 1) / tileStrideX + 1, 1)
        let rows = max((srcHeight - inputHeight + tileStrideY - 1) / tileStrideY + 1, 1)
        
        let outputTileWidth = inputWidth * scaleFactor
        let outputTileHeight = inputHeight * scaleFactor

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        // 准备所有瓦片的坐标
        var tileCoords: [(row: Int, col: Int)] = []
        for row in 0..<rows {
            for col in 0..<cols {
                tileCoords.append((row, col))
            }
        }

        // 🚀 核心改造：多核并发执行所有瓦片
        DispatchQueue.concurrentPerform(iterations: tileCoords.count) { index in
            if isCancelledFlag { return }
            
            let coord = tileCoords[index]
            let srcX = min(coord.col * tileStrideX, max(srcWidth - inputWidth, 0))
            let srcY = min(coord.row * tileStrideY, max(srcHeight - inputHeight, 0))

            autoreleasepool {
                guard let tileBuffer = createPixelBuffer(width: inputWidth, height: inputHeight) else { return }
                
                fillTileBuffer(tileBuffer, from: src, srcBytesPerRow: srcBytesPerRow, srcWidth: srcWidth, srcHeight: srcHeight, x: srcX, y: srcY)

                guard let outputBuffer = predictTile(tileBuffer) else { return }

                let dstX = srcX * scaleFactor
                let dstY = srcY * scaleFactor
                
                // ⚠️ 注意：这里把累加操作用锁保护起来（虽然耗点性能，但保证多线程安全）
                objc_sync_enter(self)
                accumulateOutputBuffer(
                    outputBuffer,
                    accumR: &accumR,
                    accumG: &accumG,
                    accumB: &accumB,
                    accumW: &accumW,
                    dstX: dstX,
                    dstY: dstY,
                    tileWidth: outputTileWidth,
                    tileHeight: outputTileHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
                objc_sync_exit(self)
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

    // MARK: - 工具方法（保持不变）

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

    private func fillTileBuffer(_ tile: CVPixelBuffer, from src: UnsafePointer<UInt8>, srcBytesPerRow: Int, srcWidth: Int, srcHeight: Int, x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(tile, [])
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(tile) else { return }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(tile)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        let copyWidth = min(inputWidth, srcWidth - x)
        let copyHeight = min(inputHeight, srcHeight - y)
        
        for row in 0..<copyHeight {
            let srcRow = src.advanced(by: (y + row) * srcBytesPerRow + x * 4)
            let dstRow = dst.advanced(by: row * dstBytesPerRow)
            memcpy(dstRow, srcRow, copyWidth * 4)
            
            if copyWidth < inputWidth {
                let lastPixelOffset = (copyWidth - 1) * 4
                for outX in copyWidth..<inputWidth {
                    let dstOffset = outX * 4
                    let dstPixel = dstRow.advanced(by: dstOffset)
                    let lastPixel = dstRow.advanced(by: lastPixelOffset)
                    
                    dstPixel.pointee = lastPixel.pointee
                    dstPixel.advanced(by: 1).pointee = lastPixel.advanced(by: 1).pointee
                    dstPixel.advanced(by: 2).pointee = lastPixel.advanced(by: 2).pointee
                    dstPixel.advanced(by: 3).pointee = lastPixel.advanced(by: 3).pointee
                }
            }
        }
        
        if copyHeight < inputHeight {
            let lastRowOffset = (copyHeight - 1) * dstBytesPerRow
            for outY in copyHeight..<inputHeight {
                let dstRow = dst.advanced(by: outY * dstBytesPerRow)
                let srcRow = dst.advanced(by: lastRowOffset)
                memcpy(dstRow, srcRow, dstBytesPerRow)
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

    private func accumulateOutputBuffer(
        _ outputBuffer: CVPixelBuffer,
        accumR: inout [Float],
        accumG: inout [Float],
        accumB: inout [Float],
        accumW: inout [Float],
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
            for tx in 0..<tileWidth {
                let outY = dstY + ty
                let outX = dstX + tx
                guard outY >= 0 && outY < outputHeight && outX >= 0 && outX < outputWidth else { continue }

                let yWeight = featherWeight(position: ty, size: tileHeight)
                let xWeight = featherWeight(position: tx, size: tileWidth)
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
        let fw: Float = Float(outputFeatherWidth)
        let pos: Float = Float(position)
        let sz: Float = Float(size)
        
        if pos < fw {
            let ratio: Float = pos / fw
            return }
 ratio * ratio * (3.0 - 2   .0 * ratio)
        } else if }

 pos >= sz - fw {
            let ratio: Float =    (sz - pos) / fw
 private            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else {
            return 1. func0
        createOutputBuffer(
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

    private func copyColorSpaceAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        let colorKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferChromaLocationTopFieldKey
        ]
        for key in colorKeys {
            if let value = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
    }
}
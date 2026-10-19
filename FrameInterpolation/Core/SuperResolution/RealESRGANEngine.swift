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

    private let tileStrideX = 288
    private let tileStrideY = 544
    private let outputFeatherWidth = 256

    private let model: MLModel
    private var isCancelledFlag = false

    // 针对 iPhone 14 优化：使用内存池
    private var inputPool: CVPixelBufferPool?
    
    // 获取设备真正的物理核心数（A15/A16 通常是 6 核）
    private let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("找不到模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        // 针对 A15/A16，全部砸给 ANE 和 GPU
        config.computeUnits = .all 
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("模型加载失败")
            return nil
        }
        self.model = model
        
        // 初始化内存池
        setupInputPool()
        
        logger.info("RealESRGAN 极限性能版初始化成功，并发线程数: \(self.maxConcurrency)")
    }

    private func setupInputPool() {
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: maxConcurrency + 4] as CFDictionary
        let bufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: inputWidth,
            kCVPixelBufferHeightKey: inputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        CVPixelBufferPoolCreate(nil, poolAttributes, bufferAttributes, &inputPool)
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let outputWidth = srcWidth * scaleFactor
        let outputHeight = srcHeight * scaleFactor
        let pixelCount = outputWidth * outputHeight

        // 使用 UnsafeMutablePointer 避免 Swift Array 的并发独占检查
        let accumR = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let accumG = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let accumB = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let accumW = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        
        accumR.initialize(repeating: 0, count: pixelCount)
        accumG.initialize(repeating: 0, count: pixelCount)
        accumB.initialize(repeating: 0, count: pixelCount)
        accumW.initialize(repeating: 0, count: pixelCount)
        
        defer {
            accumR.deallocate()
            accumG.deallocate()
            accumB.deallocate()
            accumW.deallocate()
        }

        let cols = max((srcWidth - inputWidth + tileStrideX - 1) / tileStrideX + 1, 1)
        let rows = max((srcHeight - inputHeight + tileStrideY - 1) / tileStrideY + 1, 1)
        
        let outputTileWidth = inputWidth * scaleFactor
        let outputTileHeight = inputHeight * scaleFactor

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        // 将任务拆分为按行并发，限制并发数，防止线程爆炸
        let semaphore = DispatchSemaphore(value: maxConcurrency)
        let group = DispatchGroup()

        for row in 0..<rows {
            group.enter()
            semaphore.wait()
            
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                
                for col in 0..<cols {
                    if self.isCancelledFlag { return }
                    
                    let srcX = min(col * self.tileStrideX, max(srcWidth - self.inputWidth, 0))
                    let srcY = min(row * self.tileStrideY, max(srcHeight - self.inputHeight, 0))

                    autoreleasepool {
                        guard let tileBuffer = self.createPixelBufferFromPool() else { return }
                        
                        self.fillTileBuffer(tileBuffer, from: src, srcBytesPerRow: srcBytesPerRow, srcWidth: srcWidth, srcHeight: srcHeight, x: srcX, y: srcY)

                        guard let outputBuffer = self.predictTile(tileBuffer) else { return }

                        let dstX = srcX * self.scaleFactor
                        let dstY = srcY * self.scaleFactor
                        
                        self.accumulateOutputBuffer(
                            outputBuffer,
                            accumR: accumR, accumG: accumG, accumB: accumB, accumW: accumW,
                            dstX: dstX, dstY: dstY,
                            tileWidth: outputTileWidth, tileHeight: outputTileHeight,
                            outputWidth: outputWidth, outputHeight: outputHeight
                        )
                    }
                }
            }
        }

        group.wait()

        guard let outputBuffer = createOutputBuffer(
            width: outputWidth, height: outputHeight,
            accumR: accumR, accumG: accumG, accumB: accumB, accumW: accumW
        ) else { return nil }

        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)
        return outputBuffer
    }

    func cancel() { isCancelledFlag = true }

    // MARK: - 内存池与核心逻辑

    private func createPixelBufferFromPool() -> CVPixelBuffer? {
        guard let pool = inputPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
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

    // 传入指针，完全避开 Swift 数组的安全检查
    private func accumulateOutputBuffer(
        _ outputBuffer: CVPixelBuffer,
        accumR: UnsafeMutablePointer<Float>,
        accumG: UnsafeMutablePointer<Float>,
        accumB: UnsafeMutablePointer<Float>,
        accumW: UnsafeMutablePointer<Float>,
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
            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else if pos >= sz - fw {
            let ratio: Float = (sz - pos) / fw
            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else {
            return 1.0
        }
    }

    private func createOutputBuffer(
        width: Int, height: Int,
        accumR: UnsafeMutablePointer<Float>, accumG: UnsafeMutablePointer<Float>,
        accumB: UnsafeMutablePointer<Float>, accumW: UnsafeMutablePointer<Float>
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

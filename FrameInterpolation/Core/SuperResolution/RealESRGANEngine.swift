import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - Real-ESRGAN x4v3 轻量版超分引擎

/// Real-ESRGAN General-x4v3 轻量版 4x 超分引擎
/// 尺寸：宽352 × 高608，单线程串行推
final class RealESRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .realESRGAN
    let inputWidth: Int = 352
    let inputHeight: Int = 608
    let scaleFactor: Int = 4

    // MARK: - 瓦片配置 (宽352，高608)

    // X轴步长 = 352 - 64 = 288（输入图上重叠 64 像素）
    private let tileStrideX = 288
    // Y轴步长 = 608 - 64 = 544（输入图上重叠 64 像素）
    private let tileStrideY = 544
    
    // 放大 4 倍后的输出重叠区域宽度 = 64 * 4 = 256 像素
    private let outputFeatherWidth = 256

    // MARK: - 私有属性

    private let model: MLModel
    private var isCancelledFlag = false

    // MARK: - 初始化

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGAN.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("找不到模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("模型加载失败")
            return nil
        }
        self.model = model
        
        logger.info("RealESRGAN 引擎初始化成功，瓦片尺寸: \(self.inputWidth)x\(self.inputHeight)")
    }

    // MARK: - 核心方法

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

        // 计算需要多少行、多少列瓦片
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

        for row in 0..<rows {
            for col in 0..<cols {
                if isCancelledFlag { return nil }

                let srcX = min(col * tileStrideX, max(srcWidth - inputWidth, 0))
                let srcY = min(row * tileStrideY, max(srcHeight - inputHeight, 0))

                autoreleasepool {
                    // 每次循环创建局部的 buffer，由 ARC 自动回收，避免跨线程数据踩踏
                    guard let tileBuffer = createPixelBuffer(width: inputWidth, height: inputHeight) else { return }
                    
                    fillTileBuffer(tileBuffer, from: src, srcBytesPerRow: srcBytesPerRow, srcWidth: srcWidth, srcHeight: srcHeight, x: srcX, y: srcY)

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
                        tileWidth: outputTileWidth,
                        tileHeight: outputTileHeight,
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

    // 修复了黑边问题和镜像填充
    private func fillTileBuffer(_ tile: CVPixelBuffer, from src: UnsafePointer<UInt8>, srcBytesPerRow: Int, srcWidth: Int, srcHeight: Int, x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(tile, [])
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(tile) else { return }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(tile)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)

        let copyWidth = min(inputWidth, srcWidth - x)
        let copyHeight = min(inputHeight, srcHeight - y)
        
        // 1. 拷贝有效区域的像素
        for row in 0..<copyHeight {
            let srcRow = src.advanced(by: (y + row) * srcBytesPerRow + x * 4)
            let dstRow = dst.advanced(by: row * dstBytesPerRow)
            memcpy(dstRow, srcRow, copyWidth * 4)
            
            // 2. 【镜像填充】处理右侧不足的区域
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
        
        // 3. 【镜像填充】处理底部不足的区域
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
                // 边界保护
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

    // 修复了平滑过渡算法（Smoothstep）
    private func featherWeight(position: Int, size: Int) -> Float {
        let fw: Float = Float(outputFeatherWidth)
        let pos: Float = Float(position)
        let sz: Float = Float(size)
        
        if pos < fw {
            let ratio: Float = pos / f =w
            return ratio * ratio * (3.0 - 2.0 * ratio) // 平滑步进曲线，防止线性过渡带来的模糊
        } else if pos >= sz - fw {
            let ratio: Float = (sz - pos) / fw
            return ratio * ratio * (3.0 - 2.0 * ratio)
        } else {
            return 1.0
        }
    }

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
            buffer kCVPixelBufferWidthKey: width,
            kCVPixelBuffer elseHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: {
 [:]
        ] as CFDictionary
        guard CVPixelBuffer           Create(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
 return              let result nil
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
            if let unmanagedValue = CVBufferCopyAttachment(src, key, nil) {
                let value = unmanagedValue.takeUnretainedValue()
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
    }
}
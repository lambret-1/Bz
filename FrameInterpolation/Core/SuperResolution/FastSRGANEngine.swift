import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - Fast-SRGAN 超分引擎

/// Fast-SRGAN 4x 超分引擎（轻量快速版）
/// 128×128 瓦片拼接（带羽化融合），4x 放大，适合通用低清视频
/// MLMultiArray 输入输出，归一化到 [0,1]，RGB 通道顺序
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
final class FastSRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "FastSRGANEngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .fastSRGAN
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
    /// 模型输入数据类型（float16 或 float32）
    private let inputDataType: MLMultiArrayDataType
    /// 模型输出数据类型
    private let outputDataType: MLMultiArrayDataType

    /// 取消标志
    private var isCancelledFlag = false

    // MARK: - 初始化

    init?() {
        // 1. 加载 Core ML 模型
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.fastSRGAN.modelFileName,
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

        // 2. 读取输入输出数据类型
        let inputDesc = model.modelDescription.inputDescriptionsByName["input"]
        let outputDesc = model.modelDescription.outputDescriptionsByName["output"]

        if let descDataType = inputDesc?.multiArrayConstraint?.dataType {
            inputDataType = descDataType
        } else {
            inputDataType = .float16
        }

        if let descDataType = outputDesc?.multiArrayConstraint?.dataType {
            outputDataType = descDataType
        } else {
            outputDataType = .float16
        }

        logger.info("Fast-SRGAN 引擎初始化成功，瓦片: \(self.inputWidth)x\(self.inputHeight)，步长: \(self.tileStride)，输入: \(self.inputDataType.rawValue)，输出: \(self.outputDataType.rawValue)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 4x 超分（128×128 瓦片拼接）
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

        // 3. 逐瓦片推理并累加
        for row in 0..<rows {
            for col in 0..<cols {
                if isCancelledFlag { return nil }

                let srcX = min(col * tileStride, max(srcWidth - inputWidth, 0))
                let srcY = min(row * tileStride, max(srcHeight - inputHeight, 0))

                // 提取瓦片（128x128）并转为 MLMultiArray
                guard let tileArray = makeTileArray(from: pixelBuffer, x: srcX, y: srcY) else {
                    logger.error("瓦片提取失败 (\(col),\(row))")
                    continue
                }

                // 推理瓦片
                guard let outputArray = processTile(tileArray) else {
                    logger.error("瓦片推理失败 (\(col),\(row))")
                    continue
                }

                // 累加到 Float 缓冲区（带羽化权重）
                let dstX = srcX * scaleFactor
                let dstY = srcY * scaleFactor
                accumulateTile(
                    outputArray,
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

    // MARK: - 瓦片提取与预处理（BGRA → NCHW MLMultiArray）

    private func makeTileArray(from source: CVPixelBuffer, x: Int, y: Int) -> MLMultiArray? {
        let shape: [NSNumber] = [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)]
        guard let array = try? MLMultiArray(shape: shape, dataType: inputDataType) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(source) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)

        let plane = inputWidth * inputHeight

        switch inputDataType {
        case .float16:
            let dst = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for ty in 0..<inputHeight {
                for tx in 0..<inputWidth {
                    let srcOffset = (y + ty) * srcBytesPerRow + (x + tx) * 4
                    let idx = ty * inputWidth + tx
                    // BGRA → RGB，归一化到 [0,1]
                    dst[0 * plane + idx] = Float16(Float(src[srcOffset + 2]) / 255.0) // R
                    dst[1 * plane + idx] = Float16(Float(src[srcOffset + 1]) / 255.0) // G
                    dst[2 * plane + idx] = Float16(Float(src[srcOffset + 0]) / 255.0) // B
                }
            }
        case .float32:
            let dst = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for ty in 0..<inputHeight {
                for tx in 0..<inputWidth {
                    let srcOffset = (y + ty) * srcBytesPerRow + (x + tx) * 4
                    let idx = ty * inputWidth + tx
                    dst[0 * plane + idx] = Float(src[srcOffset + 2]) / 255.0 // R
                    dst[1 * plane + idx] = Float(src[srcOffset + 1]) / 255.0 // G
                    dst[2 * plane + idx] = Float(src[srcOffset + 0]) / 255.0 // B
                }
            }
        default:
            logger.error("不支持的输入数据类型: \(self.inputDataType.rawValue)")
            return nil
        }

        return array
    }

    // MARK: - 单瓦片推理

    private func processTile(_ inputArray: MLMultiArray) -> MLMultiArray? {
        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: featureProvider),
              let outputArray = prediction.featureValue(for: "output")?.multiArrayValue else {
            logger.error("Core ML 推理失败")
            return nil
        }
        return outputArray
    }

    // MARK: - 瓦片累加（Float 累加器，带羽化权重）

    private func accumulateTile(
        _ array: MLMultiArray,
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
        let plane = tileSize * tileSize
        let totalPixels = min(plane, array.count / 3)

        switch array.dataType {
        case .float16:
            let srcPtr = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for idx in 0..<totalPixels {
                let ty = idx / tileSize
                let tx = idx % tileSize
                let outY = dstY + ty
                let outX = dstX + tx
                guard outY >= 0 && outY < outputHeight && outX >= 0 && outX < outputWidth else { continue }

                let yWeight = featherWeight(position: ty, size: tileSize)
                let xWeight = featherWeight(position: tx, size: tileSize)
                let weight = xWeight * yWeight
                guard weight > 0 else { continue }

                let rIdx = 0 * plane + idx
                let gIdx = 1 * plane + idx
                let bIdx = 2 * plane + idx
                guard rIdx < array.count && gIdx < array.count && bIdx < array.count else { break }

                let outIdx = outY * outputWidth + outX
                accumR[outIdx] += Float(srcPtr[rIdx]) * weight
                accumG[outIdx] += Float(srcPtr[gIdx]) * weight
                accumB[outIdx] += Float(srcPtr[bIdx]) * weight
                accumW[outIdx] += weight
            }
        case .float32:
            let srcPtr = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for idx in 0..<totalPixels {
                let ty = idx / tileSize
                let tx = idx % tileSize
                let outY = dstY + ty
                let outX = dstX + tx
                guard outY >= 0 && outY < outputHeight && outX >= 0 && outX < outputWidth else { continue }

                let yWeight = featherWeight(position: ty, size: tileSize)
                let xWeight = featherWeight(position: tx, size: tileSize)
                let weight = xWeight * yWeight
                guard weight > 0 else { continue }

                let rIdx = 0 * plane + idx
                let gIdx = 1 * plane + idx
                let bIdx = 2 * plane + idx
                guard rIdx < array.count && gIdx < array.count && bIdx < array.count else { break }

                let outIdx = outY * outputWidth + outX
                accumR[outIdx] += srcPtr[rIdx] * weight
                accumG[outIdx] += srcPtr[gIdx] * weight
                accumB[outIdx] += srcPtr[bIdx] * weight
                accumW[outIdx] += weight
            }
        default:
            logger.error("不支持的输出数据类型: \(array.dataType.rawValue)")
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

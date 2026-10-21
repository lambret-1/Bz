import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - RealESRGAN x2 视频超分引擎

/// RealESRGAN x2 视频版超分引擎
/// 固定输入 256×256 TensorType（12通道），输出 1024×1024（4x）
/// 12通道 = 4帧×RGB（时序信息，先用当前帧重复填充）
final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2
    let inputWidth: Int = 256
    let inputHeight: Int = 256
    let scaleFactor: Int = 4

    private let model: MLModel
    private var isCancelledFlag = false

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGANx2.modelFileName,
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
        logger.info("RealESRGAN x2 引擎初始化成功，输入: \(self.inputWidth)x\(self.inputHeight)，输出: \(self.inputWidth * 4)x\(self.inputHeight * 4)")
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // 1. 缩放到 256×256
        guard let resizedInput = resizePixelBuffer(pixelBuffer, width: inputWidth, height: inputHeight) else {
            logger.error("输入帧缩放失败")
            return nil
        }

        // 2. BGRA CVPixelBuffer → MLMultiArray [1, 12, 256, 256] Float16
        // 12通道 = 4帧×RGB，先用当前帧重复填充
        guard let inputArray = try? MLMultiArray(shape: [1, 12, 256, 256], dataType: .float16) else {
            logger.error("创建输入数组失败")
            return nil
        }
        bgraTo12ChannelFloat16(resizedInput, output: inputArray)

        // 3. 推理
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray]),
              let prediction = try? model.prediction(from: provider),
              let outputArray = prediction.featureValue(for: "output")?.multiArrayValue else {
            logger.error("模型推理失败")
            return nil
        }

        // 4. MLMultiArray [1, 3, 1024, 1024] Float16 → BGRA CVPixelBuffer
        guard let outputBuffer = float16PlanarToBGRA(outputArray, width: 1024, height: 1024) else {
            logger.error("输出转换失败")
            return nil
        }

        // 5. 缩放到目标尺寸（源尺寸×4）
        let targetWidth = srcWidth * 4
        let targetHeight = srcHeight * 4
        guard let finalOutput = resizePixelBuffer(outputBuffer, width: targetWidth, height: targetHeight) else {
            return outputBuffer
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: finalOutput)
        return finalOutput
    }

    func cancel() { isCancelledFlag = true }

    // MARK: - 缩放

    private func resizePixelBuffer(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var destBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &destBuffer) == kCVReturnSuccess,
              let dest = destBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else {
            return nil
        }

        var srcBuffer = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dstBuffer = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(dest)
        )

        vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        return dest
    }

    // MARK: - BGRA → 12通道 Float16 Planar

    private func bgraTo12ChannelFloat16(_ pixelBuffer: CVPixelBuffer, output: MLMultiArray) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = base.assumingMemoryBound(to: UInt8.self)

        let w = inputWidth
        let h = inputHeight
        let ptr = UnsafeMutablePointer<Float16>(OpaquePointer(output.dataPointer))
        let planeSize = w * h

        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bytesPerRow + x * 4
                let b = Float16(src[offset + 0]) / 255.0
                let g = Float16(src[offset + 1]) / 255.0
                let r = Float16(src[offset + 2]) / 255.0
                let idx = y * w + x

                // 12通道 = 4帧×RGB，当前帧重复4次
                for frame in 0..<4 {
                    let baseCh = frame * 3
                    ptr[baseCh * planeSize + idx] = r
                    ptr[(baseCh + 1) * planeSize + idx] = g
                    ptr[(baseCh + 2) * planeSize + idx] = b
                }
            }
        }
    }

    // MARK: - Float16 Planar → BGRA

    private func float16PlanarToBGRA(_ array: MLMultiArray, width: Int, height: Int) -> CVPixelBuffer? {
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

        let src = UnsafePointer<Float16>(OpaquePointer(array.dataPointer))
        let planeSize = width * height

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let r = Float(src[idx]) * 255.0
                let g = Float(src[planeSize + idx]) * 255.0
                let b = Float(src[2 * planeSize + idx]) * 255.0

                let pixelOffset = y * dstBytesPerRow + x * 4
                dst[pixelOffset + 0] = UInt8(max(0, min(255, Int(b))))
                dst[pixelOffset + 1] = UInt8(max(0, min(255, Int(g))))
                dst[pixelOffset + 2] = UInt8(max(0, min(255, Int(r))))
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
            if let unmanagedValue = CVBufferGetAttachment(src, key, nil) {
                let value = unmanagedValue.takeUnretainedValue()
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
    }
}

import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - PiperSR 全帧超分引擎

/// PiperSR 2x 视频版超分引擎（ANE 原生）
/// 固定输入 640×360 TensorType，输出 1280×720
/// 无瓦片拼接，整帧推理，速度极快
final class FastSRGANEngine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "PiperSREngine")

    // MARK: - 超分引擎协议

    static let engineType: SuperResolutionEngineType = .fastSRGAN
    let inputWidth: Int = 640
    let inputHeight: Int = 360
    let scaleFactor: Int = 2
    var targetScale: Int = 2

    // MARK: - 私有属性

    private let model: MLModel

    /// 取消标志
    private var isCancelledFlag = false

    // MARK: - 初始化

    init?() {
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

        logger.info("PiperSR 全帧引擎初始化成功，输入: \(self.inputWidth)x\(self.inputHeight)，输出: \(self.inputWidth * 2)x\(self.inputHeight * 2)")
    }

    // MARK: - 公开方法

    /// 对单帧执行 2x 全帧超分
    /// 输入任意尺寸帧，先缩放到 640×360，推理输出 1280×720
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // 1. 将输入帧缩放到 640×360
        guard let resizedInput = resizePixelBuffer(pixelBuffer, width: inputWidth, height: inputHeight) else {
            logger.error("输入帧缩放失败")
            return nil
        }

        // 2. BGRA CVPixelBuffer → MLMultiArray [1,3,360,640] Float16
        guard let inputArray = try? MLMultiArray(shape: [1, 3, 360, 640], dataType: .float16) else {
            logger.error("创建输入数组失败")
            return nil
        }
        bgraToFloat16Planar(resizedInput, output: inputArray)

        // 3. 推理
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input_image": inputArray]),
              let prediction = try? model.prediction(from: provider),
              let outputArray = prediction.featureValue(for: "output_image")?.multiArrayValue else {
            logger.error("模型推理失败")
            return nil
        }

        // 4. MLMultiArray [1,3,720,1280] Float16 → BGRA CVPixelBuffer
        guard let outputBuffer = float16PlanarToBGRA(outputArray, width: 1280, height: 720) else {
            logger.error("输出转换失败")
            return nil
        }

        // 5. 复制颜色空间附件
        copyColorSpaceAttachments(from: pixelBuffer, to: outputBuffer)

        return outputBuffer
    }

    /// 取消处理
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

    // MARK: - BGRA → Float16 Planar

    private func bgraToFloat16Planar(_ pixelBuffer: CVPixelBuffer, output: MLMultiArray) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = base.assumingMemoryBound(to: UInt8.self)

        let w = inputWidth
        let h = inputHeight

        // MLMultiArray shape: [1, 3, 360, 640]
        let ptr = UnsafeMutablePointer<Float16>(OpaquePointer(output.dataPointer))
        let planeSize = w * h

        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bytesPerRow + x * 4
                let b = Float16(src[offset + 0]) / 255.0
                let g = Float16(src[offset + 1]) / 255.0
                let r = Float16(src[offset + 2]) / 255.0
                let idx = y * w + x
                ptr[idx] = r           // R plane
                ptr[planeSize + idx] = g  // G plane
                ptr[2 * planeSize + idx] = b  // B plane
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

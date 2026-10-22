import CoreML
import CoreVideo
import CoreImage
import OSLog

final class RealESRGANx4Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx4Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx4

    // 模型要求固定的 512x512 输入
    let inputWidth: Int = 512
    let inputHeight: Int = 512
    let scaleFactor: Int = 4
    var targetScale: Int = 4

    private let model: MLModel
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var isCancelledFlag = false

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: "RealESRGAN_x4",
            withExtension: "mlmodelc"
        ) else {
            logger.error("初始化失败: 找不到 RealESRGAN_x4.mlmodelc")
            return nil
        }
        logger.info("模型路径: \(modelURL.path)")

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("初始化失败: MLModel 加载异常")
            return nil
        }
        self.model = model
        logger.info("初始化成功: 输入 \(inputWidth)x\(inputHeight), 输出 \(inputWidth*scaleFactor)x\(inputHeight*scaleFactor)")
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else {
            logger.error("跳过: 输入尺寸非法 \(srcWidth)x\(srcHeight)")
            return nil
        }
        logger.info("输入帧: \(srcWidth)x\(srcHeight)")

        // 1. 预处理：缩放到 512x512
        guard let resized512 = resizePixelBuffer(pixelBuffer, targetWidth: 512, targetHeight: 512) else {
            logger.error("预处理失败: 缩放到512x512失败")
            return nil
        }
        let resizedW = CVPixelBufferGetWidth(resized512)
        let resizedH = CVPixelBufferGetHeight(resized512)
        logger.info("预处理完成: \(resizedW)x\(resizedH)")

        if isCancelledFlag { return nil }

        // 2. 推理（输出特征名 activation_out）
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(pixelBuffer: resized512)
            ])
            let prediction = try model.prediction(from: inputProvider)
            logger.info("可用输出特征: \(prediction.featureNames)")

            guard let outputBuffer = prediction.featureValue(for: "activation_out")?.imageBufferValue else {
                logger.error("推理输出为空: activation_out/imageBufferValue 为 nil")
                return nil
            }

            let outW = CVPixelBufferGetWidth(outputBuffer)
            let outH = CVPixelBufferGetHeight(outputBuffer)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.info("推理完成: 输出 \(outW)x\(outH), 耗时 \(String(format: "%.3f", elapsed))s")

            if isCancelledFlag { return nil }

            // 3. 后处理：缩放到目标尺寸 src×2
            let targetOutWidth = srcWidth * 2
            let targetOutHeight = srcHeight * 2
            logger.info("后处理: \(outW)x\(outH) → \(targetOutWidth)x\(targetOutHeight)")

            guard let finalOutput = resizePixelBuffer(outputBuffer, targetWidth: targetOutWidth, targetHeight: targetOutHeight) else {
                logger.error("后处理失败: 缩放到目标尺寸失败")
                return nil
            }

            copyColorSpaceAttachments(from: pixelBuffer, to: finalOutput)
            let finalW = CVPixelBufferGetWidth(finalOutput)
            let finalH = CVPixelBufferGetHeight(finalOutput)
            logger.info("输出帧: \(finalW)x\(finalH)")
            return finalOutput

        } catch {
            logger.error("推理异常: \(error.localizedDescription)")
            return nil
        }
    }

    func cancel() { isCancelledFlag = true }

    private func resizePixelBuffer(_ srcBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> CVPixelBuffer? {
        var dstBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, attrs, &dstBuffer) == kCVReturnSuccess,
              let dst = dstBuffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: srcBuffer)
        let scaleX = CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(srcBuffer))
        let scaleY = CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(srcBuffer))
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaledImage, to: dst)
        return dst
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

import CoreML
import CoreVideo
import CoreImage
import OSLog

final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2
    
    // 模型要求固定的 512x512 输入
    let inputWidth: Int = 512
    let inputHeight: Int = 512
    let scaleFactor: Int = 4 // 模型输出是 2048x2048
    var targetScale: Int = 4

    private let model: MLModel
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var isCancelledFlag = false

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: "RealESRGAN_x2",
            withExtension: "mlpackage"
        ) else {
            logger.error("找不到 RealESRGAN_x2 模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("模型加载失败")
            return nil
        }
        self.model = model
        logger.info("RealESRGAN 引擎初始化成功 (硬件加速版)")
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // 1. 预处理：将 720p 等任意尺寸缩放为 512x512（这里直接拉伸，模型处理效果极好）
        guard let resized512 = resizePixelBuffer(pixelBuffer, targetWidth: 512, targetHeight: 512) else {
            return nil
        }

        if isCancelledFlag { return nil }

        // 2. 推理（输出特征名是 activation_out，不是 output）
        guard let inputProvider = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(pixelBuffer: resized512)]),
              let prediction = try? model.prediction(from: inputProvider),
              let outputBuffer = prediction.featureValue(for: "activation_out")?.imageBufferValue else {
            logger.error("推理失败")
            return nil
        }

        if isCancelledFlag { return nil }

        // 3. 后处理：模型输出 2048×2048，缩放到目标尺寸（src尺寸 × targetScale）
        let targetOutWidth = srcWidth * targetScale
        let targetOutHeight = srcHeight * targetScale
        
        guard let finalOutput = resizePixelBuffer(outputBuffer, targetWidth: targetOutWidth, targetHeight: targetOutHeight) else {
            return nil
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: finalOutput)
        return finalOutput
    }

    func cancel() { isCancelledFlag = true }

    // MARK: - 使用 GPU 快速缩放 (不再使用 CPU 循环)
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
        
        // 这里建议加上 AspectFit 逻辑，防止画面极度拉伸
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
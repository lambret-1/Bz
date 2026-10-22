import CoreML
import CoreVideo
import CoreImage
import OSLog
import MachO

final class RealESRGANx4Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx4Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx4

    let inputWidth: Int = 512
    let inputHeight: Int = 512
    let scaleFactor: Int = 4
    var targetScale: Int = 4

    private let model: MLModel
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var isCancelledFlag = false
    private var frameCount = 0

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: "RealESRGAN_x4",
            withExtension: "mlmodelc"
        ) else {
            logger.error("[帧?] 初始化失败: 找不到 RealESRGAN_x4.mlmodelc")
            return nil
        }
        logger.info("[帧?] 模型路径: \(modelURL.path)")

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loadStart = CFAbsoluteTimeGetCurrent()
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("[帧?] 初始化失败: MLModel 加载异常")
            return nil
        }
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
        self.model = model
        logger.info("[帧?] 初始化成功: 输入 512x512, 输出 2048x2048, 加载耗时 \(String(format: "%.2f", loadTime))s")
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        isCancelledFlag = false
        frameCount += 1
        let frameNo = frameCount

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else {
            logger.error("[帧\(frameNo)] 跳过: 输入尺寸非法 \(srcWidth)x\(srcHeight)")
            return nil
        }
        logger.info("[帧\(frameNo)] 输入: \(srcWidth)x\(srcHeight), 内存 \(Self.memoryMB())MB")

        // 1. 预处理
        guard let resized512 = resizePixelBuffer(pixelBuffer, targetWidth: 512, targetHeight: 512) else {
            logger.error("[帧\(frameNo)] 预处理失败: 缩放到512x512失败")
            return nil
        }
        logger.info("[帧\(frameNo)] 预处理完成: 512x512")

        if isCancelledFlag {
            logger.info("[帧\(frameNo)] 已取消（预处理后）")
            return nil
        }

        // 2. 推理
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(pixelBuffer: resized512)
            ])
            let prediction = try model.prediction(from: inputProvider)

            guard let outputBuffer = prediction.featureValue(for: "activation_out")?.imageBufferValue else {
                logger.error("[帧\(frameNo)] 推理输出为空: activation_out/imageBufferValue=nil, 可用特征=\(prediction.featureNames)")
                return nil
            }

            let outW = CVPixelBufferGetWidth(outputBuffer)
            let outH = CVPixelBufferGetHeight(outputBuffer)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            // 采样输出像素，检测是否全黑
            let sample = Self.samplePixels(outputBuffer)
            logger.info("[帧\(frameNo)] 推理: \(outW)x\(outH), \(String(format: "%.3f", elapsed))s, 像素采样 R\(sample.r) G\(sample.g) B\(sample.b)")

            if isCancelledFlag {
                logger.info("[帧\(frameNo)] 已取消（推理后）")
                return nil
            }

            // 3. 后处理
            let targetOutWidth = srcWidth * 2
            let targetOutHeight = srcHeight * 2

            guard let finalOutput = resizePixelBuffer(outputBuffer, targetWidth: targetOutWidth, targetHeight: targetOutHeight) else {
                logger.error("[帧\(frameNo)] 后处理失败: 缩放到 \(targetOutWidth)x\(targetOutHeight) 失败")
                return nil
            }

            // 色彩空间传递
            var passedKeys: [String] = []
            let colorKeys: [CFString] = [
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferICCProfileKey,
                kCVImageBufferChromaLocationTopFieldKey
            ]
            for key in colorKeys {
                if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) {
                    CVBufferSetAttachment(finalOutput, key, value, .shouldPropagate)
                    passedKeys.append(key as String)
                }
            }
            let finalW = CVPixelBufferGetWidth(finalOutput)
            let finalH = CVPixelBufferGetHeight(finalOutput)
            logger.info("[帧\(frameNo)] 输出: \(finalW)x\(finalH), 色彩空间 \(passedKeys.count)个, 内存 \(Self.memoryMB())MB")
            return finalOutput

        } catch {
            logger.error("[帧\(frameNo)] 推理异常: \(error.localizedDescription)")
            return nil
        }
    }

    func cancel() {
        isCancelledFlag = true
        logger.info("收到取消请求（帧\(self.frameCount)）")
    }

    // MARK: - 采样工具

    private struct PixelSample {
        let r: UInt8, g: UInt8, b: UInt8
    }

    private static func samplePixels(_ buffer: CVPixelBuffer) -> PixelSample {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return PixelSample(r: 0, g: 0, b: 0)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // 中心像素
        let x = width / 2
        let y = height / 2
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * bytesPerRow + x * 4
        let b = ptr[offset]
        let g = ptr[offset + 1]
        let r = ptr[offset + 2]
        return PixelSample(r: r, g: g, b: b)
    }

    private static func memoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / 1024 / 1024
    }

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
}

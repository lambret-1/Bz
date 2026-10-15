import AVFoundation
import CoreVideo
import OSLog
import Accelerate

/// 视频处理管线：解码 → 补帧 → 编码 + 音频透传
/// 支持 2x/4x 补帧，模型缺失时自动降级为空转（帧率不变）
final class VideoPipeline {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPipeline")
    private var isCancelled = false
    /// 帧插值器，模型缺失时为 nil（降级为空转）
    private let interpolator: FrameInterpolator?
    /// 后台处理队列
    private let processingQueue = DispatchQueue(label: "com.lambret.bz.pipeline", qos: .userInitiated)

    /// 音频诊断结果（供结果页展示，不依赖Xcode控制台）
    static var 音频诊断结果: String = "未执行"

    /// 是否使用 AI 补帧（模型加载成功为 true，缺失为 false）
    var isUsingAIInterpolation: Bool { interpolator != nil }

    init() {
        self.interpolator = FrameInterpolator()
        if interpolator == nil {
            logger.warning("RIFE Lite 模型未加载，管线将以空转模式运行（帧率不变）")
        } else {
            logger.info("RIFE Lite 模型加载成功，补帧功能已启用")
        }
    }

    // MARK: - 公开方法

    /// 开始处理视频
    /// - Parameters:
    ///   - inputURL: 输入视频文件 URL
    ///   - outputURL: 输出视频文件 URL
    ///   - multiplier: 补帧倍数（2 或 4），模型缺失时此参数无效
    ///   - progress: 进度回调（0.0~1.0, 当前阶段），主线程调用
    ///   - completion: 完成回调，主线程调用
    func process(
        inputURL: URL,
        outputURL: URL,
        multiplier: Int,
        fastMode: Bool = false,
        outputResolution: OutputResolution = .auto,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        isCancelled = false
        let effectiveMultiplier = interpolator != nil ? multiplier : 1
        logger.info("开始处理: \(inputURL.lastPathComponent, privacy: .public), 倍数\(effectiveMultiplier)x, 快速模式:\(fastMode), 分辨率:\(outputResolution.rawValue)")

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.runPipeline(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    multiplier: effectiveMultiplier,
                    fastMode: fastMode,
                    outputResolution: outputResolution,
                    progress: progress,
                    completion: completion
                )
            } catch {
                self.logger.error("管线处理失败: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    completion(.failure(error))
                }
            }
        }
    }

    /// 取消处理
    func cancel() {
        logger.info("用户取消处理")
        isCancelled = true
    }

    // MARK: - 私有方法

    private func runPipeline(
        inputURL: URL,
        outputURL: URL,
        multiplier: Int,
        fastMode: Bool,
        outputResolution: OutputResolution,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)

        // 异步加载轨道（iOS 16+ 同步属性可能返回空，必须用 loadTracks）
        let tracksSemaphore = DispatchSemaphore(value: 0)
        var loadedVideoTrack: AVAssetTrack?
        var loadedAudioTrack: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { videoTracks, error in
            loadedVideoTrack = videoTracks?.first
            asset.loadTracks(withMediaType: .audio) { audioTracks, _ in
                loadedAudioTrack = audioTracks?.first
                tracksSemaphore.signal()
            }
        }
        tracksSemaphore.wait()

        print("[Bz音频诊断] 视频轨道: \(loadedVideoTrack != nil ? "有" : "无"), 音频轨道: \(loadedAudioTrack != nil ? "有" : "无")")

        // 获取视频轨道
        guard let videoTrack = loadedVideoTrack else {
            throw PipelineError.noVideoTrack
        }

        // 帧率与帧数计算
        let inputFPS = Double(videoTrack.nominalFrameRate)
        guard inputFPS > 0 else {
            throw PipelineError.invalidFrameRate
        }
        let outputFPS = inputFPS * Double(multiplier)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let totalInputFrames = max(Int(durationSeconds * inputFPS), 1)

        // 输出尺寸（根据 outputResolution 缩放）
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        var outputWidth = Int(naturalSize.width)
        var outputHeight = Int(naturalSize.height)

        // 计算目标高度（保持宽高比）
        let targetHeight: Int?
        switch outputResolution {
        case .auto:
            targetHeight = nil
        case .p720:
            targetHeight = 720
        case .p1080:
            targetHeight = 1080
        }

        var needsScaling = false
        if let targetH = targetHeight, outputHeight > targetH {
            let scale = Double(targetH) / Double(outputHeight)
            outputWidth = Int(Double(outputWidth) * scale)
            outputHeight = targetH
            // 确保宽高为偶数（H.264 编码要求）
            outputWidth = outputWidth - (outputWidth % 2)
            outputHeight = outputHeight - (outputHeight % 2)
            needsScaling = true
        }

        guard outputWidth > 0, outputHeight > 0 else {
            throw PipelineError.invalidVideoSize
        }

        print("[Bz音频诊断] 输入: \(Int(naturalSize.width))x\(Int(naturalSize.height)), 输出: \(outputWidth)x\(outputHeight), 缩放:\(needsScaling), 快速模式:\(fastMode)")
        print("[Bz音频诊断] 输出: \(outputFPS)fps, 倍数\(multiplier)x")

        // 临时无声视频文件（第一阶段输出）
        let tempVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        // 删除已存在的输出文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // MARK: 配置视频 Reader
        let reader = try AVAssetReader(asset: asset)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw PipelineError.readerConfigurationFailed
        }
        reader.add(videoReaderOutput)

        // MARK: 配置 Writer（仅视频，音频后续用 AVAssetExportSession 合成）
        let writer = try AVAssetWriter(outputURL: tempVideoURL, fileType: .mp4)

        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight
            ]
        )
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = transform

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoWriterInput) else {
            throw PipelineError.writerConfigurationFailed
        }
        writer.add(videoWriterInput)

        // MARK: 启动读写
        guard reader.startReading() else {
            throw PipelineError.readerStartFailed(reader.error ?? PipelineError.unknown)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        Self.音频诊断结果 = "视频处理中，后续合成音频"

        // MARK: 视频处理循环
        var outputFrameIndex = 0
        var previousPixelBuffer: CVPixelBuffer?
        var lastProgressReport = 0.0

        while reader.status == .reading {
            if isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw PipelineError.cancelled
            }

            guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            // 进度计算（基于输入帧数）
            let inputFrameIndex = outputFrameIndex / max(multiplier, 1)
            let progressValue = min(Double(inputFrameIndex) / Double(totalInputFrames), 0.99)
            if progressValue - lastProgressReport >= 0.01 {
                lastProgressReport = progressValue
                let stage: ProcessingStage = interpolator != nil ? .inferring : .decoding
                Task { @MainActor in
                    progress(progressValue, stage)
                }
            }

            autoreleasepool {
                // 如果有前一帧且插值器可用，生成中间帧
                if let prev = previousPixelBuffer, let interpolator = self.interpolator, multiplier > 1 {
                    // 快速模式：偶数对用AI插值，奇数对用简单混合（推理次数减半）
                    let useAI = !fastMode || (inputFrameIndex % 2 == 0)

                    for midIndex in 1..<multiplier {
                        if self.isCancelled { return }

                        var midFrame: CVPixelBuffer?
                        if useAI {
                            midFrame = interpolator.interpolate(frame0: prev, frame1: pixelBuffer)
                        } else {
                            midFrame = self.blendFrames(prev, pixelBuffer)
                        }

                        if let midFrame = midFrame {
                            self.copyColorSpaceAttachments(from: pixelBuffer, to: midFrame)

                            // 输出分辨率缩放
                            let finalFrame = needsScaling ? self.scalePixelBuffer(midFrame, to: outputWidth, outputHeight) ?? midFrame : midFrame

                            let midPTS = CMTime(
                                value: Int64(outputFrameIndex),
                                timescale: Int32(outputFPS)
                            )
                            self.waitForWriterReady(videoWriterInput)
                            pixelBufferAdaptor.append(finalFrame, withPresentationTime: midPTS)
                            outputFrameIndex += 1
                        }
                    }
                }

                // 写入当前原始帧（输出分辨率缩放）
                let finalFrame = needsScaling ? self.scalePixelBuffer(pixelBuffer, to: outputWidth, outputHeight) ?? pixelBuffer : pixelBuffer
                let currentPTS = CMTime(
                    value: Int64(outputFrameIndex),
                    timescale: Int32(outputFPS)
                )
                self.waitForWriterReady(videoWriterInput)
                pixelBufferAdaptor.append(finalFrame, withPresentationTime: currentPTS)
                outputFrameIndex += 1
            }

            previousPixelBuffer = pixelBuffer
        }

        // 检查 reader 最终状态
        if reader.status == .failed {
            if let error = reader.error {
                throw error
            }
            throw PipelineError.readerFailed
        }

        videoWriterInput.markAsFinished()
        print("[Bz音频诊断] 视频处理完成，输出帧数: \(outputFrameIndex)")

        // MARK: 完成视频写入
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            let error = writer.error ?? PipelineError.writerFailed
            logger.error("视频编码失败: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempVideoURL)
            throw error
        }

        // MARK: 第二阶段：用 AVAssetExportSession 合成原视频音频
        if loadedAudioTrack != nil {
            Self.音频诊断结果 = "合成音频中..."
            print("[Bz音频诊断] 开始合成原视频音频")
            try self.muxAudio(
                videoURL: tempVideoURL,
                sourceAsset: asset,
                outputURL: outputURL
            )
            print("[Bz音频诊断] 音频合成完成")
        } else {
            // 无音频轨道，直接移动临时文件到输出位置
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: tempVideoURL, to: outputURL)
            Self.音频诊断结果 = "原视频无音频轨道"
            print("[Bz音频诊断] 原视频无音频，直接输出无声视频")
        }

        // 清理临时文件
        try? FileManager.default.removeItem(at: tempVideoURL)

        Task { @MainActor in
            progress(1.0, .finished)
            completion(.success(outputURL))
        }
    }

    // MARK: - 合成音频（AVMutableComposition + AVAssetExportSession）
    private func muxAudio(videoURL: URL, sourceAsset: AVAsset, outputURL: URL) throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()

        // 视频轨道
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            Self.音频诊断结果 = "合成失败：无法创建视频轨道"
            throw PipelineError.writerConfigurationFailed
        }
        guard let sourceVideoTrack = videoAsset.tracks(withMediaType: .video).first else {
            Self.音频诊断结果 = "合成失败：临时视频无视频轨道"
            throw PipelineError.noVideoTrack
        }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoAsset.duration),
            of: sourceVideoTrack,
            at: .zero
        )
        videoTrack.preferredTransform = sourceVideoTrack.preferredTransform

        // 音频轨道（从原视频复制）
        guard let sourceAudioTrack = sourceAsset.tracks(withMediaType: .audio).first else {
            Self.音频诊断结果 = "合成失败：原视频无音频轨道"
            throw PipelineError.writerConfigurationFailed
        }
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            Self.音频诊断结果 = "合成失败：无法创建音频轨道"
            throw PipelineError.writerConfigurationFailed
        }
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceAsset.duration),
            of: sourceAudioTrack,
            at: .zero
        )

        // 导出
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            Self.音频诊断结果 = "合成失败：无法创建ExportSession"
            throw PipelineError.writerConfigurationFailed
        }

        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        let exportSemaphore = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            exportSemaphore.signal()
        }
        exportSemaphore.wait()

        if exportSession.status != .completed {
            let error = exportSession.error ?? PipelineError.writerFailed
            Self.音频诊断结果 = "合成失败：\(error.localizedDescription)"
            print("[Bz音频诊断] 音频合成失败: \(error.localizedDescription)")
            throw error
        }

        Self.音频诊断结果 = "音频合成成功"
    }

    // MARK: - vImage 缩放 CVPixelBuffer（输出分辨率控制）
    private func scalePixelBuffer(_ source: CVPixelBuffer, to width: Int, _ height: Int) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        var srcBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source),
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )

        var dstPixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &dstPixelBuffer) == kCVReturnSuccess,
              let dst = dstPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        var dstBuffer = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(dst),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(dst)
        )

        let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            return nil
        }

        return dst
    }

    // MARK: - 快速模式：简单帧混合（跳过AI推理，0.5 alpha混合）
    private func blendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        var resultBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &resultBuffer) == kCVReturnSuccess,
              let result = resultBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(frame0, .readOnly)
        CVPixelBufferLockBaseAddress(frame1, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        let src0 = CVPixelBufferGetBaseAddress(frame0)!.assumingMemoryBound(to: UInt8.self)
        let src1 = CVPixelBufferGetBaseAddress(frame1)!.assumingMemoryBound(to: UInt8.self)
        let dst = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let totalBytes = bytesPerRow * height

        // 0.5 混合：dst = (src0 + src1) / 2
        for i in 0..<totalBytes {
            dst[i] = UInt8((UInt16(src0[i]) + UInt16(src1[i])) / 2)
        }

        return result
    }

    // MARK: - 等待 Writer 就绪（有界背压）
    private func waitForWriterReady(_ input: AVAssetWriterInput) {
        var waitCount = 0
        while !input.isReadyForMoreMediaData {
            if isCancelled { return }
            Thread.sleep(forTimeInterval: 0.005)
            waitCount += 1
            if waitCount > 200 { // 超过 1 秒未就绪
                logger.warning("Writer 超过 1 秒未就绪，等待次数: \(waitCount)")
                break
            }
        }
    }

    // MARK: - 颜色空间附件复制
    /// 将源 PixelBuffer 的颜色空间附件复制到目标 PixelBuffer
    /// 关键：AVAssetReader 读出的原帧带有 BT.709 等颜色空间信息，
    /// 手动创建的补帧缺少这些附件，H.264 编码时 RGB→YUV 转换会用默认 BT.601，
    /// 导致补帧与原帧亮度/颜色不一致
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

// MARK: - 错误定义
enum PipelineError: LocalizedError {
    case noVideoTrack
    case invalidFrameRate
    case invalidVideoSize
    case readerConfigurationFailed
    case writerConfigurationFailed
    case readerStartFailed(Error)
    case readerFailed
    case writerFailed
    case writerNotReady
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "输入视频没有视频轨道"
        case .invalidFrameRate:
            return "无法获取视频帧率"
        case .invalidVideoSize:
            return "视频尺寸无效"
        case .readerConfigurationFailed:
            return "视频读取器配置失败"
        case .writerConfigurationFailed:
            return "视频写入器配置失败"
        case .readerStartFailed(let error):
            return "视频读取启动失败: \(error.localizedDescription)"
        case .readerFailed:
            return "视频读取失败"
        case .writerFailed:
            return "视频编码失败"
        case .writerNotReady:
            return "视频编码器未就绪"
        case .cancelled:
            return "处理已取消"
        case .unknown:
            return "未知错误"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noVideoTrack:
            return "请选择包含视频轨道的 MP4 或 MOV 文件"
        case .cancelled:
            return nil
        default:
            return "请重试或更换视频文件"
        }
    }
}

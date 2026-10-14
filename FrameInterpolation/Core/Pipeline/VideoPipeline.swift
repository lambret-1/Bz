import AVFoundation
import CoreVideo
import OSLog

/// 视频处理管线：解码 → 补帧 → 编码 + 音频透传
/// 支持 2x/4x 补帧，模型缺失时自动降级为空转（帧率不变）
final class VideoPipeline {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPipeline")
    private var isCancelled = false
    /// 帧插值器，模型缺失时为 nil（降级为空转）
    private let interpolator: FrameInterpolator?
    /// 后台处理队列
    private let processingQueue = DispatchQueue(label: "com.lambret.bz.pipeline", qos: .userInitiated)

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
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        isCancelled = false
        let effectiveMultiplier = interpolator != nil ? multiplier : 1
        logger.info("开始处理: \(inputURL.lastPathComponent, privacy: .public), 倍数\(effectiveMultiplier)x")

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.runPipeline(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    multiplier: effectiveMultiplier,
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
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)

        // 获取视频轨道
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
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

        // 输出尺寸（编码尺寸，保留原始 transform）
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let outputWidth = Int(naturalSize.width)
        let outputHeight = Int(naturalSize.height)

        guard outputWidth > 0, outputHeight > 0 else {
            throw PipelineError.invalidVideoSize
        }

        logger.info("输入: \(outputWidth)x\(outputHeight), \(inputFPS)fps, 时长\(durationSeconds)s, 总帧数\(totalInputFrames)")
        logger.info("输出: \(outputFPS)fps, 倍数\(multiplier)x")

        // 删除已存在的输出文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // MARK: 配置 Reader
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

        // 音频轨道
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
                audioReaderOutput = audioOutput
                logger.info("检测到音频轨道，将透传音频")
            }
        }

        // MARK: 配置 Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

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

        // 音频写入
        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioWriterInput = audioInput
            }
        }

        // MARK: 启动读写
        guard reader.startReading() else {
            throw PipelineError.readerStartFailed(reader.error ?? PipelineError.unknown)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

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
                    for midIndex in 1..<multiplier {
                        if self.isCancelled { return }

                        // 生成中间帧
                        if let midFrame = interpolator.interpolate(frame0: prev, frame1: pixelBuffer) {
                            let midPTS = CMTime(
                                value: Int64(outputFrameIndex),
                                timescale: Int32(outputFPS)
                            )
                            self.waitForWriterReady(videoWriterInput)
                            pixelBufferAdaptor.append(midFrame, withPresentationTime: midPTS)
                            outputFrameIndex += 1
                        }
                    }
                }

                // 写入当前原始帧
                let currentPTS = CMTime(
                    value: Int64(outputFrameIndex),
                    timescale: Int32(outputFPS)
                )
                self.waitForWriterReady(videoWriterInput)
                pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: currentPTS)
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
        logger.info("视频处理完成，输出帧数: \(outputFrameIndex)")

        // MARK: 音频透传
        if let audioReaderOutput = audioReaderOutput, let audioWriterInput = audioWriterInput {
            logger.info("开始音频透传")
            var audioFrameCount = 0

            while reader.status == .reading {
                if isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw PipelineError.cancelled
                }

                guard let audioSample = audioReaderOutput.copyNextSampleBuffer() else {
                    break
                }

                autoreleasepool {
                    self.waitForWriterReady(audioWriterInput)
                    audioWriterInput.append(audioSample)
                    audioFrameCount += 1
                }
            }

            audioWriterInput.markAsFinished()
            logger.info("音频透传完成，音频帧数: \(audioFrameCount)")
        }

        // MARK: 完成写入
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status == .completed {
            logger.info("视频编码完成: \(outputURL.lastPathComponent, privacy: .public)")
            Task { @MainActor in
                progress(1.0, .finished)
                completion(.success(outputURL))
            }
        } else {
            let error = writer.error ?? PipelineError.writerFailed
            logger.error("视频编码失败: \(error.localizedDescription, privacy: .public)")
            throw error
        }
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

import AVFoundation
import CoreVideo
import OSLog

/// 视频处理管线（空转版本）
/// 当前阶段仅做 解码 → 编码 透传，不改变帧率与内容，用于验证 AVFoundation 管线稳定性
/// 后续阶段将在此基础上接入 RIFE Lite 补帧与音频透传
final class VideoPipeline {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPipeline")
    private var isCancelled = false
    /// 后台处理队列，避免阻塞主线程
    private let processingQueue = DispatchQueue(label: "com.lambret.bz.pipeline", qos: .userInitiated)

    // MARK: - 公开方法

    /// 开始处理视频（空转：解码后直接编码，帧率不变）
    /// - Parameters:
    ///   - inputURL: 输入视频文件 URL
    ///   - outputURL: 输出视频文件 URL
    ///   - progress: 进度回调（0.0 ~ 1.0），主线程调用
    ///   - completion: 完成回调，主线程调用
    func process(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        isCancelled = false
        logger.info("开始处理视频: \(inputURL.lastPathComponent, privacy: .public)")

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.runPipeline(
                    inputURL: inputURL,
                    outputURL: outputURL,
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
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)

        // 获取视频轨道（同步 API，在后台线程调用安全）
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }

        // 视频编码尺寸与方向
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let outputWidth = Int(naturalSize.width)
        let outputHeight = Int(naturalSize.height)

        guard outputWidth > 0, outputHeight > 0 else {
            throw PipelineError.invalidVideoSize
        }

        logger.info("视频尺寸: \(outputWidth)x\(outputHeight), 变换矩阵: \(transform)")

        // 如果输出文件已存在则删除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // MARK: 配置 Reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw PipelineError.readerConfigurationFailed
        }
        reader.add(readerOutput)

        // MARK: 配置 Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: writerSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        // 保留原始视频方向
        writerInput.transform = transform

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw PipelineError.writerConfigurationFailed
        }
        writer.add(writerInput)

        // MARK: 启动读写
        guard reader.startReading() else {
            throw PipelineError.readerStartFailed(reader.error ?? PipelineError.unknown)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // 估算总帧数用于进度计算
        let fps = Double(videoTrack.nominalFrameRate)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let totalFrames = max(Int(durationSeconds * fps), 1)
        var frameIndex = 0
        var lastProgressReport = 0.0

        logger.info("预计总帧数: \(totalFrames), 帧率: \(fps)fps, 时长: \(durationSeconds)s")

        // MARK: 逐帧处理
        while reader.status == .reading {
            // 检查取消
            if isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw PipelineError.cancelled
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // 等待 writer 就绪（有界背压，避免内存堆积）
            var waitCount = 0
            while !writerInput.isReadyForMoreMediaData {
                if isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw PipelineError.cancelled
                }
                Thread.sleep(forTimeInterval: 0.005)
                waitCount += 1
                if waitCount > 200 { // 超过 1 秒未就绪，视为异常
                    logger.error("Writer 超过 1 秒未就绪，终止处理")
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw PipelineError.writerNotReady
                }
            }

            // 自动释放池包裹每帧，降低内存峰值
            autoreleasepool {
                let appendSuccess = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts)
                if !appendSuccess {
                    self.logger.warning("第 \(frameIndex) 帧写入失败，writer 状态: \(writer.status.rawValue)")
                }
            }

            frameIndex += 1

            // 进度回调（每 1% 上报一次，减少主线程压力）
            let currentProgress = min(Double(frameIndex) / Double(totalFrames), 0.99)
            if currentProgress - lastProgressReport >= 0.01 || frameIndex == totalFrames {
                lastProgressReport = currentProgress
                Task { @MainActor in
                    progress(currentProgress)
                }
            }
        }

        // 检查 reader 最终状态
        if reader.status == .failed {
            if let error = reader.error {
                throw error
            }
            throw PipelineError.readerFailed
        }

        logger.info("解码完成，共处理 \(frameIndex) 帧，等待编码完成")

        // MARK: 完成写入
        writerInput.markAsFinished()

        // 使用信号量同步等待 finishWriting（在后台线程中安全）
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status == .completed {
            logger.info("视频编码完成，输出文件: \(outputURL.lastPathComponent, privacy: .public)")
            Task { @MainActor in
                progress(1.0)
                completion(.success(outputURL))
            }
        } else {
            let error = writer.error ?? PipelineError.writerFailed
            logger.error("视频编码失败: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

// MARK: - 错误定义
enum PipelineError: LocalizedError {
    case noVideoTrack
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

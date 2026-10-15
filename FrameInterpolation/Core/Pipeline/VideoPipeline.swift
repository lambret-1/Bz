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

        // 输出尺寸（编码尺寸，保留原始 transform）
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let outputWidth = Int(naturalSize.width)
        let outputHeight = Int(naturalSize.height)

        guard outputWidth > 0, outputHeight > 0 else {
            throw PipelineError.invalidVideoSize
        }

        print("[Bz音频诊断] 输入: \(outputWidth)x\(outputHeight), \(inputFPS)fps, 时长\(durationSeconds)s")
        print("[Bz音频诊断] 输出: \(outputFPS)fps, 倍数\(multiplier)x")

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

        // MARK: 配置独立音频 Reader（音频与视频完全隔离，PCM解码→AAC转码，避免透传兼容性问题）
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioSampleRate: Double = 44100.0
        var audioChannels: Int = 2
        if let audioTrack = loadedAudioTrack {
            // 读取源音频格式
            if let formatDesc = audioTrack.formatDescriptions.first as? CMAudioFormatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                audioSampleRate = asbd.pointee.mSampleRate
                audioChannels = Int(asbd.pointee.mChannelsPerFrame)
                print("[Bz音频诊断] 源音频格式: 采样率\(audioSampleRate)Hz, 通道\(audioChannels), 格式ID:\(asbd.pointee.mFormatID)")
            }

            do {
                let independentAudioReader = try AVAssetReader(asset: asset)
                // Reader 解码为 PCM（16位整型，小端，交错）
                let pcmSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
                if independentAudioReader.canAdd(audioOutput) {
                    independentAudioReader.add(audioOutput)
                    audioReader = independentAudioReader
                    audioReaderOutput = audioOutput
                    print("[Bz音频诊断] 独立音频 Reader 创建成功(PCM解码)，音频时长: \(CMTimeGetSeconds(audioTrack.timeRange.duration))s")
                } else {
                    print("[Bz音频诊断] 独立音频 Reader 无法添加 output")
                }
            } catch {
                print("[Bz音频诊断] 独立音频 Reader 创建失败: \(error.localizedDescription)")
            }
        } else {
            print("[Bz音频诊断] 无音频轨道，输出将无音频")
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

        // 音频写入（AAC转码，从源轨道获取采样率和通道数）
        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: 128000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioWriterInput = audioInput
                print("[Bz音频诊断] 音频 WriterInput 已添加(AAC \(Int(audioSampleRate))Hz \(audioChannels)ch 128kbps)")
            } else {
                print("[Bz音频诊断] Writer 无法添加音频 input")
            }
        }

        // MARK: 启动读写
        guard reader.startReading() else {
            throw PipelineError.readerStartFailed(reader.error ?? PipelineError.unknown)
        }
        let writerStarted = writer.startWriting()
        print("[Bz音频诊断] Writer startWriting 返回: \(writerStarted), 状态: \(writer.status.rawValue)")
        writer.startSession(atSourceTime: .zero)

        // MARK: 启动音频独立线程（与视频处理并行）
        let audioGroup = DispatchGroup()
        if let audioReader = audioReader, let audioRO = audioReaderOutput, let audioWI = audioWriterInput {
            audioGroup.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { audioGroup.leave(); return }
                self.audioStage(reader: audioReader, output: audioRO, writerInput: audioWI)
                audioGroup.leave()
            }
            print("[Bz音频诊断] 音频独立线程已启动")
        } else {
            print("[Bz音频诊断] 音频线程未启动: reader=\(audioReader != nil), output=\(audioReaderOutput != nil), writerInput=\(audioWriterInput != nil)")
        }

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
                            self.copyColorSpaceAttachments(from: pixelBuffer, to: midFrame)

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
        print("[Bz音频诊断] 视频处理完成，输出帧数: \(outputFrameIndex)，等待音频线程完成...")

        // 等待音频线程完成
        audioGroup.wait()
        audioWriterInput?.markAsFinished()
        print("[Bz音频诊断] 音频线程已完成，writer状态: \(writer.status.rawValue)")

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

    // MARK: - 音频独立线程（独立 Reader，连续读取写入）
    private func audioStage(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writerInput: AVAssetWriterInput) {
        guard reader.startReading() else {
            print("[Bz音频诊断] 音频 Reader startReading 失败: \(reader.error?.localizedDescription ?? "unknown")")
            return
        }
        print("[Bz音频诊断] 音频 Reader 已启动，开始读取写入")

        var sampleCount = 0
        while reader.status == .reading {
            if isCancelled {
                reader.cancelReading()
                break
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            // 等待 writer 就绪
            var waitCount = 0
            while !writerInput.isReadyForMoreMediaData {
                if isCancelled { reader.cancelReading(); return }
                Thread.sleep(forTimeInterval: 0.005)
                waitCount += 1
                if waitCount > 600 {
                    print("[Bz音频诊断] 音频 Writer 3秒未就绪，isReady: \(writerInput.isReadyForMoreMediaData)")
                    break
                }
            }

            autoreleasepool {
                if writerInput.append(sampleBuffer) {
                    sampleCount += 1
                } else {
                    print("[Bz音频诊断] 音频样本 append 失败，已写入\(sampleCount)个，isReady: \(writerInput.isReadyForMoreMediaData)")
                }
            }
        }

        if reader.status == .failed {
            print("[Bz音频诊断] 音频 Reader 失败: \(reader.error?.localizedDescription ?? "unknown")")
        }
        print("[Bz音频诊断] 音频线程结束，共写入 \(sampleCount) 个样本，reader状态: \(reader.status.rawValue)")
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

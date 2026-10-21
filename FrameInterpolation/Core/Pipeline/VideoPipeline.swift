import AVFoundation
import CoreVideo
import OSLog
import Accelerate

/// 视频处理管线：解码 → 补帧/超分 → 编码 + 音频透传
/// 支持补帧模式（2x/4x）与超分模式（Fast-SRGAN 4x / Real-ESRGAN 4x），两种模式互斥
/// 模型缺失时自动降级：补帧→空转（帧率不变），超分→vImage缩放
final class VideoPipeline {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPipeline")
    private var isCancelled = false
    /// 帧插值器，懒加载：首次进入补帧模式时才加载模型，避免启动时同步加载阻塞UI
    private lazy var interpolator: FrameInterpolator? = {
        let interp = FrameInterpolator()
        if interp == nil {
            logger.warning("RIFE Lite 模型未加载，补帧管线将以空转模式运行（帧率不变）")
        } else {
            logger.info("RIFE Lite 模型加载成功，补帧功能已启用")
        }
        return interp
    }()
    /// 后台处理队列
    private let processingQueue = DispatchQueue(label: "com.lambret.bz.pipeline", qos: .userInitiated)

    /// CVPixelBuffer 内存池（复用缓冲，避免循环中频繁分配释放）
    private let bufferPool = PixelBufferPoolManager(minBufferCount: 12)

    /// 原子进度保护（iOS 16+ OSAllocatedUnfairLock，开销仅为 NSLock 的几十分之一）
    private let progressLock = OSAllocatedUnfairLock(initialState: (value: 0.0, stage: ProcessingStage.decoding))

    /// 轮询当前进度（线程安全，供外部 Timer 每 0.5s 调用一次）
    func pollProgress() -> (value: Double, stage: ProcessingStage) {
        progressLock.withLock { ($0.value, $0.stage) }
    }

    /// 内部更新进度（只写原子变量，不切主线程）
    private func updateProgress(_ value: Double, stage: ProcessingStage) {
        progressLock.withLock {
            $0.value = value
            $0.stage = stage
        }
    }

    /// 音频诊断结果（供结果页展示，不依赖Xcode控制台）
    static var 音频诊断结果: String = "未执行"

    /// 是否使用 AI 补帧（模型文件存在即视为可用，实际加载在首次补帧时完成）
    var isUsingAIInterpolation: Bool = true

    /// 当前使用的超分引擎类型（处理完成后供结果页查询）
    private(set) var currentSuperResolutionEngine: SuperResolutionEngineType?

    init() {
        // 模型懒加载，启动时不加载任何模型，避免阻塞UI
    }

    // MARK: - 公开方法

    /// 开始处理视频（补帧模式，向后兼容接口）
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
        let frameMultiplier = FrameMultiplier(rawValue: multiplier) ?? .x2
        process(
            inputURL: inputURL,
            outputURL: outputURL,
            mode: .interpolation(frameMultiplier),
            fastMode: fastMode,
            outputResolution: outputResolution,
            progress: progress,
            completion: completion
        )
    }

    /// 开始处理视频（统一入口，支持补帧与超分双模式）
    /// - Parameters:
    ///   - inputURL: 输入视频文件 URL
    ///   - outputURL: 输出视频文件 URL
    ///   - mode: 处理模式（补帧或超分，二者互斥）
    ///   - fastMode: 快速模式（仅补帧模式生效）
    ///   - outputResolution: 输出分辨率限制
    ///   - progress: 进度回调（0.0~1.0, 当前阶段），主线程调用
    ///   - completion: 完成回调，主线程调用
    func process(
        inputURL: URL,
        outputURL: URL,
        mode: PipelineMode,
        fastMode: Bool = false,
        outputResolution: OutputResolution = .auto,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        isCancelled = false
        currentSuperResolutionEngine = nil

        let effectiveMultiplier: Int
        let modeDescription: String
        switch mode {
        case .interpolation(let m):
            effectiveMultiplier = interpolator != nil ? m.rawValue : 1
            modeDescription = "补帧\(effectiveMultiplier)x"
        case .superResolution(let engineType, let scale):
            effectiveMultiplier = 1 // 超分模式帧率不变
            currentSuperResolutionEngine = engineType
            modeDescription = "超分\(engineType.shortName)\(scale.label)"
        }

        logger.info("开始处理: \(inputURL.lastPathComponent, privacy: .public), 模式:\(modeDescription), 快速模式:\(fastMode), 分辨率:\(outputResolution.rawValue)")

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.runPipeline(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    mode: mode,
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
        mode: PipelineMode,
        multiplier: Int,
        fastMode: Bool,
        outputResolution: OutputResolution,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)

        // 同步加载轨道（iOS 16 中 tracks(withMediaType:) 会阻塞等待元数据加载，比异步 loadTracks 更可靠）
        let loadedVideoTrack = asset.tracks(withMediaType: .video).first
        let loadedAudioTrack = asset.tracks(withMediaType: .audio).first

        print("[Bz音频诊断] 视频轨道: \(loadedVideoTrack != nil ? "有" : "无"), 音频轨道: \(loadedAudioTrack != nil ? "有" : "无")")
        if let audioTrack = loadedAudioTrack {
            print("[Bz音频诊断] 音频格式: \(audioTrack.formatDescriptions), 估计码率: \(audioTrack.estimatedDataRate)bps")
        }

        // 获取视频轨道
        guard let videoTrack = loadedVideoTrack else {
            throw PipelineError.noVideoTrack
        }

        // 帧率与帧数计算
        let inputFPS = Double(videoTrack.nominalFrameRate)
        guard inputFPS > 0 else {
            throw PipelineError.invalidFrameRate
        }

        // 超分模式帧率不变，补帧模式按倍数提升
        let outputFPS: Double
        /// 用户选择的超分放大倍数（1-4x）
        let targetScale: Int
        /// 模型原生放大倍数（固定 4x）
        let nativeScale: Int
        switch mode {
        case .interpolation:
            outputFPS = inputFPS * Double(multiplier)
            targetScale = 1
            nativeScale = 1
        case .superResolution(let engineType, let scale):
            outputFPS = inputFPS // 超分模式帧率保持不变
            targetScale = scale.rawValue
            nativeScale = engineType.nativeScaleFactor
        }

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let totalInputFrames = max(Int(durationSeconds * inputFPS), 1)

        // 输出尺寸（按用户选择的放大倍数计算）
        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        var outputWidth = Int(naturalSize.width) * targetScale
        var outputHeight = Int(naturalSize.height) * targetScale

        // 计算目标短边（自动识别横竖屏，保持宽高比）
        let targetShortSide: Int?
        switch outputResolution {
        case .auto:
            targetShortSide = nil
        case .p720:
            targetShortSide = 720
        case .p1080:
            targetShortSide = 1080
        }

        var needsScaling = false
        if let targetShort = targetShortSide {
            let currentShort = min(outputWidth, outputHeight)
            if currentShort > targetShort {
                let scale = Double(targetShort) / Double(currentShort)
                outputWidth = Int(Double(outputWidth) * scale)
                outputHeight = Int(Double(outputHeight) * scale)
                // 确保宽高为偶数（H.264 编码要求）
                outputWidth = outputWidth - (outputWidth % 2)
                outputHeight = outputHeight - (outputHeight % 2)
                needsScaling = true
            }
        }

        guard outputWidth > 0, outputHeight > 0 else {
            throw PipelineError.invalidVideoSize
        }

        print("[Bz音频诊断] 输入: \(Int(naturalSize.width))x\(Int(naturalSize.height)), 输出: \(outputWidth)x\(outputHeight), 缩放:\(needsScaling), 快速模式:\(fastMode)")
        print("[Bz音频诊断] 输出: \(outputFPS)fps, 模式:\(mode.displayName)")

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

        // MARK: 配置音频 Reader（直写模式，不再二次编码）
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = loadedAudioTrack {
            // 音频 Reader 输出 PCM 格式（解码），Writer 用 AAC 编码
            // 透传模式(outputSettings:nil)在部分视频上不稳定，PCM→AAC 更可靠
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
            output.alwaysCopiesSampleData = true
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
                print("[Bz音频诊断] 音频模式：PCM解码→AAC编码，已配置音频 Reader")
            } else {
                print("[Bz音频诊断] 音频 Reader 添加失败，reader状态: \(reader.status.rawValue)")
            }
        }

        // MARK: 配置 Writer（音视频同时写入，消除二次编码）
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // 按像素数比例动态计算码率，优先使用 HEVC 降低开销
        // 原理：放大分辨率 = 像素数增加 = 需要更高码率承载新增细节
        // HEVC 相比 H.264 压缩效率提升约 40%，相同画质下码率可降低
        let inputWidth = Int(naturalSize.width)
        let inputHeight = Int(naturalSize.height)
        let inputPixelCount = max(inputWidth * inputHeight, 1)
        let outputPixelCount = outputWidth * outputHeight
        let pixelScaleRatio = Double(outputPixelCount) / Double(inputPixelCount)

        // 输入视频原始码率（estimatedDataRate 单位 bps）
        let inputBitRate = Double(videoTrack.estimatedDataRate)
        // 基础码率：输入码率 × 像素数放大比例；输入码率无效时按分辨率兜底
        let baseBitRate: Double
        if inputBitRate > 100_000 {
            baseBitRate = inputBitRate * pixelScaleRatio
        } else {
            // 兜底：按输出像素数计算，每百万像素约 4Mbps（HEVC）
            baseBitRate = Double(outputPixelCount) / 1_000_000.0 * 4_000_000
        }

        // HEVC 效率系数：相同画质下比 H.264 节省约 35% 码率
        let hevcEfficiencyFactor = 0.65
        // 码率上下限：最低 2Mbps，最高 60Mbps（避免超大文件）
        let targetBitRate = max(2_000_000, min(60_000_000, Int(baseBitRate * hevcEfficiencyFactor)))

        logger.info("编码配置: HEVC, 输入码率 \(inputBitRate/1_000_000)Mbps, 像素放大 \(String(format: "%.2f", pixelScaleRatio))x, 输出码率 \(Double(targetBitRate)/1_000_000)Mbps")

        // 优先使用 HEVC，不支持时降级为 H.264（码率相应提高，因为 H.264 效率较低）
        let videoWriterInput: AVAssetWriterInput
        if let hevcInput = makeVideoWriterInput(
            codec: .hevc,
            width: outputWidth,
            height: outputHeight,
            bitRate: targetBitRate,
            writer: writer
        ) {
            videoWriterInput = hevcInput
            logger.info("使用 HEVC 编码")
        } else {
            let h264BitRate = min(80_000_000, Int(Double(targetBitRate) / hevcEfficiencyFactor))
            videoWriterInput = makeVideoWriterInput(
                codec: .h264,
                width: outputWidth,
                height: outputHeight,
                bitRate: h264BitRate,
                writer: writer
            )!
            logger.warning("HEVC 不可用，降级为 H.264 编码，码率 \(Double(h264BitRate)/1_000_000)Mbps")
        }
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

        // MARK: 配置音频 Writer Input（透传原格式，不重编码）
        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            // 从音频轨道获取声道数和采样率，用于 AAC 编码配置
            let audioFormatDesc = loadedAudioTrack?.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let audioChannels = audioFormatDesc.flatMap { desc -> Int? in
                let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                return Int(basicDesc?.pointee.mChannelsPerFrame ?? 2)
            } ?? 2
            let audioSampleRate = audioFormatDesc.flatMap { desc -> Double? in
                let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                return basicDesc?.pointee.mSampleRate
            } ?? 44100

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: audioChannels,
                AVSampleRateKey: audioSampleRate,
                AVEncoderBitRateKey: 128000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
                print("[Bz音频诊断] 音频模式：已配置 AAC 编码 Writer Input，声道:\(audioChannels)，采样率:\(audioSampleRate)")
            } else {
                print("[Bz音频诊断] 音频 Writer Input 添加失败，writer状态: \(writer.status.rawValue)")
            }
        }

        // MARK: 启动读写
        guard reader.startReading() else {
            throw PipelineError.readerStartFailed(reader.error ?? PipelineError.unknown)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        Self.音频诊断结果 = audioWriterInput != nil ? "音视频编码中" : "无声视频处理中"

        // MARK: 启动音频直写（独立队列，与视频处理并行）
        let audioEncodeGroup = DispatchGroup()
        if let audioInput = audioWriterInput, let audioOutput = audioReaderOutput {
            audioEncodeGroup.enter()
            let audioQueue = DispatchQueue(label: "com.lambret.bz.audio.encode", qos: .userInitiated)
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        audioEncodeGroup.leave()
                        return
                    }
                    // PTS 直接透传，音视频同源保持同步
                    if !audioInput.append(sample) {
                        print("[Bz音频诊断] 音频 append 失败: \(writer.error?.localizedDescription ?? "未知")，停止音频写入")
                        audioInput.markAsFinished()
                        audioEncodeGroup.leave()
                        return
                    }
                }
            }
            print("[Bz音频诊断] 音频直写已启动")
        }

        // MARK: 视频处理循环（按模式分发）
        var outputFrameIndex = 0
        var lastProgressReport = 0.0

        switch mode {
        case .interpolation:
            try runInterpolationAsync(
                reader: reader,
                videoReaderOutput: videoReaderOutput,
                writer: writer,
                videoWriterInput: videoWriterInput,
                pixelBufferAdaptor: pixelBufferAdaptor,
                outputFPS: outputFPS,
                multiplier: multiplier,
                fastMode: fastMode,
                needsScaling: needsScaling,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                totalInputFrames: totalInputFrames,
                progress: progress,
                outputFrameIndex: &outputFrameIndex,
                lastProgressReport: &lastProgressReport
            )
        case .superResolution(let engineType, let scale):
            try runSuperResolutionAsync(
                reader: reader,
                videoReaderOutput: videoReaderOutput,
                writer: writer,
                videoWriterInput: videoWriterInput,
                pixelBufferAdaptor: pixelBufferAdaptor,
                outputFPS: outputFPS,
                engineType: engineType,
                targetScale: scale,
                nativeScale: nativeScale,
                needsScaling: needsScaling,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                totalInputFrames: totalInputFrames,
                progress: progress,
                outputFrameIndex: &outputFrameIndex,
                lastProgressReport: &lastProgressReport
            )
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

        // 等待音频编码完成（如果有音频）
        if audioWriterInput != nil {
            print("[Bz音频诊断] 等待音频编码完成...")
            audioEncodeGroup.wait()
            print("[Bz音频诊断] 音频编码完成")
        }

        // MARK: 完成写入（音视频都已 markAsFinished）
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            let error = writer.error ?? PipelineError.writerFailed
            logger.error("编码失败: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        Self.音频诊断结果 = audioWriterInput != nil ? "音视频编码完成" : "无声视频处理完成"
        print("[Bz音频诊断] 全部完成，输出: \(outputURL.lastPathComponent)")

        // 释放内存池
        bufferPool.reset()

        Task { @MainActor in
            progress(1.0, .finished)
            completion(.success(outputURL))
        }
    }

    // MARK: - 补帧模式处理循环

    private func runInterpolationLoop(
        reader: AVAssetReader,
        videoReaderOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        videoWriterInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputFPS: Double,
        multiplier: Int,
        fastMode: Bool,
        needsScaling: Bool,
        outputWidth: Int,
        outputHeight: Int,
        totalInputFrames: Int,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        outputFrameIndex: inout Int,
        lastProgressReport: inout Double
    ) throws {
        var previousPixelBuffer: CVPixelBuffer?

        // 局部函数：写入中间帧（复制颜色空间+缩放+写入Writer）
        func writeIntermediateFrame(_ frame: CVPixelBuffer, source: CVPixelBuffer) {
            if isCancelled { return }
            copyColorSpaceAttachments(from: source, to: frame)
            let finalFrame = needsScaling ? scalePixelBuffer(frame, to: outputWidth, outputHeight) ?? frame : frame
            let midPTS = CMTime(value: Int64(outputFrameIndex), timescale: Int32(outputFPS))
            waitForWriterReady(videoWriterInput)
            pixelBufferAdaptor.append(finalFrame, withPresentationTime: midPTS)
            outputFrameIndex += 1
        }

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
                // 进度防抖：只写原子变量，由外部 Timer 轮询更新 UI，避免高频主线程回调
                updateProgress(progressValue, stage: stage)
            }

            autoreleasepool {
                // 如果有前一帧且插值器可用，生成中间帧（RIFE分层递归策略）
                if let prev = previousPixelBuffer, multiplier > 1 {
                    let motion = fastMode ? estimateMotion(frame0: prev, frame1: pixelBuffer) : 255
                    let highMotion = motion >= 8.0
                    let useAI = !fastMode || highMotion

                    if multiplier == 2 {
                        let midFrame = useAI
                            ? self.interpolator?.interpolate(frame0: prev, frame1: pixelBuffer)
                            : self.blendFrames(prev, pixelBuffer)
                        writeIntermediateFrame(midFrame ?? self.deepCopyPixelBuffer(prev) ?? prev, source: pixelBuffer)
                    } else if multiplier == 4 {
                        let mid05 = self.interpolator?.interpolate(frame0: prev, frame1: pixelBuffer)
                            ?? self.deepCopyPixelBuffer(prev) ?? prev
                        let mid025 = useAI
                            ? self.interpolator?.interpolate(frame0: prev, frame1: mid05)
                            : self.blendFrames(prev, mid05)
                        writeIntermediateFrame(mid025 ?? self.deepCopyPixelBuffer(prev) ?? prev, source: pixelBuffer)
                        writeIntermediateFrame(mid05, source: pixelBuffer)
                        let mid075 = useAI
                            ? self.interpolator?.interpolate(frame0: mid05, frame1: pixelBuffer)
                            : self.blendFrames(mid05, pixelBuffer)
                        writeIntermediateFrame(mid075 ?? self.deepCopyPixelBuffer(pixelBuffer) ?? pixelBuffer, source: pixelBuffer)
                    } else {
                        for _ in 1..<multiplier {
                            if self.isCancelled { return }
                            let midFrame = useAI
                                ? self.interpolator?.interpolate(frame0: prev, frame1: pixelBuffer)
                                : self.blendFrames(prev, pixelBuffer)
                            writeIntermediateFrame(midFrame ?? self.deepCopyPixelBuffer(prev) ?? prev, source: pixelBuffer)
                        }
                    }
                }

                // 写入当前原始帧（输出分辨率缩放）
                let finalFrame = needsScaling ? self.scalePixelBuffer(pixelBuffer, to: outputWidth, outputHeight) ?? pixelBuffer : pixelBuffer
                let currentPTS = CMTime(value: Int64(outputFrameIndex), timescale: Int32(outputFPS))
                self.waitForWriterReady(videoWriterInput)
                pixelBufferAdaptor.append(finalFrame, withPresentationTime: currentPTS)
                outputFrameIndex += 1
            }

            previousPixelBuffer = deepCopyPixelBuffer(pixelBuffer) ?? pixelBuffer
        }
    }

    // MARK: - 超分模式处理循环

    private func runSuperResolutionLoop(
        reader: AVAssetReader,
        videoReaderOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        videoWriterInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputFPS: Double,
        engineType: SuperResolutionEngineType,
        targetScale: SuperResolutionScale,
        nativeScale: Int,
        needsScaling: Bool,
        outputWidth: Int,
        outputHeight: Int,
        totalInputFrames: Int,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        outputFrameIndex: inout Int,
        lastProgressReport: inout Double
    ) throws {
        // 1x 模式或模型缺失时跳过 AI 超分，直接复制/缩放帧
        let needsAI = targetScale.needsAISuperResolution
        let engine = needsAI ? SuperResolutionEngineFactory.makeEngine(type: engineType) : nil
        let usingAI = engine != nil
        if needsAI && engine == nil {
            logger.warning("\(engineType.displayName) 模型未加载，超分模式降级为 vImage 缩放")
        }
        if !needsAI {
            logger.info("超分倍数 1x，跳过 AI 推理，直接透传帧")
        }

        var inputFrameIndex = 0

        // 超分处理较慢，立即报告初始进度，避免用户误以为卡死
        Task { @MainActor in
            progress(0.0, usingAI ? .superResolving : .decoding)
        }

        while reader.status == .reading {
            if isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                engine?.cancel()
                throw PipelineError.cancelled
            }

            guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            // 进度计算（超分模式一进一出，inputFrameIndex == outputFrameIndex）
            let progressValue = min(Double(inputFrameIndex) / Double(totalInputFrames), 0.99)
            if progressValue - lastProgressReport >= 0.01 {
                lastProgressReport = progressValue
                let stage: ProcessingStage = usingAI ? .superResolving : .decoding
                // 进度防抖：只写原子变量，由外部 Timer 轮询更新 UI
                updateProgress(progressValue, stage: stage)
            }

            autoreleasepool {
                let processedFrame: CVPixelBuffer

                if !needsAI {
                    // 1x 模式：直接使用原帧
                    processedFrame = pixelBuffer
                } else if let engine = engine,
                          let aiFrame = engine.upscale(pixelBuffer) {
                    // AI 超分（原生 4x），若目标倍数 < 4x 则缩放到目标尺寸
                    if targetScale.rawValue < nativeScale {
                        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
                        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
                        let targetW = srcWidth * targetScale.rawValue
                        let targetH = srcHeight * targetScale.rawValue
                        processedFrame = self.scalePixelBuffer(aiFrame, to: targetW, targetH) ?? aiFrame
                    } else {
                        processedFrame = aiFrame
                    }
                } else {
                    // 降级：vImage 缩放到目标尺寸
                    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
                    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
                    let targetW = srcWidth * targetScale.rawValue
                    let targetH = srcHeight * targetScale.rawValue
                    processedFrame = self.scalePixelBuffer(pixelBuffer, to: targetW, targetH) ?? pixelBuffer
                }

                // 复制颜色空间附件
                copyColorSpaceAttachments(from: pixelBuffer, to: processedFrame)

                // 最终输出缩放（根据 outputResolution 限制）
                let finalFrame = needsScaling ? self.scalePixelBuffer(processedFrame, to: outputWidth, outputHeight) ?? processedFrame : processedFrame

                // 超分模式帧率不变，PTS 按 outputFPS 等间隔排列
                let currentPTS = CMTime(value: Int64(outputFrameIndex), timescale: Int32(outputFPS))
                self.waitForWriterReady(videoWriterInput)
                pixelBufferAdaptor.append(finalFrame, withPresentationTime: currentPTS)
                outputFrameIndex += 1
                inputFrameIndex += 1
            }
        }
    }

    // MARK: - 异步超分管线（解码+推理与编码并发）

    /// 异步超分管线：解码+推理在独立队列，编码由 requestMediaDataWhenReady 驱动
    /// 通过有界 FrameBuffer 实现背压，避免内存爆炸
    private func runSuperResolutionAsync(
        reader: AVAssetReader,
        videoReaderOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        videoWriterInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputFPS: Double,
        engineType: SuperResolutionEngineType,
        targetScale: SuperResolutionScale,
        nativeScale: Int,
        needsScaling: Bool,
        outputWidth: Int,
        outputHeight: Int,
        totalInputFrames: Int,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        outputFrameIndex: inout Int,
        lastProgressReport: inout Double
    ) throws {
        // 1x 模式或模型缺失时跳过 AI 超分
        let needsAI = targetScale.needsAISuperResolution
        let engine = needsAI ? SuperResolutionEngineFactory.makeEngine(type: engineType) : nil
        let usingAI = engine != nil
        if needsAI && engine == nil {
            logger.warning("\(engineType.displayName) 模型未加载，超分模式降级为 vImage 缩放")
        }

        // 立即报告初始进度
        Task { @MainActor in
            progress(0.0, usingAI ? .superResolving : .decoding)
        }

        // 启动诊断日志会话
        DiagnosticLogger.shared.startSession()
        DiagnosticLogger.shared.writeLine("模式: \(usingAI ? engineType.displayName : "vImage缩放")")
        DiagnosticLogger.shared.writeLine("输入: \(totalInputFrames)帧, 输出: \(outputWidth)x\(outputHeight)")
        DiagnosticLogger.shared.writeLine("----------------------------------------")

        // MARK: 黄金三队列流水线
        // Reader（只读不拷）→ Inference（深拷贝+ANE+缩放）→ Encode
        // 队列容量：Reader→Inference(6)、Inference→Encode(10)
        let readerToInference = FrameBuffer(capacity: 6)
        let inferenceToEncode = FrameBuffer(capacity: 10)

        let readerQueue = DispatchQueue(label: "com.lambret.bz.sr.reader", qos: .userInitiated)
        let inferenceQueue = DispatchQueue(label: "com.lambret.bz.sr.inference", qos: .userInitiated)
        let encodeQueue = DispatchQueue(label: "com.lambret.bz.sr.encode", qos: .userInitiated)

        // 跨队列错误传递
        let errorLock = NSLock()
        var pipelineError: Error?

        func setError(_ error: Error) {
            errorLock.lock()
            if pipelineError == nil { pipelineError = error }
            errorLock.unlock()
        }

        // 关闭所有队列（cancel或错误时调用）
        func closeAllQueues() {
            readerToInference.close()
            inferenceToEncode.close()
        }

        // MARK: 队列1：Reader（只调copyNextSampleBuffer，不深拷贝，IO密集型独立队列）
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        readerQueue.async { [weak self] in
            guard let self = self else {
                readerToInference.close()
                readerGroup.leave()
                return
            }

            var localFrameIndex = 0
            var localProgress = 0.0

            defer {
                readerToInference.close()
                readerGroup.leave()
            }

            while reader.status == .reading {
                if self.isCancelled {
                    reader.cancelReading()
                    setError(PipelineError.cancelled)
                    return
                }

                guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    break
                }

                // 进度计算（在Reader阶段更新，因为帧率不变）
                let progressValue = min(Double(localFrameIndex) / Double(totalInputFrames), 0.99)
                if progressValue - localProgress >= 0.01 {
                    localProgress = progressValue
                    let stage: ProcessingStage = usingAI ? .superResolving : .decoding
                    updateProgress(progressValue, stage: stage)
                }

                // 直接传递原始CVPixelBuffer（引用计数retain，reader不会复用）
                // 深拷贝放到Inference队列，与ANE计算在同一线程，共享L1 Cache
                let pts = CMTime(value: Int64(localFrameIndex), timescale: Int32(outputFPS))
                if !readerToInference.enqueue(ProcessedFrame(pixelBuffer: pixelBuffer, presentationTime: pts)) {
                    return
                }

                localFrameIndex += 1
            }
        }

        // MARK: 队列2：Inference（深拷贝→ANE推理→vImage缩放，全部在同一线程）
        let inferenceGroup = DispatchGroup()
        inferenceGroup.enter()
        inferenceQueue.async { [weak self] in
            guard let self = self else {
                inferenceToEncode.close()
                inferenceGroup.leave()
                return
            }

            defer {
                inferenceToEncode.close()
                inferenceGroup.leave()
            }

            var frameIndex = 0
            while true {
                if self.isCancelled {
                    setError(PipelineError.cancelled)
                    return
                }

                let t0 = CACurrentMediaTime()
                // 从Reader队列取原始帧
                guard let frame = readerToInference.dequeue() else {
                    break
                }
                let t1 = CACurrentMediaTime()

                autoreleasepool {
                    // 1. 深拷贝（reader的buffer生命周期由reader管理，必须拷贝）
                    guard let copiedFrame = self.deepCopyPixelBuffer(frame.pixelBuffer) else { return }
                    let t2 = CACurrentMediaTime()

                    // 2. ANE推理
                    let aiFrame: CVPixelBuffer
                    if !needsAI {
                        aiFrame = copiedFrame
                    } else if let engine = engine {
                        guard let upscaled = engine.upscale(copiedFrame) else {
                            self.logger.error("第\(frameIndex)帧超分推理失败，引擎返回nil")
                            self.setError(PipelineError.unknown)
                            return
                        }
                        aiFrame = upscaled
                    } else {
                        self.logger.error("超分引擎未初始化")
                        self.setError(PipelineError.unknown)
                        return
                    }
                    let t3 = CACurrentMediaTime()

                    // 3. vImage统一缩放到最终输出尺寸（一步到位）
                    var finalFrame = aiFrame
                    let currentWidth = CVPixelBufferGetWidth(finalFrame)
                    let currentHeight = CVPixelBufferGetHeight(finalFrame)
                    if currentWidth != outputWidth || currentHeight != outputHeight {
                        if let scaled = self.scalePixelBuffer(finalFrame, to: outputWidth, outputHeight) {
                            finalFrame = scaled
                        }
                    }
                    let t4 = CACurrentMediaTime()

                    // 4. 复制颜色空间附件
                    self.copyColorSpaceAttachments(from: frame.pixelBuffer, to: finalFrame)

                    // 5. 入队到Encode
                    if !inferenceToEncode.enqueue(ProcessedFrame(pixelBuffer: finalFrame, presentationTime: frame.presentationTime)) {
                        return
                    }
                    let t5 = CACurrentMediaTime()

                    // 诊断日志（每10帧打印一次，同时写入文件）
                    if frameIndex % 10 == 0 {
                        let logLine = "帧\(frameIndex) 等待出队:\(String(format: "%.3f", t1-t0))s 深拷:\(String(format: "%.3f", t2-t1))s 推理:\(String(format: "%.3f", t3-t2))s 缩放:\(String(format: "%.3f", t4-t3))s 入队:\(String(format: "%.3f", t5-t4))s"
                        self.logger.info("\(logLine)")
                        DiagnosticLogger.shared.writeLine(logLine)
                    }
                    frameIndex += 1
                }
            }
        }

        // MARK: 队列3：Encode（requestMediaDataWhenReady驱动）
        let encodeGroup = DispatchGroup()
        encodeGroup.enter()
        var encodeFinished = false
        let finishEncode = {
            if !encodeFinished {
                encodeFinished = true
                videoWriterInput.markAsFinished()
                encodeGroup.leave()
            }
        }
        videoWriterInput.requestMediaDataWhenReady(on: encodeQueue) { [weak self] in
            guard let self = self else {
                finishEncode()
                return
            }

            while videoWriterInput.isReadyForMoreMediaData {
                // 从Inference队列取帧
                guard let frame = inferenceToEncode.dequeue() else {
                    finishEncode()
                    return
                }

                if self.isCancelled {
                    self.setError(PipelineError.cancelled)
                    finishEncode()
                    return
                }

                // 追加到writer
                let appended = pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
                if !appended {
                    if writer.status == .failed {
                        self.setError(writer.error ?? PipelineError.writerFailed)
                    }
                    finishEncode()
                    return
                }
            }
        }

        // 等待Reader和Inference完成
        readerGroup.wait()
        inferenceGroup.wait()

        // 检查前置队列错误
        errorLock.lock()
        let preError = pipelineError
        errorLock.unlock()

        if let error = preError {
            closeAllQueues()
            if writer.status == .writing {
                writer.cancelWriting()
            }
            engine?.cancel()
            throw error
        }

        // 等待编码完成
        encodeGroup.wait()

        // 检查编码端错误
        errorLock.lock()
        let encodeError = pipelineError
        errorLock.unlock()

        if let error = encodeError {
            if case PipelineError.cancelled = error {
                throw error
            }
            if writer.status == .failed {
                throw writer.error ?? error
            }
            throw error
        }

        // 检查reader最终状态
        if reader.status == .failed {
            if let error = reader.error {
                throw error
            }
            throw PipelineError.readerFailed
        }

        // 输出帧数 = Inference队列的入队数
        let finalFrameCount = inferenceToEncode.totalEnqueued
        outputFrameIndex = finalFrameCount
        logger.info("黄金三队列超分管线完成，输出帧数: \(finalFrameCount)")

        // 结束诊断日志会话
        DiagnosticLogger.shared.writeLine("----------------------------------------")
        DiagnosticLogger.shared.writeLine("输出帧数: \(finalFrameCount)")
        DiagnosticLogger.shared.endSession()
    }

    // MARK: - 异步补帧管线（解码+推理与编码并发）

    /// 异步补帧管线：解码+推理在独立队列，编码由 requestMediaDataWhenReady 驱动
    private func runInterpolationAsync(
        reader: AVAssetReader,
        videoReaderOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        videoWriterInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputFPS: Double,
        multiplier: Int,
        fastMode: Bool,
        needsScaling: Bool,
        outputWidth: Int,
        outputHeight: Int,
        totalInputFrames: Int,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        outputFrameIndex: inout Int,
        lastProgressReport: inout Double
    ) throws {
        let frameBuffer = FrameBuffer(capacity: 8)
        let decodeQueue = DispatchQueue(label: "com.lambret.bz.fi.decode", qos: .userInitiated)
        let encodeQueue = DispatchQueue(label: "com.lambret.bz.fi.encode", qos: .userInitiated)

        let errorLock = NSLock()
        var pipelineError: Error?
        var localOutputFrameCount = 0

        func setError(_ error: Error) {
            errorLock.lock()
            if pipelineError == nil { pipelineError = error }
            errorLock.unlock()
        }

        // MARK: 解码+推理队列
        let decodeGroup = DispatchGroup()
        decodeGroup.enter()
        decodeQueue.async { [weak self] in
            guard let self = self else {
                frameBuffer.close()
                decodeGroup.leave()
                return
            }

            var previousPixelBuffer: CVPixelBuffer?
            var localFrameIndex = 0
            var localProgress = 0.0

            // 确保解码队列退出时关闭缓冲队列，唤醒编码端
            defer {
                frameBuffer.close()
                localOutputFrameCount = localFrameIndex
                decodeGroup.leave()
            }

            // 局部函数：处理并入队一帧
            func enqueueFrame(_ frame: CVPixelBuffer, source: CVPixelBuffer) -> Bool {
                if self.isCancelled { return false }
                self.copyColorSpaceAttachments(from: source, to: frame)
                let finalFrame = needsScaling
                    ? self.scalePixelBuffer(frame, to: outputWidth, outputHeight) ?? frame
                    : frame
                let pts = CMTime(value: Int64(localFrameIndex), timescale: Int32(outputFPS))
                let ok = frameBuffer.enqueue(ProcessedFrame(pixelBuffer: finalFrame, presentationTime: pts))
                if ok { localFrameIndex += 1 }
                return ok
            }

            while reader.status == .reading {
                if self.isCancelled {
                    reader.cancelReading()
                    setError(PipelineError.cancelled)
                    return
                }

                guard let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    break
                }

                // 进度计算
                let inputFrameIndex = localFrameIndex / max(multiplier, 1)
                let progressValue = min(Double(inputFrameIndex) / Double(totalInputFrames), 0.99)
                if progressValue - localProgress >= 0.01 {
                    localProgress = progressValue
                    let stage: ProcessingStage = self.interpolator != nil ? .inferring : .decoding
                    // 进度防抖：只写原子变量，由外部 Timer 轮询更新 UI
                    updateProgress(progressValue, stage: stage)
                }

                autoreleasepool {
                    // 深拷贝当前帧（alwaysCopiesSampleData=false 时原帧由 reader 管理）
                    let currentFrame = self.deepCopyPixelBuffer(pixelBuffer) ?? pixelBuffer

                    // 如果有前一帧且插值器可用，生成中间帧
                    if let prev = previousPixelBuffer, multiplier > 1 {
                        let motion = fastMode ? self.estimateMotion(frame0: prev, frame1: currentFrame) : 255
                        let highMotion = motion >= 8.0
                        let useAI = !fastMode || highMotion

                        if multiplier == 2 {
                            let midFrame = useAI
                                ? self.interpolator?.interpolate(frame0: prev, frame1: currentFrame)
                                : self.blendFrames(prev, currentFrame)
                            if !enqueueFrame(midFrame ?? self.deepCopyPixelBuffer(prev) ?? prev, source: currentFrame) { return }
                        } else if multiplier == 4 {
                            let mid05 = self.interpolator?.interpolate(frame0: prev, frame1: currentFrame)
                                ?? self.deepCopyPixelBuffer(prev) ?? prev
                            let mid025 = useAI
                                ? self.interpolator?.interpolate(frame0: prev, frame1: mid05)
                                : self.blendFrames(prev, mid05)
                            if !enqueueFrame(mid025 ?? self.deepCopyPixelBuffer(prev) ?? prev, source: currentFrame) { return }
                            if !enqueueFrame(mid05, source: currentFrame) { return }
                            let mid075 = useAI
                                ? self.interpolator?.interpolate(frame0: mid05, frame1: currentFrame)
                                : self.blendFrames(mid05, currentFrame)
                            if !enqueueFrame(mid075 ?? self.deepCopyPixelBuffer(currentFrame) ?? currentFrame, source: currentFrame) { return }
                        } else {
                            for _ in 1..<multiplier {
                                if self.isCancelled { return }
                                let midFrame = useAI
                                    ? self.interpolator?.interpolate(frame0: prev, frame1: currentFrame)
                                    : self.blendFrames(prev, currentFrame)
                                if !enqueueFrame(midFrame ?? self.deepCopyPixelBuffer(prev) ?? prev, source: currentFrame) { return }
                            }
                        }
                    }

                    // 写入当前原始帧
                    if !enqueueFrame(currentFrame, source: currentFrame) { return }

                    // 更新前一帧
                    previousPixelBuffer = currentFrame
                }
            }
        }

        // MARK: 编码队列
        let encodeGroup = DispatchGroup()
        encodeGroup.enter()
        var encodeFinished = false
        let finishEncode = {
            if !encodeFinished {
                encodeFinished = true
                videoWriterInput.markAsFinished()
                encodeGroup.leave()
            }
        }
        videoWriterInput.requestMediaDataWhenReady(on: encodeQueue) { [weak self] in
            guard let self = self else {
                finishEncode()
                return
            }

            while videoWriterInput.isReadyForMoreMediaData {
                guard let frame = frameBuffer.dequeue() else {
                    finishEncode()
                    return
                }

                if self.isCancelled {
                    self.setError(PipelineError.cancelled)
                    finishEncode()
                    return
                }

                let appended = pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
                if !appended {
                    if writer.status == .failed {
                        self.setError(writer.error ?? PipelineError.writerFailed)
                    }
                    finishEncode()
                    return
                }
            }
        }

        // 等待解码+推理完成
        decodeGroup.wait()

        errorLock.lock()
        let decodeError = pipelineError
        errorLock.unlock()

        if let error = decodeError {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw error
        }

        // 等待编码完成
        encodeGroup.wait()

        errorLock.lock()
        let encodeError = pipelineError
        errorLock.unlock()

        if let error = encodeError {
            if case PipelineError.cancelled = error {
                throw error
            }
            if writer.status == .failed {
                throw writer.error ?? error
            }
            throw error
        }

        if reader.status == .failed {
            if let error = reader.error {
                throw error
            }
            throw PipelineError.readerFailed
        }

        outputFrameIndex = localOutputFrameCount
        let finalFrameCount = localOutputFrameCount
        logger.info("异步补帧管线完成，输出帧数: \(finalFrameCount)")
    }

    // MARK: - 创建视频写入输入（支持 HEVC/H.264，自动检测兼容性）

    /// 创建视频写入输入，自动检测编码兼容性并添加到 writer
    /// - Returns: 创建成功返回 AVAssetWriterInput（已添加到 writer），不支持该编码返回 nil
    private func makeVideoWriterInput(
        codec: AVVideoCodecType,
        width: Int,
        height: Int,
        bitRate: Int,
        writer: AVAssetWriter
    ) -> AVAssetWriterInput? {
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalKey: 60
        ]

        if codec == .hevc {
            compressionProperties[AVVideoAllowFrameReorderingKey] = true
        } else {
            compressionProperties[AVVideoAllowFrameReorderingKey] = false
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProperties
            ]
        )
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            return nil
        }
        writer.add(input)
        return input
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

    // MARK: - CVPixelBuffer 深拷贝（防止 reader 复用内存覆盖前一帧）
    private func deepCopyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        // 优先从内存池获取，池枯竭时降级为临时分配
        var resultBuffer: CVPixelBuffer? = bufferPool.makeBuffer(width: width, height, pixelFormat)
        if resultBuffer == nil {
            let attrs = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs, &resultBuffer) == kCVReturnSuccess,
                  let result = resultBuffer else {
                return nil
            }
            resultBuffer = result
        }
        guard let result = resultBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        guard let srcAddr = CVPixelBufferGetBaseAddress(source),
              let dstAddr = CVPixelBufferGetBaseAddress(result) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let bytesPerRow = min(srcBytesPerRow, dstBytesPerRow)

        for row in 0..<height {
            memcpy(dstAddr.advanced(by: row * dstBytesPerRow),
                   srcAddr.advanced(by: row * srcBytesPerRow),
                   bytesPerRow)
        }

        // 复制颜色空间附件
        copyColorSpaceAttachments(from: source, to: result)

        return result
    }

    // MARK: - vImage 缩放 CVPixelBuffer（输出分辨率控制）
    private func scalePixelBuffer(_ source: CVPixelBuffer, to width: Int, _ height: Int) -> CVPixelBuffer? {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let srcData = CVPixelBufferGetBaseAddress(source) else {
            return nil
        }
        var srcBuffer = vImage_Buffer(
            data: srcData,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )

        // 优先从内存池获取，池枯竭时降级为临时分配
        var dstPixelBuffer: CVPixelBuffer? = bufferPool.makeBuffer(width: width, height, kCVPixelFormatType_32BGRA)
        if dstPixelBuffer == nil {
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
            dstPixelBuffer = dst
        }
        guard let dst = dstPixelBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        guard let dstData = CVPixelBufferGetBaseAddress(dst) else {
            return nil
        }
        var dstBuffer = vImage_Buffer(
            data: dstData,
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

    // MARK: - 运动强度检测（快速模式自适应切换AI/blend）
    /// 计算相邻帧平均绝对亮度差，返回值范围约 0~255
    /// 阈值建议：<8 静态画面走blend，>=8 有运动走AI
    private func estimateMotion(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)
        guard width > 0, height > 0 else { return 255 }

        // 降采样到 64x64 降低计算量
        let smallW = 64
        let smallH = 64

        // iOSurface-backed 的 CVPixelBuffer Lock 可能失败
        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess else {
            return 255
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
        }

        guard let src0 = CVPixelBufferGetBaseAddress(frame0),
              let src1 = CVPixelBufferGetBaseAddress(frame1) else {
            return 255
        }

        let bytesPerRow0 = CVPixelBufferGetBytesPerRow(frame0)
        let bytesPerRow1 = CVPixelBufferGetBytesPerRow(frame1)
        let stepX = max(width / smallW, 1)
        let stepY = max(height / smallH, 1)

        var sum: Int64 = 0
        var count: Int64 = 0

        for y in stride(from: 0, to: height, by: stepY) {
            let row0 = src0.assumingMemoryBound(to: UInt8.self).advanced(by: y * bytesPerRow0)
            let row1 = src1.assumingMemoryBound(to: UInt8.self).advanced(by: y * bytesPerRow1)
            for x in stride(from: 0, to: width, by: stepX) {
                // BGRA 格式，取 B/G/R 三通道平均
                let idx = x * 4
                let b0 = Int(row0[idx]), g0 = Int(row0[idx+1]), r0 = Int(row0[idx+2])
                let b1 = Int(row1[idx]), g1 = Int(row1[idx+1]), r1 = Int(row1[idx+2])
                let lum0 = (r0 * 30 + g0 * 59 + b0 * 11) / 100
                let lum1 = (r1 * 30 + g1 * 59 + b1 * 11) / 100
                sum += Int64(abs(lum0 - lum1))
                count += 1
            }
        }

        guard count > 0 else { return 255 }
        return Float(sum) / Float(count)
    }

    // MARK: - 快速模式：Metal 帧混合（0.5 alpha混合，GPU加速，失败回退CPU）
    private func blendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        // 优先使用 Metal GPU 混合
        if let blender = MetalFrameBlender.shared,
           let result = blender.blend(frame0: frame0, frame1: frame1, alpha: 0.5) {
            return result
        }

        // Metal 不可用时回退到 CPU 混合，避免中间帧丢失导致 PTS 空洞
        logger.error("MetalFrameBlender 不可用，回退到 CPU 帧混合")
        return cpuBlendFrames(frame0, frame1)
    }

    // MARK: - CPU 帧混合回退（Metal 不可用时使用）
    private func cpuBlendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
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

        // iOSurface-backed 的 CVPixelBuffer Lock 可能失败，GetBaseAddress 返回 NULL
        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        guard let src0Ptr = CVPixelBufferGetBaseAddress(frame0),
              let src1Ptr = CVPixelBufferGetBaseAddress(frame1),
              let dstPtr = CVPixelBufferGetBaseAddress(result) else {
            return nil
        }
        let src0 = src0Ptr.assumingMemoryBound(to: UInt8.self)
        let src1 = src1Ptr.assumingMemoryBound(to: UInt8.self)
        let dst = dstPtr.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let totalBytes = bytesPerRow * height

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

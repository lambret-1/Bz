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
    /// 帧插值器，模型缺失时为 nil（降级为空转）
    private let interpolator: FrameInterpolator?
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

    /// 是否使用 AI 补帧（模型加载成功为 true，缺失为 false）
    var isUsingAIInterpolation: Bool { interpolator != nil }

    /// 当前使用的超分引擎类型（处理完成后供结果页查询）
    private(set) var currentSuperResolutionEngine: SuperResolutionEngineType?

    init() {
        self.interpolator = FrameInterpolator()
        if interpolator == nil {
            logger.warning("RIFE Lite 模型未加载，补帧管线将以空转模式运行（帧率不变）")
        } else {
            logger.info("RIFE Lite 模型加载成功，补帧功能已启用")
        }
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

        // 异步加载轨道（iOS 16+ 同步属性可能返回空，必须用 loadTracks）
        let tracksSemaphore = DispatchSemaphore(value: 0)
        var loadedVideoTrack: AVAssetTrack?
        var loadedAudioTrack: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { videoTracks, error in
            loadedVideoTrack = videoTracks?.first
            asset.loadTracks(withMediaType: .audio) { audioTracks, audioError in
                loadedAudioTrack = audioTracks?.first
                // 备选：异步加载失败时尝试同步获取（部分视频异步加载音频轨道返回空）
                if loadedAudioTrack == nil {
                    loadedAudioTrack = asset.tracks(withMediaType: .audio).first
                }
                tracksSemaphore.signal()
            }
        }
        tracksSemaphore.wait()
        // 备选：异步加载视频轨道也可能失败
        if loadedVideoTrack == nil {
            loadedVideoTrack = asset.tracks(withMediaType: .video).first
        }

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
            // 音频必须 alwaysCopiesSampleData=true，否则 sample buffer 数据可能被 reader 复用覆盖
            // 音频数据量小，拷贝开销可忽略
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = true
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
                print("[Bz音频诊断] 音频直写模式：已配置音频 Reader")
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
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
                print("[Bz音频诊断] 音频直写模式：已配置音频 Writer Input")
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
        Self.音频诊断结果 = audioWriterInput != nil ? "音视频直写中" : "无声视频处理中"

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

        Self.音频诊断结果 = audioWriterInput != nil ? "音视频直写完成" : "无声视频处理完成"
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

        // 创建有界帧缓冲队列（容量 6 帧，平衡内存与吞吐）
        let frameBuffer = FrameBuffer(capacity: 6)
        let decodeQueue = DispatchQueue(label: "com.lambret.bz.sr.decode", qos: .userInitiated)
        let encodeQueue = DispatchQueue(label: "com.lambret.bz.sr.encode", qos: .userInitiated)

        // 用局部变量跟踪输出帧数（避免 inout 参数被异步闭包捕获）
        var localOutputFrameCount = 0

        // 跨队列错误传递
        let errorLock = NSLock()
        var pipelineError: Error?

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

            var localFrameIndex = 0
            var localProgress = 0.0

            // 确保解码队列退出时关闭缓冲队列，唤醒编码端
            defer {
                frameBuffer.close()
                localOutputFrameCount = localFrameIndex
                decodeGroup.leave()
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
                let progressValue = min(Double(localFrameIndex) / Double(totalInputFrames), 0.99)
                if progressValue - localProgress >= 0.01 {
                    localProgress = progressValue
                    let stage: ProcessingStage = usingAI ? .superResolving : .decoding
                    // 进度防抖：只写原子变量，由外部 Timer 轮询更新 UI
                    updateProgress(progressValue, stage: stage)
                }

                autoreleasepool {
                    let processedFrame: CVPixelBuffer

                    if !needsAI {
                        // 1x 模式：深拷贝原帧（原帧来自 reader，生命周期由 reader 管理）
                        processedFrame = self.deepCopyPixelBuffer(pixelBuffer) ?? pixelBuffer
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
                        processedFrame = self.scalePixelBuffer(pixelBuffer, to: targetW, targetH)
                            ?? (self.deepCopyPixelBuffer(pixelBuffer) ?? pixelBuffer)
                    }

                    // 复制颜色空间附件
                    self.copyColorSpaceAttachments(from: pixelBuffer, to: processedFrame)

                    // 最终输出缩放
                    let finalFrame = needsScaling
                        ? self.scalePixelBuffer(processedFrame, to: outputWidth, outputHeight) ?? processedFrame
                        : processedFrame

                    // 计算 PTS
                    let pts = CMTime(value: Int64(localFrameIndex), timescale: Int32(outputFPS))

                    // 入队（阻塞等待缓冲空间）
                    if !frameBuffer.enqueue(ProcessedFrame(pixelBuffer: finalFrame, presentationTime: pts)) {
                        // 队列已关闭，退出
                        return
                    }

                    localFrameIndex += 1
                }
            }
        }

        // MARK: 编码队列（requestMediaDataWhenReady 驱动）
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
                // 从缓冲队列取帧（可能阻塞等待）
                guard let frame = frameBuffer.dequeue() else {
                    // 队列已关闭且为空，编码完成
                    finishEncode()
                    return
                }

                if self.isCancelled {
                    setError(PipelineError.cancelled)
                    finishEncode()
                    return
                }

                // 追加到 writer
                let appended = pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
                if !appended {
                    if writer.status == .failed {
                        setError(writer.error ?? PipelineError.writerFailed)
                    }
                    finishEncode()
                    return
                }
            }
        }

        // 等待解码+推理完成
        decodeGroup.wait()

        // 检查解码端错误
        errorLock.lock()
        let decodeError = pipelineError
        errorLock.unlock()

        if let error = decodeError {
            // 取消编码
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

        // 检查 reader 最终状态
        if reader.status == .failed {
            if let error = reader.error {
                throw error
            }
            throw PipelineError.readerFailed
        }

        outputFrameIndex = localOutputFrameCount
        let finalFrameCount = localOutputFrameCount
        logger.info("异步超分管线完成，输出帧数: \(finalFrameCount)")
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
                    setError(PipelineError.cancelled)
                    finishEncode()
                    return
                }

                let appended = pixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
                if !appended {
                    if writer.status == .failed {
                        setError(writer.error ?? PipelineError.writerFailed)
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

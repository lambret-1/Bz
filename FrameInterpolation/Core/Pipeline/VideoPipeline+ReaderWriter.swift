@preconcurrency import AVFoundation
import CoreVideo
import OSLog
import Accelerate

extension VideoPipeline {
    func runPipeline(
        inputURL: URL,
        outputURL: URL,
        mode: PipelineMode,
        multiplier: Int,
        fastMode: Bool,
        outputResolution: OutputResolution,
        progress: @escaping @MainActor (Double, ProcessingStage) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) async throws {
        let asset = AVURLAsset(url: inputURL)

        // 异步加载轨道
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let loadedVideoTrack = videoTracks.first else {
            throw PipelineError.noVideoTrack
        }
        let loadedAudioTrack = audioTracks.first

        print("[Bz音频诊断] 视频轨道: 有, 音频轨道: \(loadedAudioTrack != nil ? "有" : "无")")
        if let audioTrack = loadedAudioTrack {
            let formatDesc = try? await audioTrack.load(.formatDescriptions)
            let dataRate = try? await audioTrack.load(.estimatedDataRate)
            print("[Bz音频诊断] 音频格式: \(String(describing: formatDesc)), 估计码率: \(String(describing: dataRate))bps")
        }

        let videoTrack = loadedVideoTrack

        // 帧率与帧数计算
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let inputFPS = Double(nominalFPS)
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

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let totalInputFrames = max(Int(durationSeconds * inputFPS), 1)

        // 输出尺寸（按用户选择的放大倍数计算）
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
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
        let inputDataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
        let inputBitRate = Double(inputDataRate)
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

        logger.info("编码配置: HEVC, 输入码率 \(inputBitRate/1_000_000, privacy: .public)Mbps, 像素放大 \(String(format: "%.2f", pixelScaleRatio), privacy: .public)x, 输出码率 \(Double(targetBitRate)/1_000_000, privacy: .public)Mbps")

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
            logger.warning("HEVC 不可用，降级为 H.264 编码，码率 \(Double(h264BitRate)/1_000_000, privacy: .public)Mbps")
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
            let audioFormatDesc = (try? await loadedAudioTrack?.load(.formatDescriptions))?.first
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
            Self.waitGroup(audioEncodeGroup)
            print("[Bz音频诊断] 音频编码完成")
        }

        // MARK: 完成写入（音视频都已 markAsFinished）
        Self.waitWriterFinish(writer: writer)

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
    // MARK: - 创建视频写入输入（支持 HEVC/H.264，自动检测兼容性）

    /// 创建视频写入输入，自动检测编码兼容性并添加到 writer
    /// - Returns: 创建成功返回 AVAssetWriterInput（已添加到 writer），不支持该编码返回 nil
    func makeVideoWriterInput(
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

}

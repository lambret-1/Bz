@preconcurrency import AVFoundation
import CoreVideo
import OSLog
import Accelerate

extension VideoPipeline {
    // MARK: - 超分模式处理循环

    func runSuperResolutionLoop(
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
        // 设置引擎目标放大倍数（RealESRGANx2引擎内部直接输出目标尺寸）
        engine?.targetScale = targetScale.rawValue
        let usingAI = engine != nil
        if needsAI && engine == nil {
            logger.warning("\(engineType.displayName, privacy: .public) 模型未加载，超分模式降级为 vImage 缩放")
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
                    // AI 超分：引擎内部缩放到目标倍数
                    processedFrame = aiFrame
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
    func runSuperResolutionAsync(
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
            logger.warning("\(engineType.displayName, privacy: .public) 模型未加载，超分模式降级为 vImage 缩放")
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
                            self.logger.error("第\(frameIndex, privacy: .public)帧超分推理失败，引擎返回nil")
                            setError(PipelineError.unknown)
                            return
                        }
                        aiFrame = upscaled
                    } else {
                        self.logger.error("超分引擎未初始化")
                        setError(PipelineError.unknown)
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
                        self.logger.info("\(logLine, privacy: .public)")
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
                    setError(PipelineError.cancelled)
                    finishEncode()
                    return
                }

                // 追加到writer
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

        // 等待Reader和Inference完成
        Self.waitGroup(readerGroup)
        Self.waitGroup(inferenceGroup)

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
        Self.waitGroup(encodeGroup)

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
        logger.info("黄金三队列超分管线完成，输出帧数: \(finalFrameCount, privacy: .public)")

        // 结束诊断日志会话
        DiagnosticLogger.shared.writeLine("----------------------------------------")
        DiagnosticLogger.shared.writeLine("输出帧数: \(finalFrameCount)")
        DiagnosticLogger.shared.endSession()
    }

}

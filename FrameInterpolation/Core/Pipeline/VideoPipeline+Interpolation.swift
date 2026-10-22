@preconcurrency import AVFoundation
import CoreVideo
import OSLog
import Accelerate

extension VideoPipeline {
    // MARK: - 补帧模式处理循环

    func runInterpolationLoop(
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

    // MARK: - 异步补帧管线（解码+推理与编码并发）

    /// 异步补帧管线：解码+推理在独立队列，编码由 requestMediaDataWhenReady 驱动
    func runInterpolationAsync(
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
        Self.waitGroup(decodeGroup)

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
        Self.waitGroup(encodeGroup)

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
        logger.info("异步补帧管线完成，输出帧数: \(finalFrameCount, privacy: .public)")
    }

}

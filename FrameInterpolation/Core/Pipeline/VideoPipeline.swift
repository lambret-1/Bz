@preconcurrency import AVFoundation
import CoreVideo
import OSLog
import Accelerate

/// 视频处理管线：解码 → 补帧/超分 → 编码 + 音频透传
/// 支持补帧模式（2x/4x）与超分模式（Fast-SRGAN 4x / Real-ESRGAN 4x），两种模式互斥
/// 模型缺失时自动降级：补帧→空转（帧率不变），超分→vImage缩放
final class VideoPipeline {
    let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPipeline")
    var isCancelled = false
    /// 帧插值器，懒加载：首次进入补帧模式时才加载模型，避免启动时同步加载阻塞UI
    lazy var interpolator: FrameInterpolator? = {
        let interp = FrameInterpolator()
        if interp == nil {
            logger.warning("RIFE Lite 模型未加载，补帧管线将以空转模式运行（帧率不变）")
        } else {
            logger.info("RIFE Lite 模型加载成功，补帧功能已启用")
        }
        return interp
    }()
    /// 后台处理队列
    let processingQueue = DispatchQueue(label: "com.lambret.bz.pipeline", qos: .userInitiated)

    /// CVPixelBuffer 内存池（复用缓冲，避免循环中频繁分配释放）
    let bufferPool = PixelBufferPoolManager(minBufferCount: 12)

    /// 原子进度保护（iOS 16+ OSAllocatedUnfairLock，开销仅为 NSLock 的几十分之一）
    let progressLock = OSAllocatedUnfairLock(initialState: (value: 0.0, stage: ProcessingStage.decoding))

    /// 轮询当前进度（线程安全，供外部 Timer 每 0.5s 调用一次）
    func pollProgress() -> (value: Double, stage: ProcessingStage) {
        progressLock.withLock { ($0.value, $0.stage) }
    }

    /// 内部更新进度（只写原子变量，不切主线程）
    func updateProgress(_ value: Double, stage: ProcessingStage) {
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
            effectiveMultiplier = 1
            currentSuperResolutionEngine = engineType
            modeDescription = "超分\(engineType.shortName)\(scale.label)"
        }

        logger.info("开始处理: \(inputURL.lastPathComponent, privacy: .public), 模式:\(modeDescription, privacy: .public), 快速模式:\(fastMode, privacy: .public), 分辨率:\(outputResolution.rawValue, privacy: .public)")

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            Task {
                do {
                    try await self.runPipeline(
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
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// 取消处理
    func cancel() {
        logger.info("用户取消处理")
        isCancelled = true
    }

    // MARK: - 同步等待辅助

    static func waitGroup(_ group: DispatchGroup) {
        group.wait()
    }

    static func waitSemaphore(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    static func waitWriterFinish(writer: AVAssetWriter) {
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()
    }
}

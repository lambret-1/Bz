import SwiftUI
import OSLog
import AVFoundation
import UserNotifications
import UIKit

/// 全局应用状态，主线程隔离，统一管理导航、导入、处理、结果与 Toast
@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "AppState")
    private let pipeline = VideoPipeline()
    private let recentRecordsKey = "BzRecentRecords"
    /// 性能监控器（处理中页面显示 CPU/内存）
    let performanceMonitor = PerformanceMonitor()

    // MARK: - 后台任务管理（统一在AppState，避免ProcessingView dismiss后丢失保护）
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 处理耗时统计（用于预估时间自适应）
    private let processingSpeedKey = "BzProcessingSpeedFactor"
    private var processingStartTime: Date?
    /// 本机实测处理速度系数：视频时长/实际耗时，越大越快。nil表示尚未实测
    @Published private(set) var measuredSpeedFactor: Double?

    // MARK: - 导航状态
    /// 是否展示参数设置页（独立 fullScreenCover）
    @Published var showSettings = false
    /// 是否展示处理中页（独立 fullScreenCover）
    @Published var isProcessing = false
    /// 处理中但用户最小化到首页（管线继续跑，ProcessingView关闭）
    @Published var isProcessingMinimized = false

    // MARK: - 首页
    @Published var recentRecords: [RecentRecord] = []

    // MARK: - 参数设置
    @Published var selectedVideo: VideoInfo?
    @Published var frameMultiplier: FrameMultiplier = .x2
    @Published var outputResolution: OutputResolution = .auto
    @Published var fastMode: Bool = false
    /// 处理模式：补帧或超分（二者互斥）
    @Published var selectedMode: PipelineMode = .interpolation(.x2)
    /// 超分引擎类型（仅超分模式生效）
    @Published var superResolutionEngine: SuperResolutionEngineType = .fastSRGAN
    /// 超分放大倍数（1-4x 可调，仅超分模式生效）
    @Published var superResolutionScale: SuperResolutionScale = .x4

    // MARK: - 处理中
    @Published var progress: Double = 0
    @Published var processedFrames: Int = 0
    @Published var totalFrames: Int = 0
    @Published var stage: ProcessingStage = .idle
    /// 预计剩余时间（秒），基于已用时间和进度估算
    @Published var estimatedRemaining: TimeInterval = 0
    /// 进度轮询定时器（每 0.5s 从 pipeline 读取原子进度，避免高频主线程回调）
    private var progressTimer: Timer?

    // MARK: - 结果
    /// 输出视频 URL，非空时展示结果页
    @Published var outputURL: URL?
    /// 实际处理模式描述（如 "AI补帧（2x）" 或 "空转管线（帧率不变）"）
    @Published var processingMode: String = ""
    /// 调试信息（模型输出统计、亮度对比等），显示在结果页
    @Published var debugInfo: String = ""
    /// 是否使用AI插值（模型加载成功）
    var isUsingAI: Bool { pipeline.isUsingAIInterpolation }

    // MARK: - 处理统计（结果页展示）
    /// 总耗时（秒）
    @Published var totalElapsedSeconds: Double = 0
    /// CPU 平均使用率（%）
    @Published var cpuAverage: Double = 0
    /// CPU 峰值使用率（%）
    @Published var cpuPeak: Double = 0
    /// 内存平均占用（MB）
    @Published var memoryAverageMB: Double = 0
    /// 内存峰值占用（MB）
    @Published var memoryPeakMB: Double = 0

    // MARK: - Toast
    @Published var toastMessage: String?
    @Published var toastStyle: ToastStyle = .success

    // MARK: - 初始化
    init() {
        // 加载最近记录
        loadRecentRecords()
        // 加载本机实测处理速度系数
        let saved = UserDefaults.standard.double(forKey: processingSpeedKey)
        measuredSpeedFactor = saved > 0 ? saved : nil

        // 监听 FrameInterpolator 的调试信息更新
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BzDebugInfoUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.debugInfo = note.object as? String ?? ""
        }
    }

    // MARK: - 最近记录持久化

    private func loadRecentRecords() {
        guard let data = UserDefaults.standard.data(forKey: recentRecordsKey) else { return }
        do {
            recentRecords = try JSONDecoder().decode([RecentRecord].self, from: data)
            logger.info("加载最近记录: \(self.recentRecords.count) 条")
        } catch {
            logger.error("加载最近记录失败: \(error.localizedDescription)")
        }
    }

    private func saveRecentRecords() {
        do {
            let data = try JSONEncoder().encode(recentRecords)
            UserDefaults.standard.set(data, forKey: recentRecordsKey)
        } catch {
            logger.error("保存最近记录失败: \(error.localizedDescription)")
        }
    }

    /// 从视频文件生成缩略图（第一帧）
    private func generateThumbnail(from url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            return uiImage.jpegData(compressionQuality: 0.6)
        } catch {
            logger.error("生成缩略图失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 追加最近记录（处理成功后调用）
    private func appendRecentRecord(
        outputURL: URL,
        outputFPS: Double,
        processingMode: String,
        outputWidth: Int,
        outputHeight: Int,
        duration: TimeInterval
    ) {
        let thumbnail = generateThumbnail(from: outputURL)
        let fileSizeMB = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { Double($0) / (1024 * 1024) }
        let record = RecentRecord(
            fileName: outputURL.lastPathComponent,
            outputFPS: outputFPS,
            thumbnailData: thumbnail,
            processingMode: processingMode,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            fileSizeMB: fileSizeMB,
            duration: duration,
            outputPath: outputURL.path
        )
        recentRecords.insert(record, at: 0)
        // 最多保留 20 条
        if recentRecords.count > 20 {
            recentRecords = Array(recentRecords.prefix(20))
        }
        saveRecentRecords()
    }

    /// 重播最近记录（输出文件仍存在时直接展示结果页，否则提示重新导入）
    func replayRecentRecord(_ record: RecentRecord) {
        if let path = record.outputPath,
           FileManager.default.fileExists(atPath: path) {
            outputURL = URL(fileURLWithPath: path)
            processingMode = record.processingMode ?? "已处理视频"
            logger.info("重播最近记录: \(record.fileName, privacy: .public)")
        } else {
            showToast("原文件已被清理，请重新导入视频", style: .warning)
            logger.info("最近记录文件已清理: \(record.fileName, privacy: .public)")
        }
    }

    /// 删除指定最近记录
    func deleteRecentRecord(_ record: RecentRecord) {
        recentRecords.removeAll { $0.id == record.id }
        saveRecentRecords()
    }

    /// 清空所有最近记录
    func clearAllRecentRecords() {
        recentRecords.removeAll()
        saveRecentRecords()
    }

    // MARK: - 导入视频

    /// 从相册选择视频后调用，读取真实元数据并进入参数设置页
    func importVideo(from url: URL) {
        logger.info("开始导入视频: \(url.lastPathComponent, privacy: .public)")
        stage = .decoding

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let info = try await MediaImporter.loadVideoInfo(from: url)
                self.selectedVideo = info
                self.showSettings = true
                self.stage = .idle
                logger.info("视频导入成功: \(info.fileName, privacy: .public), \(info.width)x\(info.height), \(info.originalFPS)fps")
            } catch {
                self.stage = .idle
                self.showToast(error.localizedDescription, style: .error)
                logger.error("视频导入失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 开始处理

    /// 启动视频处理管线（补帧或超分，二者互斥，模型缺失时自动降级）
    func startProcessing() {
        guard let video = selectedVideo else {
            showToast("未选择视频", style: .error)
            return
        }

        // 确保 selectedMode 与当前选择同步
        let mode: PipelineMode
        switch selectedMode {
        case .interpolation:
            mode = .interpolation(frameMultiplier)
        case .superResolution:
            mode = .superResolution(superResolutionEngine, superResolutionScale)
        }

        logger.info("开始处理: \(video.fileName, privacy: .public), 模式:\(mode.displayName)")

        isProcessing = true
        progress = 0
        processedFrames = 0
        // 根据视频时长和帧率计算总帧数，用于进度页显示"已处理 X / Y 帧"
        totalFrames = max(Int((video.duration * video.originalFPS).rounded()), 1)
        stage = .decoding
        processingStartTime = Date()

        // 启动性能监控（处理中页面显示 CPU/内存）
        performanceMonitor.resetStatistics()
        performanceMonitor.start()

        // 统一申请后台任务，处理全程持有（包括最小化到首页）
        beginBackgroundTask()

        // 输出文件路径
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output_\(UUID().uuidString).mp4")
        self.outputURL = nil

        // 启动进度轮询定时器（每 0.5s 从 pipeline 读取原子进度，避免高频主线程回调）
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let (value, stage) = self.pipeline.pollProgress()
            self.progress = value
            self.stage = stage
            if self.totalFrames > 0 {
                self.processedFrames = min(Int(value * Double(self.totalFrames)), self.totalFrames)
            }
            if let start = self.processingStartTime, value > 0.01 {
                let elapsed = Date().timeIntervalSince(start)
                self.estimatedRemaining = elapsed * (1.0 - value) / value
            }
        }

        pipeline.process(
            inputURL: video.url,
            outputURL: outputURL,
            mode: mode,
            fastMode: fastMode,
            outputResolution: outputResolution,
            progress: { [weak self] value, stage in
                // 进度防抖：循环中不再调用此闭包，仅完成时可能调用 1.0
                guard let self = self else { return }
                self.progress = value
                self.stage = stage
            },
            completion: { [weak self] result in
                guard let self = self else { return }

                // 停止进度轮询定时器
                self.progressTimer?.invalidate()
                self.progressTimer = nil

                // 停止性能监控
                self.performanceMonitor.stop()

                switch result {
                case .success(let url):
                    self.stage = .finished
                    self.progress = 1.0
                    self.estimatedRemaining = 0
                    self.outputURL = url

                    // 记录处理统计（总耗时、CPU/内存平均与峰值）
                    if let start = self.processingStartTime {
                        self.totalElapsedSeconds = Date().timeIntervalSince(start)
                    }
                    self.cpuAverage = self.performanceMonitor.cpuAverage
                    self.cpuPeak = self.performanceMonitor.cpuPeak
                    self.memoryAverageMB = self.performanceMonitor.memoryAverage
                    self.memoryPeakMB = self.performanceMonitor.memoryPeak

                    // 根据实际模式设置处理描述
                    switch mode {
                    case .interpolation:
                        self.processingMode = self.pipeline.isUsingAIInterpolation
                            ? "AI补帧（\(self.frameMultiplier.label)）"
                            : "空转管线（帧率不变）"
                    case .superResolution(let engineType, let scale):
                        self.processingMode = "AI超分（\(engineType.shortName) \(scale.label)）"
                    }

                    // 追加最近记录（超分模式帧率不变）
                    let outputFPS: Double
                    switch mode {
                    case .interpolation:
                        outputFPS = (self.selectedVideo?.originalFPS ?? 30) * Double(self.frameMultiplier.rawValue)
                    case .superResolution:
                        outputFPS = self.selectedVideo?.originalFPS ?? 30
                    }

                    // 读取输出视频元数据
                    let outputAsset = AVURLAsset(url: url)
                    let outputTrack = outputAsset.tracks(withMediaType: .video).first
                    let outputSize = outputTrack?.naturalSize.applying(outputTrack?.preferredTransform ?? .identity) ?? .zero
                    let outputWidth = Int(abs(outputSize.width))
                    let outputHeight = Int(abs(outputSize.height))
                    let outputDuration = CMTimeGetSeconds(outputAsset.duration)

                    self.appendRecentRecord(
                        outputURL: url,
                        outputFPS: outputFPS,
                        processingMode: self.processingMode,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight,
                        duration: outputDuration
                    )
                    self.showToast("处理完成")
                    self.logger.info("处理完成: \(url.lastPathComponent, privacy: .public)")
                    // 处理完成发本地通知（用户切后台时能收到）
                    self.sendBackgroundNotification(
                        title: "处理完成",
                        body: "视频已处理完成，点击查看结果",
                        identifier: "bz_process_complete"
                    )
                    // 记录本机实测处理速度系数（视频时长/实际耗时）
                    if let start = self.processingStartTime,
                       let videoDuration = self.selectedVideo?.duration,
                       videoDuration > 0 {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 0 {
                            let speedFactor = videoDuration / elapsed
                            // 滑动平均：新系数占30%，避免单次异常波动
                            let averaged = self.measuredSpeedFactor.map { ($0 * 0.7) + (speedFactor * 0.3) } ?? speedFactor
                            self.measuredSpeedFactor = averaged
                            UserDefaults.standard.set(averaged, forKey: self.processingSpeedKey)
                            self.logger.info("实测速度系数: \(String(format: "%.2f", speedFactor)), 滑动平均: \(String(format: "%.2f", averaged))")
                        }
                    }
                    // 处理完成，结束后台任务
                    self.endBackgroundTask()
                    // 注意：成功时不设置 isProcessing = false
                    // 保持 ProcessingView 在后台，ResultView 通过 fullScreenCover 覆盖在上
                    // 避免 ProcessingView 被 dismiss 时连带移除 ResultView
                    // 用户从结果页返回时再统一设置 isProcessing = false

                case .failure(let error):
                    self.isProcessing = false
                    self.isProcessingMinimized = false
                    self.stage = .failed
                    self.estimatedRemaining = 0
                    self.outputURL = nil
                    // 处理失败，结束后台任务
                    self.endBackgroundTask()
                    if case PipelineError.cancelled = error {
                        self.showToast("已取消处理", style: .warning)
                    } else {
                        self.showToast(error.localizedDescription, style: .error)
                    }
                    self.logger.error("处理失败: \(error.localizedDescription, privacy: .public)")
                }
            }
        )
    }

    // MARK: - 取消处理

    func cancelProcessing() {
        pipeline.cancel()
        performanceMonitor.stop()
        isProcessing = false
        isProcessingMinimized = false
        stage = .idle
        progress = 0
        endBackgroundTask()
        logger.info("处理已取消")
    }

    // MARK: - 后台任务统一管理

    private func beginBackgroundTask() {
        endBackgroundTask() // 先结束旧的
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "视频补帧处理") { [weak self] in
            // 后台时间快用完了，发通知喊用户回来
            self?.backgroundTimeExpiring()
            if let id = self?.backgroundTaskID, id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                self?.backgroundTaskID = .invalid
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - 最小化处理页到首页（管线继续跑）

    func minimizeProcessing() {
        guard isProcessing else { return }
        isProcessingMinimized = true
        isProcessing = false
        logger.info("处理页最小化到首页，管线继续运行")
    }

    // MARK: - 从首页横幅恢复处理页

    func restoreProcessingView() {
        guard isProcessingMinimized else { return }
        isProcessingMinimized = false
        isProcessing = true
        logger.info("从首页横幅恢复处理页")
    }

    // MARK: - 切后台通知

    /// 应用进入后台时调用，处理中则发本地通知提醒用户
    func applicationDidEnterBackground() {
        // 任务完成后（outputURL != nil）不再发后台通知
        guard (isProcessing || isProcessingMinimized) && outputURL == nil else { return }
        sendBackgroundNotification(
            title: "补帧处理中",
            body: "你刚切到后台，处理将继续约30秒，点我回到App继续",
            identifier: "bz_bg_warning"
        )
    }

    /// 后台时间即将耗尽时调用
    func backgroundTimeExpiring() {
        // 任务完成后不再发通知
        guard (isProcessing || isProcessingMinimized) && outputURL == nil else { return }
        sendBackgroundNotification(
            title: "补帧即将暂停",
            body: "系统马上要挂起任务，点我回来继续处理",
            identifier: "bz_bg_expiring"
        )
    }

    private func sendBackgroundNotification(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - 重置全部状态（返回首页）

    func resetAll() {
        logger.info("重置全部状态，返回首页")
        pipeline.cancel()
        outputURL = nil
        processingMode = ""
        debugInfo = ""
        isProcessing = false
        isProcessingMinimized = false
        showSettings = false
        selectedVideo = nil
        selectedMode = .interpolation(.x2)
        superResolutionEngine = .fastSRGAN
        superResolutionScale = .x4
        stage = .idle
        progress = 0
        processedFrames = 0
        totalFrames = 0
    }

    // MARK: - Toast

private var toastWorkItem: DispatchWorkItem?

func showToast(_ message: String, style: ToastStyle = .success) {
    toastWorkItem?.cancel()
    toastMessage = message
    toastStyle = style
    let workItem = DispatchWorkItem {
        withAnimation { self.toastMessage = nil }
    }
    toastWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
}
}

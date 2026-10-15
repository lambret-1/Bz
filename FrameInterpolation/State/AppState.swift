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

    // MARK: - 处理中
    @Published var progress: Double = 0
    @Published var processedFrames: Int = 0
    @Published var totalFrames: Int = 0
    @Published var stage: ProcessingStage = .idle

    // MARK: - 结果
    /// 输出视频 URL，非空时展示结果页
    @Published var outputURL: URL?
    /// 实际处理模式描述（如 "AI补帧（2x）" 或 "空转管线（帧率不变）"）
    @Published var processingMode: String = ""
    /// 调试信息（模型输出统计、亮度对比等），显示在结果页
    @Published var debugInfo: String = ""
    /// 是否使用AI插值（模型加载成功）
    var isUsingAI: Bool { pipeline.isUsingAIInterpolation }

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
    private func appendRecentRecord(outputURL: URL, outputFPS: Double) {
        let thumbnail = generateThumbnail(from: outputURL)
        let record = RecentRecord(
            fileName: outputURL.lastPathComponent,
            outputFPS: outputFPS,
            thumbnailData: thumbnail
        )
        recentRecords.insert(record, at: 0)
        // 最多保留 20 条
        if recentRecords.count > 20 {
            recentRecords = Array(recentRecords.prefix(20))
        }
        saveRecentRecords()
    }

    // MARK: - 导入视频

    /// 从相册选择视频后调用，读取真实元数据并进入参数设置页
    func importVideo(from url: URL) {
        logger.info("开始导入视频: \(url.lastPathComponent, privacy: .public)")
        stage = .decoding

        Task {
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

    /// 启动视频处理管线（补帧 + 音频透传，模型缺失时自动降级为空转）
    func startProcessing() {
        guard let video = selectedVideo else {
            showToast("未选择视频", style: .error)
            return
        }

        logger.info("开始处理: \(video.fileName, privacy: .public), 倍数\(self.frameMultiplier.label)")

        isProcessing = true
        progress = 0
        processedFrames = 0
        stage = .decoding
        processingStartTime = Date()

        // 统一申请后台任务，处理全程持有（包括最小化到首页）
        beginBackgroundTask()

        // 输出文件路径
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output_\(UUID().uuidString).mp4")
        self.outputURL = nil

        pipeline.process(
            inputURL: video.url,
            outputURL: outputURL,
            multiplier: frameMultiplier.rawValue,
            fastMode: fastMode,
            outputResolution: outputResolution,
            progress: { [weak self] value, stage in
                guard let self = self else { return }
                self.progress = value
                self.stage = stage
            },
            completion: { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let url):
                    self.stage = .finished
                    self.progress = 1.0
                    self.outputURL = url
                    self.processingMode = self.pipeline.isUsingAIInterpolation
                        ? "AI补帧（\(self.frameMultiplier.label)）"
                        : "空转管线（帧率不变）"
                    // 追加最近记录
                    let outputFPS = (self.selectedVideo?.originalFPS ?? 30) * Double(self.frameMultiplier.rawValue)
                    self.appendRecentRecord(outputURL: url, outputFPS: outputFPS)
                    self.showToast("处理完成")
                    self.logger.info("处理完成: \(url.lastPathComponent, privacy: .public)")
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
        stage = .idle
        progress = 0
        processedFrames = 0
        totalFrames = 0
    }

    // MARK: - Toast

    func showToast(_ message: String, style: ToastStyle = .success) {
        toastMessage = message
        toastStyle = style
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastMessage = nil }
        }
    }
}

import SwiftUI
import OSLog

/// 全局应用状态，主线程隔离，统一管理导航、导入、处理、结果与 Toast
@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "AppState")
    private let pipeline = VideoPipeline()

    // MARK: - 导航状态
    /// 是否展示参数设置页（独立 fullScreenCover）
    @Published var showSettings = false
    /// 是否展示处理中页（独立 fullScreenCover）
    @Published var isProcessing = false

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

    // MARK: - Toast
    @Published var toastMessage: String?
    @Published var toastStyle: ToastStyle = .success

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

        // 输出文件路径
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output_\(UUID().uuidString).mp4")
        self.outputURL = nil

        pipeline.process(
            inputURL: video.url,
            outputURL: outputURL,
            multiplier: frameMultiplier.rawValue,
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
                    self.showToast("处理完成")
                    self.logger.info("处理完成: \(url.lastPathComponent, privacy: .public)")
                    // 注意：成功时不设置 isProcessing = false
                    // 保持 ProcessingView 在后台，ResultView 通过 fullScreenCover 覆盖在上
                    // 避免 ProcessingView 被 dismiss 时连带移除 ResultView
                    // 用户从结果页返回时再统一设置 isProcessing = false

                case .failure(let error):
                    self.isProcessing = false
                    self.stage = .failed
                    self.outputURL = nil
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
        stage = .idle
        progress = 0
        logger.info("处理已取消")
    }

    // MARK: - 重置全部状态（返回首页）

    func resetAll() {
        logger.info("重置全部状态，返回首页")
        pipeline.cancel()
        outputURL = nil
        isProcessing = false
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

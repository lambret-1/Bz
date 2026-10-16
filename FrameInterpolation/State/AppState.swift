import SwiftUI
import OSLog
import AVFoundation
import UserNotifications
import UIKit

/// 全局应用状态，主线程隔离，统一管理项目、导航、导入、处理、结果与 Toast
@MainActor
final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "AppState")
    private let pipeline = VideoPipeline()
    private let projectsKey = "BzProjects"
    private let recentRecordsKey = "BzRecentRecords"

    // MARK: - 后台任务管理
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 处理耗时统计
    private let processingSpeedKey = "BzProcessingSpeedFactor"
    private var processingStartTime: Date?
    /// 本机实测处理速度系数：视频时长/实际耗时
    @Published private(set) var measuredSpeedFactor: Double?

    // MARK: - 导航状态
    /// 是否展示应用设置页（独立 fullScreenCover）
    @Published var showAppSettings = false
    /// 是否展示处理中页（独立 fullScreenCover）
    @Published var isProcessing = false
    /// 处理中但用户最小化到首页
    @Published var isProcessingMinimized = false
    /// 是否展示项目详情页（独立 fullScreenCover）
    @Published var showProjectDetail = false
    /// 是否展示导出设置页（独立 fullScreenCover）
    @Published var showExportSettings = false

    // MARK: - 项目管理
    /// 全部项目列表
    @Published var projects: [Project] = []
    /// 当前编辑的项目
    @Published var currentProject: Project?
    /// 片段编辑撤销栈（保存操作前的 segments 快照）
    private var undoStack: [[VideoSegment]] = []

    // MARK: - 兼容旧版最近记录
    @Published var recentRecords: [RecentRecord] = []

    // MARK: - 兼容旧版参数（处理时从 currentProject 读取，此处保留过渡）
    @Published var selectedVideo: VideoInfo?
    @Published var frameMultiplier: FrameMultiplier = .x2
    @Published var outputResolution: OutputResolution = .auto
    @Published var fastMode: Bool = false

    // MARK: - 处理中
    @Published var progress: Double = 0
    @Published var processedFrames: Int = 0
    @Published var totalFrames: Int = 0
    @Published var stage: ProcessingStage = .idle
    @Published var estimatedRemaining: TimeInterval = 0
    /// 处理任务清单
    @Published var processingTasks: [ProcessingTask] = []

    // MARK: - 结果
    @Published var outputURL: URL?
    @Published var processingMode: String = ""
    @Published var debugInfo: String = ""
    var isUsingAI: Bool { pipeline.isUsingAIInterpolation }

    // MARK: - Toast
    @Published var toastMessage: String?
    @Published var toastStyle: ToastStyle = .success
    private var toastWorkItem: DispatchWorkItem?

    // MARK: - 应用设置
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled: Bool = true
    @AppStorage("keepScreenAwake") var keepScreenAwake: Bool = true
    @AppStorage("defaultCodec") var defaultCodec: VideoCodec = .hevc
    @AppStorage("defaultBitrateMode") var defaultBitrateMode: BitrateMode = .auto
    @AppStorage("defaultContainer") var defaultContainer: ContainerFormat = .auto

    // MARK: - 初始化
    init() {
        loadProjects()
        loadRecentRecords()
        let saved = UserDefaults.standard.double(forKey: processingSpeedKey)
        measuredSpeedFactor = saved > 0 ? saved : nil

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BzDebugInfoUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.debugInfo = note.object as? String ?? ""
        }
    }

    // MARK: - 项目持久化

    private func loadProjects() {
        guard let data = UserDefaults.standard.data(forKey: projectsKey) else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
            logger.info("加载项目: \(self.projects.count) 个")
        } catch {
            logger.error("加载项目失败: \(error.localizedDescription)")
        }
    }

    private func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: projectsKey)
        } catch {
            logger.error("保存项目失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 最近记录持久化（兼容旧版）

    private func loadRecentRecords() {
        guard let data = UserDefaults.standard.data(forKey: recentRecordsKey) else { return }
        do {
            recentRecords = try JSONDecoder().decode([RecentRecord].self, from: data)
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

    /// 生成指定时间点的缩略图
    private func generateThumbnail(from url: URL, at time: TimeInterval) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            return uiImage.jpegData(compressionQuality: 0.5)
        } catch {
            return nil
        }
    }

    // MARK: - 导入视频并创建项目

    /// 从相册选择视频后调用，读取元数据并创建新项目，进入项目详情页
    func importVideo(from url: URL) {
        logger.info("开始导入视频: \(url.lastPathComponent, privacy: .public)")
        stage = .decoding

        Task {
            do {
                var info = try await MediaImporter.loadVideoInfo(from: url)
                // 生成缩略图
                let thumbnail = generateThumbnail(from: url)
                info = VideoInfo(
                    id: info.id, url: info.url, fileName: info.fileName,
                    duration: info.duration, originalFPS: info.originalFPS,
                    originalSizeMB: info.originalSizeMB, width: info.width,
                    height: info.height, codecFormat: info.codecFormat,
                    bitRateMbps: info.bitRateMbps, thumbnailData: thumbnail
                )

                // 创建初始片段（整段视频）
                let segmentThumbnail = generateThumbnail(from: url, at: 0)
                let initialSegment = VideoSegment(
                    startTime: 0,
                    duration: info.duration,
                    thumbnailData: segmentThumbnail
                )

                // 创建项目
                let projectName = (info.fileName as NSString).deletingPathExtension
                var export = ExportSettings()
                export.codec = defaultCodec
                export.bitrateMode = defaultBitrateMode
                export.container = defaultContainer

                let project = Project(
                    name: projectName,
                    videoInfo: info,
                    segments: [initialSegment],
                    exportSettings: export
                )

                projects.insert(project, at: 0)
                currentProject = project
                saveProjects()
                undoStack.removeAll()

                self.selectedVideo = info
                self.stage = .idle
                self.showProjectDetail = true

                logger.info("项目创建成功: \(projectName, privacy: .public)")
            } catch {
                self.stage = .idle
                self.showToast(error.localizedDescription, style: .error)
                logger.error("视频导入失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 项目操作

    /// 打开项目详情
    func openProject(_ project: Project) {
        currentProject = project
        selectedVideo = project.videoInfo
        undoStack.removeAll()
        showProjectDetail = true
    }

    /// 重命名项目
    func renameProject(_ project: Project, newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = newName
        projects[index].updatedAt = Date()
        if currentProject?.id == project.id {
            currentProject = projects[index]
        }
        saveProjects()
    }

    /// 复制项目
    func duplicateProject(_ project: Project) {
        var copy = project
        copy.id = UUID()
        copy.name = "\(project.name) 副本"
        copy.status = .draft
        copy.outputURL = nil
        copy.createdAt = Date()
        copy.updatedAt = Date()
        projects.insert(copy, at: 0)
        saveProjects()
        showToast("已复制项目")
    }

    /// 删除项目
    func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        if currentProject?.id == project.id {
            currentProject = nil
            showProjectDetail = false
        }
        saveProjects()
        showToast("已删除项目", style: .warning)
    }

    /// 更新当前项目（保存修改）
    private func updateCurrentProject(_ mutation: (inout Project) -> Void) {
        guard let project = currentProject,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        mutation(&updated)
        updated.updatedAt = Date()
        projects[index] = updated
        currentProject = updated
        saveProjects()
    }

    // MARK: - 片段编辑

    /// 保存当前片段状态到撤销栈
    private func pushUndo() {
        guard let segments = currentProject?.segments else { return }
        undoStack.append(segments)
        // 最多保留 20 步
        if undoStack.count > 20 {
            undoStack.removeFirst()
        }
    }

    /// 是否可撤销
    var canUndo: Bool { !undoStack.isEmpty }

    /// 撤销上一次片段编辑
    func undoSegmentEdit() {
        guard let previous = undoStack.popLast() else { return }
        updateCurrentProject { $0.segments = previous }
        showToast("已撤销", style: .warning)
    }

    /// 在播放头位置分切当前片段
    func splitSegment(at time: TimeInterval) {
        guard let project = currentProject else { return }

        // 找到包含该时间点的片段
        guard let segmentIndex = project.segments.firstIndex(where: {
            time > $0.startTime + 0.05 && time < $0.endTime - 0.05
        }) else {
            showToast("播放头需位于片段内部", style: .warning)
            return
        }

        let segment = project.segments[segmentIndex]
        pushUndo()

        let firstDuration = time - segment.startTime
        let secondDuration = segment.endTime - time

        let firstThumbnail = generateThumbnail(from: project.videoInfo.url, at: segment.startTime)
        let secondThumbnail = generateThumbnail(from: project.videoInfo.url, at: time)

        let first = VideoSegment(
            startTime: segment.startTime,
            duration: firstDuration,
            thumbnailData: firstThumbnail
        )
        let second = VideoSegment(
            startTime: time,
            duration: secondDuration,
            thumbnailData: secondThumbnail
        )

        updateCurrentProject {
            $0.segments.remove(at: segmentIndex)
            $0.segments.insert(contentsOf: [first, second], at: segmentIndex)
        }
        triggerHaptic()
        showToast("已分切")
    }

    /// 复制选中的片段
    func duplicateSegment(_ segment: VideoSegment) {
        guard let project = currentProject,
              let index = project.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        pushUndo()
        var copy = segment
        copy.id = UUID()
        updateCurrentProject {
            $0.segments.insert(copy, at: index + 1)
        }
        triggerHaptic()
        showToast("已复制片段")
    }

    /// 删除选中的片段（至少保留 1 个）
    func deleteSegment(_ segment: VideoSegment) {
        guard let project = currentProject else { return }
        guard project.segments.count > 1 else {
            showToast("至少保留 1 个片段", style: .error)
            return
        }
        pushUndo()
        updateCurrentProject {
            $0.segments.removeAll { $0.id == segment.id }
        }
        triggerHaptic()
        showToast("已删除，可撤销", style: .warning)
    }

    /// 移动片段（排序）
    func moveSegment(from source: IndexSet, to destination: Int) {
        guard currentProject != nil else { return }
        pushUndo()
        updateCurrentProject {
            $0.segments.move(fromOffsets: source, toOffset: destination)
        }
    }

    // MARK: - 增强配置

    /// 设置增强模式（互斥：选择补帧自动取消超分，反之亦然）
    func setEnhancementMode(_ mode: EnhancementMode) {
        guard let project = currentProject else { return }
        if project.enhancement.mode == mode {
            // 再次点击取消
            updateCurrentProject { $0.enhancement.mode = .none }
        } else {
            updateCurrentProject { $0.enhancement.mode = mode }
            if mode != .none {
                triggerHaptic()
            }
        }
    }

    /// 更新补帧倍数
    func setFrameMultiplier(_ multiplier: FrameMultiplier) {
        updateCurrentProject { $0.enhancement.frameMultiplier = multiplier }
    }

    /// 更新超分模型
    func setSuperResolutionModel(_ model: SuperResolutionModel) {
        updateCurrentProject { $0.enhancement.srModel = model }
    }

    /// 更新清晰度配置
    func updateClarity(_ mutation: (inout ClarityConfig) -> Void) {
        updateCurrentProject { mutation(&$0.enhancement.clarity) }
    }

    /// 切换音频修复
    func toggleAudioRepair(_ enabled: Bool) {
        updateCurrentProject { $0.enhancement.audio.repairEnabled = enabled }
    }

    /// 更新导出设置
    func updateExportSettings(_ settings: ExportSettings) {
        updateCurrentProject { $0.exportSettings = settings }
    }

    // MARK: - 开始处理

    /// 启动视频处理管线
    func startProcessing() {
        guard let project = currentProject else {
            showToast("未选择项目", style: .error)
            return
        }
        guard !project.segments.isEmpty else {
            showToast("没有可处理的片段", style: .error)
            return
        }

        let video = project.videoInfo
        logger.info("开始处理: \(video.fileName, privacy: .public)")

        // 同步到旧版参数（管线使用）
        selectedVideo = video
        frameMultiplier = project.enhancement.frameMultiplier
        fastMode = false

        isProcessing = true
        progress = 0
        processedFrames = 0
        stage = .decoding
        processingStartTime = Date()

        // 构建任务清单
        setupProcessingTasks(for: project)

        beginBackgroundTask()

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
                self.updateProcessingTasks(stage: stage, progress: value)
                if let start = self.processingStartTime, value > 0.01 {
                    let elapsed = Date().timeIntervalSince(start)
                    self.estimatedRemaining = elapsed * (1.0 - value) / value
                }
            },
            completion: { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let url):
                    self.stage = .finished
                    self.progress = 1.0
                    self.estimatedRemaining = 0
                    self.outputURL = url
                    self.processingMode = self.buildProcessingModeDescription(project: project)
                    self.markAllTasksCompleted()

                    // 更新项目状态
                    self.updateCurrentProject {
                        $0.status = .completed
                        $0.outputURL = url
                    }

                    // 追加最近记录
                    let outputFPS = video.originalFPS * Double(self.frameMultiplier.rawValue)
                    self.appendRecentRecord(outputURL: url, outputFPS: outputFPS)
                    self.showToast("处理完成")
                    self.logger.info("处理完成: \(url.lastPathComponent, privacy: .public)")

                    // 记录实测速度系数
                    if let start = self.processingStartTime, video.duration > 0 {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 0 {
                            let speedFactor = video.duration / elapsed
                            let averaged = self.measuredSpeedFactor.map { ($0 * 0.7) + (speedFactor * 0.3) } ?? speedFactor
                            self.measuredSpeedFactor = averaged
                            UserDefaults.standard.set(averaged, forKey: self.processingSpeedKey)
                        }
                    }
                    self.endBackgroundTask()

                case .failure(let error):
                    self.isProcessing = false
                    self.isProcessingMinimized = false
                    self.stage = .failed
                    self.estimatedRemaining = 0
                    self.outputURL = nil
                    self.markAllTasksFailed()
                    self.updateCurrentProject { $0.status = .failed }
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

    /// 构建处理模式描述
    private func buildProcessingModeDescription(project: Project) -> String {
        switch project.enhancement.mode {
        case .frameInterpolation:
            return "AI补帧（\(project.enhancement.frameMultiplier.label)）"
        case .superResolution:
            return "超分（\(project.enhancement.srModel.rawValue)）"
        case .none:
            return "基础导出"
        }
    }

    /// 构建处理任务清单
    private func setupProcessingTasks(for project: Project) {
        var tasks: [ProcessingTask] = []
        tasks.append(ProcessingTask(name: "剪辑合成", status: .waiting, progress: nil))

        switch project.enhancement.mode {
        case .frameInterpolation:
            tasks.append(ProcessingTask(name: "补帧增强", status: .waiting, progress: nil))
        case .superResolution:
            tasks.append(ProcessingTask(name: "超分增强", status: .waiting, progress: nil))
        case .none:
            break
        }

        if project.enhancement.clarity.hasAnyEnabled {
            tasks.append(ProcessingTask(name: "清晰度优化", status: .waiting, progress: nil))
        }
        if project.enhancement.audio.repairEnabled {
            tasks.append(ProcessingTask(name: "音频修复", status: .waiting, progress: nil))
        }
        tasks.append(ProcessingTask(name: "编码输出", status: .waiting, progress: nil))

        processingTasks = tasks
    }

    /// 根据处理阶段更新任务状态
    private func updateProcessingTasks(stage: ProcessingStage, progress: Double) {
        guard !processingTasks.isEmpty else { return }
        var updated = processingTasks

        // 简单映射：decoding → 第一个任务 running，inferring → 中间任务，encoding → 最后一个
        switch stage {
        case .decoding:
            if let firstIndex = updated.firstIndex(where: { $0.status == .waiting }) {
                updated[firstIndex].status = .running
                updated[firstIndex].progress = progress
            }
        case .inferring:
            // 标记第一个完成，当前运行的设为进度
            for i in updated.indices {
                if updated[i].status == .running {
                    updated[i].status = .completed
                    updated[i].progress = 1.0
                    break
                }
            }
            if let runningIndex = updated.firstIndex(where: { $0.status == .waiting }) {
                updated[runningIndex].status = .running
                updated[runningIndex].progress = progress
            }
        case .encoding:
            for i in updated.indices {
                if updated[i].status == .running {
                    updated[i].status = .completed
                    updated[i].progress = 1.0
                }
            }
            if let lastIndex = updated.lastIndex(where: { $0.status == .waiting }) {
                updated[lastIndex].status = .running
                updated[lastIndex].progress = progress
            } else if let last = updated.indices.last {
                updated[last].status = .running
                updated[last].progress = progress
            }
        case .finished:
            for i in updated.indices {
                updated[i].status = .completed
                updated[i].progress = 1.0
            }
        default:
            break
        }

        processingTasks = updated
    }

    private func markAllTasksCompleted() {
        processingTasks = processingTasks.map {
            var t = $0
            t.status = .completed
            t.progress = 1.0
            return t
        }
    }

    private func markAllTasksFailed() {
        processingTasks = processingTasks.map {
            var t = $0
            if t.status == .running {
                t.status = .waiting
            }
            return t
        }
    }

    // MARK: - 取消处理

    func cancelProcessing() {
        pipeline.cancel()
        isProcessing = false
        isProcessingMinimized = false
        stage = .idle
        progress = 0
        processingTasks = []
        endBackgroundTask()
        logger.info("处理已取消")
    }

    // MARK: - 后台任务

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "视频增强处理") { [weak self] in
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

    func minimizeProcessing() {
        guard isProcessing else { return }
        isProcessingMinimized = true
        isProcessing = false
    }

    func restoreProcessingView() {
        guard isProcessingMinimized else { return }
        isProcessingMinimized = false
        isProcessing = true
    }

    // MARK: - 切后台通知

    func applicationDidEnterBackground() {
        guard (isProcessing || isProcessingMinimized) && outputURL == nil else { return }
        sendBackgroundNotification(
            title: "视频处理中",
            body: "你刚切到后台，处理将继续约30秒，点我回到App继续",
            identifier: "bz_bg_warning"
        )
    }

    func backgroundTimeExpiring() {
        guard (isProcessing || isProcessingMinimized) && outputURL == nil else { return }
        sendBackgroundNotification(
            title: "处理即将暂停",
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

    // MARK: - 重置全部状态

    func resetAll() {
        logger.info("重置全部状态，返回首页")
        pipeline.cancel()
        outputURL = nil
        processingMode = ""
        debugInfo = ""
        isProcessing = false
        isProcessingMinimized = false
        showProjectDetail = false
        showExportSettings = false
        currentProject = nil
        selectedVideo = nil
        stage = .idle
        progress = 0
        processedFrames = 0
        totalFrames = 0
        processingTasks = []
        undoStack.removeAll()
    }

    /// 从项目详情返回首页
    func closeProjectDetail() {
        showProjectDetail = false
        currentProject = nil
        undoStack.removeAll()
    }

    // MARK: - 最近记录

    private func appendRecentRecord(outputURL: URL, outputFPS: Double) {
        let thumbnail = generateThumbnail(from: outputURL)
        let record = RecentRecord(
            fileName: outputURL.lastPathComponent,
            outputFPS: outputFPS,
            thumbnailData: thumbnail
        )
        recentRecords.insert(record, at: 0)
        if recentRecords.count > 20 {
            recentRecords = Array(recentRecords.prefix(20))
        }
        saveRecentRecords()
    }

    // MARK: - 缓存管理

    /// 计算缓存大小（MB）
    var cacheSizeMB: Double {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        let totalBytes = files.compactMap { url -> Int? in
            try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)
        return Double(totalBytes) / 1024.0 / 1024.0
    }

    /// 清除缓存
    func clearCache() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) else { return }
        for file in files {
            let path = tempDir.appendingPathComponent(file).path
            try? FileManager.default.removeItem(atPath: path)
        }
        showToast("缓存已清除")
    }

    // MARK: - Toast

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

    // MARK: - 触觉反馈

    private func triggerHaptic() {
        guard hapticFeedbackEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}

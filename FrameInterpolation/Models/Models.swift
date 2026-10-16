import Foundation
import UIKit
import SwiftUI

// MARK: - 视频信息
/// 视频元数据模型，包含导入视频的全部属性
struct VideoInfo: Identifiable, Equatable, Codable {
    let id: UUID
    /// 视频文件 URL（沙盒临时目录）
    let url: URL
    /// 文件名
    let fileName: String
    /// 时长（秒）
    let duration: TimeInterval
    /// 原始帧率
    let originalFPS: Double
    /// 原始文件大小（MB）
    let originalSizeMB: Double
    /// 显示宽度（像素，已应用旋转）
    let width: Int
    /// 显示高度（像素，已应用旋转）
    let height: Int
    /// 视频编码格式（如 H.264 / HEVC）
    let codecFormat: String
    /// 视频码率（Mbps）
    let bitRateMbps: Double
    /// 缩略图数据（JPEG）
    let thumbnailData: Data?

    /// 缩略图
    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }

    init(id: UUID = UUID(), url: URL, fileName: String, duration: TimeInterval,
         originalFPS: Double, originalSizeMB: Double, width: Int, height: Int,
         codecFormat: String, bitRateMbps: Double, thumbnailData: Data? = nil) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.duration = duration
        self.originalFPS = originalFPS
        self.originalSizeMB = originalSizeMB
        self.width = width
        self.height = height
        self.codecFormat = codecFormat
        self.bitRateMbps = bitRateMbps
        self.thumbnailData = thumbnailData
    }

    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.id == rhs.id
    }

    enum CodingKeys: String, CodingKey {
        case id, url, fileName, duration, originalFPS, originalSizeMB
        case width, height, codecFormat, bitRateMbps, thumbnailData
    }
}

// MARK: - 最近处理记录（兼容旧版，保留）
struct RecentRecord: Identifiable, Equatable, Codable {
    let id: UUID
    let fileName: String
    let outputFPS: Double
    let createdAt: Date
    let thumbnailData: Data?

    init(id: UUID = UUID(), fileName: String, outputFPS: Double, createdAt: Date = Date(), thumbnailData: Data? = nil) {
        self.id = id
        self.fileName = fileName
        self.outputFPS = outputFPS
        self.createdAt = createdAt
        self.thumbnailData = thumbnailData
    }
}

// MARK: - 项目状态
enum ProjectStatus: String, Codable {
    case draft = "草稿"
    case processing = "处理中"
    case completed = "完成"
    case failed = "失败"

    /// 状态图标名
    var iconName: String {
        switch self {
        case .draft: return "pencil.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    /// 状态颜色
    var color: Color {
        switch self {
        case .draft: return DesignTokens.Colors.textSecondary
        case .processing: return DesignTokens.Colors.accent
        case .completed: return DesignTokens.Colors.success
        case .failed: return DesignTokens.Colors.error
        }
    }
}

// MARK: - 视频片段
/// 时间线上的视频片段，源文件只读，仅记录时间范围
struct VideoSegment: Identifiable, Equatable, Codable {
    let id: UUID
    /// 起始时间（秒）
    var startTime: TimeInterval
    /// 持续时长（秒）
    var duration: TimeInterval
    /// 缩略图数据（JPEG，可选）
    var thumbnailData: Data?

    /// 结束时间
    var endTime: TimeInterval { startTime + duration }

    /// 缩略图
    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }

    init(id: UUID = UUID(), startTime: TimeInterval, duration: TimeInterval, thumbnailData: Data? = nil) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.thumbnailData = thumbnailData
    }

    static func == (lhs: VideoSegment, rhs: VideoSegment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 增强模式（互斥：补帧 / 超分 / 无）
enum EnhancementMode: String, CaseIterable, Identifiable, Codable {
    case none = "无"
    case frameInterpolation = "补帧"
    case superResolution = "超分"

    var id: String { rawValue }
}

// MARK: - 补帧倍数
enum FrameMultiplier: Int, CaseIterable, Identifiable, Codable {
    case x2 = 2
    case x4 = 4

    var id: Int { rawValue }
    var label: String { "\(rawValue)x" }
}

// MARK: - 超分模型
enum SuperResolutionModel: String, CaseIterable, Identifiable, Codable {
    case piperSR = "PiperSR"
    case esrgan = "Real-ESRGAN"

    var id: String { rawValue }
}

// MARK: - 清晰度增强配置
struct ClarityConfig: Codable {
    /// 降噪
    var denoiseEnabled: Bool = false
    var denoiseIntensity: Double = 0.5
    /// 锐化
    var sharpenEnabled: Bool = false
    var sharpenIntensity: Double = 0.4
    /// 对比度
    var contrastEnabled: Bool = false
    var contrastIntensity: Double = 1.1
    /// 色彩
    var colorEnabled: Bool = false
    var colorIntensity: Double = 1.05

    /// 是否有任何清晰度增强启用
    var hasAnyEnabled: Bool {
        denoiseEnabled || sharpenEnabled || contrastEnabled || colorEnabled
    }
}

// MARK: - 音频配置
struct AudioConfig: Codable {
    /// 音频修复（保持原始音频，修复容器兼容）
    var repairEnabled: Bool = false
}

// MARK: - 增强配置
struct EnhancementConfig: Codable {
    /// 主增强模式（互斥）
    var mode: EnhancementMode = .none
    /// 补帧倍数
    var frameMultiplier: FrameMultiplier = .x2
    /// 超分模型
    var srModel: SuperResolutionModel = .piperSR
    /// 清晰度增强
    var clarity: ClarityConfig = ClarityConfig()
    /// 音频
    var audio: AudioConfig = AudioConfig()
}

// MARK: - 导出设置
enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }
}

enum BitrateMode: String, CaseIterable, Identifiable, Codable {
    case auto = "自动"
    case high = "高画质"
    case balanced = "均衡"
    case small = "小体积"
    var id: String { rawValue }

    /// 码率系数
    var factor: Double {
        switch self {
        case .auto: return 1.0
        case .high: return 1.5
        case .balanced: return 1.0
        case .small: return 0.6
        }
    }
}

enum ContainerFormat: String, CaseIterable, Identifiable, Codable {
    case auto = "自动"
    case mov = "MOV"
    case mp4 = "MP4"
    var id: String { rawValue }
}

enum AudioMode: String, CaseIterable, Identifiable, Codable {
    case passthrough = "透传"
    case aac = "AAC 重编码"
    var id: String { rawValue }
}

struct ExportSettings: Codable {
    var codec: VideoCodec = .hevc
    var bitrateMode: BitrateMode = .auto
    var container: ContainerFormat = .auto
    var audioMode: AudioMode = .passthrough
}

// MARK: - 输出分辨率（兼容旧版）
enum OutputResolution: String, CaseIterable, Identifiable, Codable {
    case auto = "自动"
    case p720 = "720p"
    case p1080 = "1080p"

    var id: String { rawValue }
}

// MARK: - 输出帧率模式
enum OutputFPSMode: String, CaseIterable, Identifiable, Codable {
    case original = "保持原样"
    case fps60 = "60fps"
    case fps120 = "120fps"

    var id: String { rawValue }
}

// MARK: - 任务标签类型
enum TaskTagType {
    case frameInterpolation
    case superResolution
    case sharpen
    case denoise
    case contrast
    case audioRepair

    var label: String {
        switch self {
        case .frameInterpolation: return "补帧"
        case .superResolution: return "超分"
        case .sharpen: return "锐化"
        case .denoise: return "降噪"
        case .contrast: return "对比度"
        case .audioRepair: return "音频修复"
        }
    }

    var color: Color {
        switch self {
        case .frameInterpolation: return DesignTokens.Colors.accent
        case .superResolution: return DesignTokens.Colors.success
        case .sharpen, .denoise, .contrast: return DesignTokens.Colors.warning
        case .audioRepair: return DesignTokens.Colors.textSecondary
        }
    }
}

// MARK: - 项目
/// 视频增强项目，包含源视频、片段编辑、增强配置、导出设置
struct Project: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// 源视频信息（只读）
    var videoInfo: VideoInfo
    /// 时间线片段（至少 1 个）
    var segments: [VideoSegment]
    /// 增强配置
    var enhancement: EnhancementConfig
    /// 导出设置
    var exportSettings: ExportSettings
    /// 项目状态
    var status: ProjectStatus
    /// 输出视频 URL（处理完成后）
    var outputURL: URL?
    /// 创建时间
    let createdAt: Date
    /// 更新时间
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, videoInfo: VideoInfo,
         segments: [VideoSegment], enhancement: EnhancementConfig = EnhancementConfig(),
         exportSettings: ExportSettings = ExportSettings(),
         status: ProjectStatus = .draft, outputURL: URL? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.videoInfo = videoInfo
        self.segments = segments
        self.enhancement = enhancement
        self.exportSettings = exportSettings
        self.status = status
        self.outputURL = outputURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    /// 总时长（所有片段之和）
    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// 任务标签列表
    var taskTags: [TaskTagType] {
        var tags: [TaskTagType] = []
        switch enhancement.mode {
        case .frameInterpolation: tags.append(.frameInterpolation)
        case .superResolution: tags.append(.superResolution)
        case .none: break
        }
        if enhancement.clarity.denoiseEnabled { tags.append(.denoise) }
        if enhancement.clarity.sharpenEnabled { tags.append(.sharpen) }
        if enhancement.clarity.contrastEnabled { tags.append(.contrast) }
        if enhancement.audio.repairEnabled { tags.append(.audioRepair) }
        return tags
    }

    /// 分辨率描述
    var resolutionLabel: String {
        "\(videoInfo.width)×\(videoInfo.height)"
    }

    /// 帧率描述
    var fpsLabel: String {
        "\(Int(videoInfo.originalFPS))fps"
    }
}

// MARK: - 处理阶段
enum ProcessingStage: String {
    case idle = "准备中"
    case decoding = "正在解码视频…"
    case inferring = "AI 正在计算光流…"
    case encoding = "正在编码输出…"
    case finished = "处理完成"
    case failed = "处理失败"
}

// MARK: - 处理任务项（用于任务清单）
struct ProcessingTask: Identifiable {
    let id = UUID()
    let name: String
    var status: TaskStatus
    var progress: Double?

    enum TaskStatus {
        case waiting
        case running
        case completed
    }
}

// MARK: - Toast 样式
enum ToastStyle {
    case success
    case error
    case warning
}

// MARK: - 时间格式化
enum TimeFormatter {
    /// 格式化为 mm:ss
    static func format(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// 格式化为 分秒中文
    static func formatChinese(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if seconds == 0 {
            return "\(minutes) 分钟"
        }
        return "\(minutes) 分 \(seconds) 秒"
    }
}

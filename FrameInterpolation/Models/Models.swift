import Foundation
import UIKit

// MARK: - 视频信息
/// 视频元数据模型，包含导入视频的全部属性
struct VideoInfo: Identifiable, Equatable {
    let id = UUID()
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
    /// 缩略图
    let thumbnail: UIImage?

    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 最近处理记录
struct RecentRecord: Identifiable, Equatable, Codable {
    let id: UUID
    let fileName: String
    /// 用户自定义显示名（重命名后覆盖fileName显示）
    var displayName: String?
    let outputFPS: Double
    let createdAt: Date
    let thumbnailData: Data?
    /// 处理模式描述（如 "AI补帧（2x）" 或 "AI超分（Fast-SRGAN 4x）"）
    let processingMode: String?
    /// 输出宽度（像素）
    let outputWidth: Int?
    /// 输出高度（像素）
    let outputHeight: Int?
    /// 输出文件大小（MB）
    let fileSizeMB: Double?
    /// 视频时长（秒）
    let duration: TimeInterval?
    /// 输出文件路径（沙盒临时目录，可能已被清理）
    let outputPath: String?

    /// 显示用名称：优先displayName，否则fileName
    var displayFileName: String {
        displayName ?? fileName
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String? = nil,
        outputFPS: Double,
        createdAt: Date = Date(),
        thumbnailData: Data? = nil,
        processingMode: String? = nil,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        fileSizeMB: Double? = nil,
        duration: TimeInterval? = nil,
        outputPath: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.outputFPS = outputFPS
        self.createdAt = createdAt
        self.thumbnailData = thumbnailData
        self.processingMode = processingMode
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.fileSizeMB = fileSizeMB
        self.duration = duration
        self.outputPath = outputPath
    }

    /// 格式化的创建时间（如 "今天 14:30"、"昨天 09:15"、"10月15日"）
    var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: createdAt))"
        } else if calendar.isDateInYesterday(createdAt) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "昨天 \(formatter.string(from: createdAt))"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: createdAt)
        }
    }

    /// 格式化的分辨率（如 "1920×1080"）
    var resolutionText: String? {
        guard let w = outputWidth, let h = outputHeight, w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }

    /// 格式化的时长（如 "1:30"）
    var durationText: String? {
        guard let d = duration, d > 0 else { return nil }
        let minutes = Int(d) / 60
        let seconds = Int(d) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// 格式化的文件大小（如 "12.5 MB"）
    var fileSizeText: String? {
        guard let size = fileSizeMB, size > 0 else { return nil }
        if size < 1 {
            return String(format: "%.0f KB", size * 1024)
        }
        return String(format: "%.1f MB", size)
    }
}

// MARK: - 补帧倍数
enum FrameMultiplier: Int, CaseIterable, Identifiable {
    case x2 = 2
    case x4 = 4

    var id: Int { rawValue }
    var label: String { "\(rawValue)x" }
}

// MARK: - 输出分辨率
enum OutputResolution: String, CaseIterable, Identifiable {
    case auto = "自动"
    case p720 = "720p"
    case p1080 = "1080p"

    var id: String { rawValue }
}

// MARK: - 处理阶段
enum ProcessingStage: String {
    case idle = "准备中"
    case decoding = "正在解码视频…"
    case inferring = "AI 正在计算光流…"
    case superResolving = "AI 正在超分增强…"
    case encoding = "正在编码输出…"
    case finished = "处理完成"
    case failed = "处理失败"
}

// MARK: - Toast 样式
enum ToastStyle {
    case success
    case error
    case warning
}

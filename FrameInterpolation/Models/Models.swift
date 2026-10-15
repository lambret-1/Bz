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

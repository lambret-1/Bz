import Foundation

/// 视频元数据模型（阶段0占位，后续由 MediaImporter 填充真实数据）
struct VideoInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let duration: TimeInterval
    let originalFPS: Double
    let originalSizeMB: Double
}

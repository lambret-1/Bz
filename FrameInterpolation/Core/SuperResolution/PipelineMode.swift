import Foundation

// MARK: - 处理模式（补帧与超分互斥）

/// 视频处理模式：补帧与超分互斥，每次处理只能选择一种
/// - 补帧模式：使用 RIFE Lite 提升帧率（2x / 4x）
/// - 超分模式：使用 Fast-SRGAN 或 Real-ESRGAN 提升分辨率，帧率保持不变
enum PipelineMode: Equatable {
    /// 补帧模式，关联补帧倍数
    case interpolation(FrameMultiplier)
    /// 超分模式，关联超分引擎类型
    case superResolution(SuperResolutionEngineType)

    /// 显示名称
    var displayName: String {
        switch self {
        case .interpolation(let multiplier):
            return "补帧 \(multiplier.label)"
        case .superResolution(let engine):
            return "超分 \(engine.displayName)"
        }
    }

    /// 简短描述（用于结果页）
    var shortDescription: String {
        switch self {
        case .interpolation(let multiplier):
            return "AI补帧（\(multiplier.label)）"
        case .superResolution(let engine):
            return "AI超分（\(engine.displayName)）"
        }
    }

    /// 是否为补帧模式
    var isInterpolation: Bool {
        if case .interpolation = self { return true }
        return false
    }

    /// 是否为超分模式
    var isSuperResolution: Bool {
        if case .superResolution = self { return true }
        return false
    }
}

// MARK: - 超分引擎类型

/// 超分引擎类型枚举
enum SuperResolutionEngineType: String, CaseIterable, Identifiable {
    /// Fast-SRGAN：4x 超分，128×128 瓦片，轻量快速，适合通用场景
    case fastSRGAN = "Fast-SRGAN"
    /// Real-ESRGAN x4v3：4x 超分，128×128 瓦片拼接，适合极低清素材
    case realESRGAN = "Real-ESRGAN"

    var id: String { rawValue }

    /// 显示名称
    var displayName: String {
        switch self {
        case .fastSRGAN:
            return "Fast-SRGAN 4x"
        case .realESRGAN:
            return "Real-ESRGAN 4x"
        }
    }

    /// 放大倍数
    var scaleFactor: Int {
        switch self {
        case .fastSRGAN:
            return 4
        case .realESRGAN:
            return 4
        }
    }

    /// 引擎描述
    var engineDescription: String {
        switch self {
        case .fastSRGAN:
            return "4x 放大，轻量快速，适合通用低清视频"
        case .realESRGAN:
            return "4x 放大，细节恢复强，适合极低清素材（速度较慢）"
        }
    }

    /// 推荐输入最大高度（超过此高度建议先缩放）
    var recommendedInputMaxHeight: Int {
        switch self {
        case .fastSRGAN:
            return 540
        case .realESRGAN:
            return 480
        }
    }

    /// 模型文件名（不含扩展名）
    var modelFileName: String {
        switch self {
        case .fastSRGAN:
            return "fast_srgan"
        case .realESRGAN:
            return "real_esrgan_x4v3"
        }
    }
}

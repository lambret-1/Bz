import Foundation

// MARK: - 处理模式（补帧与超分互斥）

/// 视频处理模式：补帧与超分互斥，每次处理只能选择一种
/// - 补帧模式：使用 RIFE Lite 提升帧率（2x / 4x）
/// - 超分模式：使用 Fast-SRGAN 或 Real-ESRGAN 提升分辨率，帧率保持不变，放大倍数 1-4x 可调
enum PipelineMode: Equatable {
    /// 补帧模式，关联补帧倍数
    case interpolation(FrameMultiplier)
    /// 超分模式，关联超分引擎类型和放大倍数（1-4x）
    case superResolution(SuperResolutionEngineType, SuperResolutionScale)

    /// 显示名称
    var displayName: String {
        switch self {
        case .interpolation(let multiplier):
            return "补帧 \(multiplier.label)"
        case .superResolution(let engine, let scale):
            return "超分 \(engine.shortName) \(scale.label)"
        }
    }

    /// 简短描述（用于结果页）
    var shortDescription: String {
        switch self {
        case .interpolation(let multiplier):
            return "AI补帧（\(multiplier.label)）"
        case .superResolution(let engine, let scale):
            return "AI超分（\(engine.shortName) \(scale.label)）"
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

// MARK: - 超分放大倍数（1-4x 可调）

/// 超分放大倍数：模型原生 4x，1x/2x/3x 通过 4x 超分后缩放到目标尺寸实现
enum SuperResolutionScale: Int, CaseIterable, Identifiable {
    case x1 = 1
    case x2 = 2
    case x3 = 3
    case x4 = 4

    var id: Int { rawValue }

    /// 显示标签
    var label: String { "\(rawValue)x" }

    /// 是否需要执行 AI 超分（1x 时可跳过，直接复制帧）
    var needsAISuperResolution: Bool { rawValue > 1 }
}

// MARK: - 超分引擎类型

/// 超分引擎类型枚举
enum SuperResolutionEngineType: String, CaseIterable, Identifiable {
    /// PiperSR 2x：2x 超分，640×360 全帧推理，ANE 原生，速度快
    case fastSRGAN = "PiperSR"
    /// Real-ESRGAN x4v3：4x 超分，128×128 瓦片拼接，适合极低清素材
    case realESRGAN = "Real-ESRGAN"

    var id: String { rawValue }

    /// 短名称（用于显示）
    var shortName: String {
        switch self {
        case .fastSRGAN: return "PiperSR"
        case .realESRGAN: return "Real-ESRGAN"
        }
    }

    /// 显示名称（含原生放大倍数）
    var displayName: String {
        switch self {
        case .fastSRGAN:
            return "PiperSR（原生2x）"
        case .realESRGAN:
            return "Real-ESRGAN（原生4x）"
        }
    }

    /// 模型原生放大倍数
    var nativeScaleFactor: Int {
        switch self {
        case .fastSRGAN: return 2
        case .realESRGAN: return 4
        }
    }

    /// 引擎描述
    var engineDescription: String {
        switch self {
        case .fastSRGAN:
            return "ANE 原生，全帧推理，速度快"
        case .realESRGAN:
            return "细节恢复强，适合极低清素材（速度较慢）"
        }
    }

    /// 推荐输入最大高度（超过此高度建议先缩放）
    var recommendedInputMaxHeight: Int {
        switch self {
        case .fastSRGAN:
            return 360
        case .realESRGAN:
            return 480
        }
    }

    /// 模型文件名（不含扩展名）
    var modelFileName: String {
        switch self {
        case .fastSRGAN:
            return "PiperSR_2x_video_720p"
        case .realESRGAN:
            return "real_esrgan_x4v3"
        }
    }
}

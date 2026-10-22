import Foundation

enum PipelineMode: Equatable {
    case interpolation(FrameMultiplier)
    case superResolution(SuperResolutionEngineType, SuperResolutionScale)

    var displayName: String {
        switch self {
        case .interpolation(let m): return "补帧 \(m.label)"
        case .superResolution(let e, let s): return "超分 \(e.shortName) \(s.label)"
        }
    }

    var shortDescription: String {
        switch self {
        case .interpolation: return "AI补帧"
        case .superResolution(let e, let s): return "AI超分（\(e.shortName) \(s.label)）"
        }
    }

    var isInterpolation: Bool { if case .interpolation = self { return true }; return false }
    var isSuperResolution: Bool { if case .superResolution = self { return true }; return false }
}

enum SuperResolutionScale: Int, CaseIterable, Identifiable {
    case x1 = 1, x2 = 2, x3 = 3, x4 = 4
    var id: Int { rawValue }
    var label: String { "\(rawValue)x" }
    var needsAISuperResolution: Bool { rawValue > 1 }
}

enum SuperResolutionEngineType: String, CaseIterable, Identifiable {
    case realESRGAN = "Real-ESRGAN"
    var id: String { rawValue }
    var shortName: String { "Real-ESRGAN" }
    var displayName: String { "Real-ESRGAN（原生4x）" }
    var nativeScaleFactor: Int { 4 }
    var engineDescription: String { "细节恢复强，适合极低清素材" }
    var recommendedInputMaxHeight: Int { 480 }
    var modelFileName: String { "real_esrgan_x4v3" }
}

import CoreVideo
import Foundation

// MARK: - 超分引擎协议

/// 超分引擎协议：所有超分模型必须实现此接口
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为 vImage 缩放
protocol SuperResolutionEngine: AnyObject {
    /// 引擎类型
    static var engineType: SuperResolutionEngineType { get }

    /// 对单帧执行超分
    /// - Parameter pixelBuffer: 输入帧（32BGRA CVPixelBuffer）
    /// - Returns: 超分后的帧（32BGRA CVPixelBuffer），失败返回 nil
    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?

    /// 模型输入宽度（固定尺寸引擎使用，瓦片引擎返回单瓦片宽度）
    var inputWidth: Int { get }

    /// 模型输入高度
    var inputHeight: Int { get }

    /// 输出放大倍数
    var scaleFactor: Int { get }
}

// MARK: - 超分引擎工厂

/// 超分引擎工厂：根据类型创建对应引擎，模型缺失时返回 nil
enum SuperResolutionEngineFactory {
    /// 创建指定类型的超分引擎
    /// - Parameter type: 引擎类型
    /// - Returns: 引擎实例，模型文件缺失或初始化失败时返回 nil
    static func makeEngine(type: SuperResolutionEngineType) -> SuperResolutionEngine? {
        switch type {
        case .piperSR:
            return PiperSREngine()
        case .realESRGAN:
            return RealESRGANEngine()
        }
    }
}

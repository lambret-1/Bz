import Metal
import OSLog

/// Metal 全局上下文：设备、命令队列、着色器库、计算管线缓存
/// 单例模式，整个 App 共享一份 Metal 资源，避免重复创建
final class MetalContext {
    static let shared = MetalContext()
    private let logger = Logger(subsystem: "com.lambret.bz", category: "MetalContext")

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    /// 计算管线缓存，避免重复编译
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Metal 初始化失败：当前设备可能不支持 Metal")
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        logger.info("Metal 上下文初始化成功，设备: \(device.name)")
    }

    /// 获取或创建指定名称的计算管线状态
    /// - Parameter name: 着色器函数名称（与 Shaders.metal 中的 kernel 函数名一致）
    /// - Returns: 计算管线状态，失败返回 nil
    func makePipeline(named name: String) -> MTLComputePipelineState? {
        cacheLock.lock()
        if let cached = pipelineCache[name] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let function = library.makeFunction(name: name) else {
            logger.error("未找到着色器函数: \(name, privacy: .public)")
            return nil
        }

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            cacheLock.lock()
            pipelineCache[name] = pipeline
            cacheLock.unlock()
            return pipeline
        } catch {
            logger.error("创建计算管线失败: \(name, privacy: .public), 错误: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

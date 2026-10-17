import CoreVideo
import Foundation

/// CVPixelBuffer 内存池管理器：按尺寸+格式复用缓冲，避免循环中频繁分配释放内存
/// 池容量 minBufferCount=12，覆盖三队列流水线峰值需求（队列积压+处理中+IO）
final class PixelBufferPoolManager {
    /// 池标识：尺寸+像素格式
    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let lock = NSLock()
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private let minBufferCount: Int

    init(minBufferCount: Int = 12) {
        self.minBufferCount = minBufferCount
    }

    /// 获取或创建指定尺寸+格式的池
    private func pool(for width: Int, _ height: Int, _ pixelFormat: OSType) -> CVPixelBufferPool? {
        let key = PoolKey(width: width, height: height, pixelFormat: pixelFormat)
        lock.lock()
        defer { lock.unlock() }
        if let existing = pools[key] { return existing }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: minBufferCount
        ]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let newPool = pool else { return nil }
        pools[key] = newPool
        return newPool
    }

    /// 从池中获取一个 buffer（池枯竭时返回 nil，调用方应降级为 CVPixelBufferCreate）
    func makeBuffer(width: Int, _ height: Int, _ pixelFormat: OSType) -> CVPixelBuffer? {
        guard let pool = pool(for: width, height, pixelFormat) else { return nil }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return result == kCVReturnSuccess ? buffer : nil
    }

    /// 清空所有池（处理完成后调用释放内存）
    func reset() {
        lock.lock()
        pools.removeAll()
        lock.unlock()
    }
}

import Metal
import CoreVideo

/// Metal 计算辅助工具：封装纹理创建、缓冲区管理等通用操作
final class MetalComputeHelper {
    static let shared = MetalComputeHelper()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal 初始化失败")
        }
        self.device = device
        self.commandQueue = queue
    }

    /// 把 CVPixelBuffer(BGRA) 包装为 MTLTexture（零拷贝，依赖 IOSurface）
    func makeTexture(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var texture: MTLTexture?
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared

        texture = device.makeTexture(descriptor: descriptor)
        texture?.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    /// 创建一个空的 RGBA 纹理，用作 Metal 的中间缓冲
    func makeEmptyTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// 把 MTLTexture 内容拷回 CVPixelBuffer
    func copy(texture: MTLTexture, to pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
}

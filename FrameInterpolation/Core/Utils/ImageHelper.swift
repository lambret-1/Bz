import UIKit
import CoreVideo

extension UIImage {
    /// 将 UIImage 无损转为 CVPixelBuffer (BGRA 格式)
    func toCVPixelBuffer() -> CVPixelBuffer? {
        // 注意：如果你的图片非常大，建议在这里先限制一下最大尺寸，防止内存爆掉
        let width = Int(self.size.width)
        let height = Int(self.size.height)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferIOSurfacePropertiesKey: [:] // 开启硬件加速
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        // 注意：UIImage 可能是旋转过的，这里直接 draw 就可以
        context.draw(self.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

extension CVPixelBuffer {
    /// 将 CVPixelBuffer 转为 UIImage
    func toUIImage() -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

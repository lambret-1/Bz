import UIKit

class ImageSuperResolutionService {
    private var engine: RealESRGANx4Engine?

    init() {
        // 懒加载：第一次处理图片时才加载
    }

    /// 处理图片（在后台线程执行，完成后切回主线程）
    func processImage(_ inputImage: UIImage, completion: @escaping (UIImage?) -> Void) {
        if engine == nil {
            engine = RealESRGANx4Engine()
        }
        guard let engine = engine else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                guard let inputBuffer = inputImage.toCVPixelBuffer() else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                guard let outputBuffer = engine.upscale(inputBuffer) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let resultImage = outputBuffer.toUIImage()
                DispatchQueue.main.async {
                    completion(resultImage)
                }
            }
        }
    }
}

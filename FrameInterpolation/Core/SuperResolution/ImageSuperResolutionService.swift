import UIKit

class ImageSuperResolutionService {
    private let engine: RealESRGANEngine?
    
    init() {
        // 初始化引擎（复用你刚才写好的那个）
        self.engine = RealESRGANEngine()
    }
    
    /// 处理图片（在后台线程执行，完成后切回主线程）
    func processImage(_ inputImage: UIImage, completion: @escaping (UIImage?) -> Void) {
        guard let engine = engine else {
            completion(nil)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                // 1. 转格式
                guard let inputBuffer = inputImage.toCVPixelBuffer() else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                // 2. 调用你的 AI 引擎（内部包含切瓦片、填充、拼接）
                guard let outputBuffer = engine.upscale(inputBuffer) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                // 3. 转回图片
                let resultImage = outputBuffer.toUIImage()
                
                // 4. 回主线程通知 UI
                DispatchQueue.main.async {
                    completion(resultImage)
                }
            }
        }
    }
}

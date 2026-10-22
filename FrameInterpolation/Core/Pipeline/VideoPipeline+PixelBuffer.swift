@preconcurrency import AVFoundation
import CoreVideo
import OSLog
import Accelerate

extension VideoPipeline {
    // MARK: - CVPixelBuffer 深拷贝（防止 reader 复用内存覆盖前一帧）
    func deepCopyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        // 优先从内存池获取，池枯竭时降级为临时分配
        var resultBuffer: CVPixelBuffer? = bufferPool.makeBuffer(width: width, height, pixelFormat)
        if resultBuffer == nil {
            let attrs = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs, &resultBuffer) == kCVReturnSuccess,
                  let result = resultBuffer else {
                return nil
            }
            resultBuffer = result
        }
        guard let result = resultBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        guard let srcAddr = CVPixelBufferGetBaseAddress(source),
              let dstAddr = CVPixelBufferGetBaseAddress(result) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let bytesPerRow = min(srcBytesPerRow, dstBytesPerRow)

        for row in 0..<height {
            memcpy(dstAddr.advanced(by: row * dstBytesPerRow),
                   srcAddr.advanced(by: row * srcBytesPerRow),
                   bytesPerRow)
        }

        // 复制颜色空间附件
        copyColorSpaceAttachments(from: source, to: result)

        return result
    }

    // MARK: - vImage 缩放 CVPixelBuffer（输出分辨率控制）
    func scalePixelBuffer(_ source: CVPixelBuffer, to width: Int, _ height: Int) -> CVPixelBuffer? {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let srcData = CVPixelBufferGetBaseAddress(source) else {
            return nil
        }
        var srcBuffer = vImage_Buffer(
            data: srcData,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )

        // 优先从内存池获取，池枯竭时降级为临时分配
        var dstPixelBuffer: CVPixelBuffer? = bufferPool.makeBuffer(width: width, height, kCVPixelFormatType_32BGRA)
        if dstPixelBuffer == nil {
            let attrs = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &dstPixelBuffer) == kCVReturnSuccess,
                  let dst = dstPixelBuffer else {
                return nil
            }
            dstPixelBuffer = dst
        }
        guard let dst = dstPixelBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        guard let dstData = CVPixelBufferGetBaseAddress(dst) else {
            return nil
        }
        var dstBuffer = vImage_Buffer(
            data: dstData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(dst)
        )

        let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            return nil
        }

        return dst
    }

    // MARK: - 运动强度检测（快速模式自适应切换AI/blend）
    /// 计算相邻帧平均绝对亮度差，返回值范围约 0~255
    /// 阈值建议：<8 静态画面走blend，>=8 有运动走AI
    func estimateMotion(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)
        guard width > 0, height > 0 else { return 255 }

        // 降采样到 64x64 降低计算量
        let smallW = 64
        let smallH = 64

        // iOSurface-backed 的 CVPixelBuffer Lock 可能失败
        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess else {
            return 255
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
        }

        guard let src0 = CVPixelBufferGetBaseAddress(frame0),
              let src1 = CVPixelBufferGetBaseAddress(frame1) else {
            return 255
        }

        let bytesPerRow0 = CVPixelBufferGetBytesPerRow(frame0)
        let bytesPerRow1 = CVPixelBufferGetBytesPerRow(frame1)
        let stepX = max(width / smallW, 1)
        let stepY = max(height / smallH, 1)

        var sum: Int64 = 0
        var count: Int64 = 0

        for y in stride(from: 0, to: height, by: stepY) {
            let row0 = src0.assumingMemoryBound(to: UInt8.self).advanced(by: y * bytesPerRow0)
            let row1 = src1.assumingMemoryBound(to: UInt8.self).advanced(by: y * bytesPerRow1)
            for x in stride(from: 0, to: width, by: stepX) {
                // BGRA 格式，取 B/G/R 三通道平均
                let idx = x * 4
                let b0 = Int(row0[idx]), g0 = Int(row0[idx+1]), r0 = Int(row0[idx+2])
                let b1 = Int(row1[idx]), g1 = Int(row1[idx+1]), r1 = Int(row1[idx+2])
                let lum0 = (r0 * 30 + g0 * 59 + b0 * 11) / 100
                let lum1 = (r1 * 30 + g1 * 59 + b1 * 11) / 100
                sum += Int64(abs(lum0 - lum1))
                count += 1
            }
        }

        guard count > 0 else { return 255 }
        return Float(sum) / Float(count)
    }

    // MARK: - 快速模式：Metal 帧混合（0.5 alpha混合，GPU加速，失败回退CPU）
    func blendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        // 优先使用 Metal GPU 混合
        if let blender = MetalFrameBlender.shared,
           let result = blender.blend(frame0: frame0, frame1: frame1, alpha: 0.5) {
            return result
        }

        // Metal 不可用时回退到 CPU 混合，避免中间帧丢失导致 PTS 空洞
        logger.error("MetalFrameBlender 不可用，回退到 CPU 帧混合")
        return cpuBlendFrames(frame0, frame1)
    }

    // MARK: - CPU 帧混合回退（Metal 不可用时使用）
    func cpuBlendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        var resultBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &resultBuffer) == kCVReturnSuccess,
              let result = resultBuffer else {
            return nil
        }

        // iOSurface-backed 的 CVPixelBuffer Lock 可能失败，GetBaseAddress 返回 NULL
        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }

        guard let src0Ptr = CVPixelBufferGetBaseAddress(frame0),
              let src1Ptr = CVPixelBufferGetBaseAddress(frame1),
              let dstPtr = CVPixelBufferGetBaseAddress(result) else {
            return nil
        }
        let src0 = src0Ptr.assumingMemoryBound(to: UInt8.self)
        let src1 = src1Ptr.assumingMemoryBound(to: UInt8.self)
        let dst = dstPtr.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let totalBytes = bytesPerRow * height

        for i in 0..<totalBytes {
            dst[i] = UInt8((UInt16(src0[i]) + UInt16(src1[i])) / 2)
        }

        return result
    }

    // MARK: - 等待 Writer 就绪（有界背压）
    func waitForWriterReady(_ input: AVAssetWriterInput) {
        var waitCount = 0
        while !input.isReadyForMoreMediaData {
            if isCancelled { return }
            Thread.sleep(forTimeInterval: 0.005)
            waitCount += 1
            if waitCount > 200 { // 超过 1 秒未就绪
                logger.warning("Writer 超过 1 秒未就绪，等待次数: \(waitCount, privacy: .public)")
                break
            }
        }
    }

    // MARK: - 颜色空间附件复制
    /// 将源 PixelBuffer 的颜色空间附件复制到目标 PixelBuffer
    /// 关键：AVAssetReader 读出的原帧带有 BT.709 等颜色空间信息，
    /// 手动创建的补帧缺少这些附件，H.264 编码时 RGB→YUV 转换会用默认 BT.601，
    /// 导致补帧与原帧亮度/颜色不一致
    func copyColorSpaceAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        let colorKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferChromaLocationTopFieldKey
        ]
        for key in colorKeys {
            if let value = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, value, .shouldPropagate)
            }
        }
    }
}

}

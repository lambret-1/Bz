import CoreML
import CoreVideo
import CoreImage          // ← 新增
import Accelerate
import OSLog

private final class ReusableInput: MLFeatureProvider {
    let input: MLMultiArray
    init(input: MLMultiArray) { self.input = input }
    var featureNames: Set<String> { ["input"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == "input" ? MLFeatureValue(multiArray: input) : nil
    }
}

final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2

    let inputWidth: Int = 256
    let inputHeight: Int = 256
    let scaleFactor: Int = 4

    private let tilePad: Int = 16
    private var tileEffIn: Int { inputWidth - 2 * tilePad }
    private var tileEffOut: Int { tileEffIn * scaleFactor }

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let outputArray: MLMultiArray
    private let inputProvider: ReusableInput
    private let predOpts: MLPredictionOptions

    // ← 新增：CIContext 缓存，用于 YUV→BGRA
    private let ciContext: CIContext

    private let tileBuf: CVPixelBuffer
    private let outTileBGRA: CVPixelBuffer
    private let modelOutW: Int
    private let modelOutH: Int

    private let tmpFloat: UnsafeMutablePointer<Float>
    private let tmpU8: UnsafeMutablePointer<UInt8>

    private var outputPool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    private var isCancelledFlag = false
    private let cancelLock = NSLock()

    init?() {
        let tStart = CFAbsoluteTimeGetCurrent()
        logger.info("🚀 开始初始化 RealESRGAN x2 引擎...")

        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGANx2.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("❌ 找不到模型文件")
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error("❌ 模型加载失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let inShape = model.modelDescription.inputDescriptionsByName["input"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              let outShape = model.modelDescription.outputDescriptionsByName["output"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              inShape.count == 4, outShape.count == 4 else {
            logger.error("❌ 模型 IO 不是 4D")
            return nil
        }

        let inN = inShape[0], inC = inShape[1], inH = inShape[2], inW = inShape[3]
        let outN = outShape[0], outC = outShape[1], outH = outShape[2], outW = outShape[3]

        let expectedOutW = inputWidth * scaleFactor
        let expectedOutH = inputHeight * scaleFactor
        guard inN == 1, inW == inputWidth, inH == inputHeight,
              outN == 1, outC == 3, outW == expectedOutW, outH == expectedOutH else {
            logger.error("❌ 模型维度不符: in=\(inShape, privacy: .public) out=\(outShape, privacy: .public)")
            return nil
        }
        self.modelOutW = outW
        self.modelOutH = outH

        guard let inputArray = try? MLMultiArray(shape: inShape.map { NSNumber(value: $0) }, dataType: .float16),
              let outputArray = try? MLMultiArray(shape: outShape.map { NSNumber(value: $0) }, dataType: .float16) else {
            logger.error("❌ MLMultiArray 创建失败")
            return nil
        }
        self.inputArray = inputArray
        self.outputArray = outputArray
        self.inputProvider = ReusableInput(input: inputArray)

        let opts = MLPredictionOptions()
        opts.outputBackings = ["output": outputArray]
        self.predOpts = opts

        guard let tileBuf = Self.makeBGRA(width: inputWidth, height: inputHeight),
              let outTileBGRA = Self.makeBGRA(width: outW, height: outH) else {
            logger.error("❌ 内部 buffer 创建失败")
            return nil
        }
        self.tileBuf = tileBuf
        self.outTileBGRA = outTileBGRA

        // ← 新增
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true,
        ])

        let planeCount = outW * outH
        self.tmpFloat = UnsafeMutablePointer<Float>.allocate(capacity: planeCount * 3)
        self.tmpU8 = UnsafeMutablePointer<UInt8>.allocate(capacity: planeCount * 3)

        let elapsed = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        logger.info("✅ 初始化成功 \(elapsed, privacy: .public)ms, in=\(inC, privacy: .public)ch")
    }

    deinit {
        tmpFloat.deallocate()
        tmpU8.deallocate()
    }

    // MARK: - 公共接口（← 关键改动：入口统一转 BGRA）

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        cancelLock.lock(); isCancelledFlag = false; cancelLock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        // 诊断 + 转换
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        logger.info("🔍 upscale \(srcW, privacy: .public)x\(srcH, privacy: .public) fmt=\(fmt, privacy: .public) planar=\(isPlanar, privacy: .public)")

        let bgraInput: CVPixelBuffer
        if fmt == kCVPixelFormatType_32BGRA && !isPlanar {
            bgraInput = pixelBuffer
        } else {
            let tConv = CFAbsoluteTimeGetCurrent()
            guard let converted = convertToBGRA(pixelBuffer, width: srcW, height: srcH) else {
                logger.error("❌ 转 BGRA 失败")
                return nil
            }
            let ms = (CFAbsoluteTimeGetCurrent() - tConv) * 1000
            logger.info("✅ 转 BGRA 完成 \(ms, privacy: .public)ms")
            bgraInput = converted
        }

        if srcW <= inputWidth && srcH <= inputHeight {
            return upscaleSingleTile(bgraInput)
        }
        return upscaleTiled(bgraInput)
    }

    func cancel() {
        cancelLock.lock(); isCancelledFlag = true; cancelLock.unlock()
    }

    // ← 新增：任意格式 → BGRA
    private func convertToBGRA(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard let dst = Self.makeBGRA(width: width, height: height) else { return nil }

        // 确保 dst 可用 CPU 访问
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ciContext.render(ci, to: dst, bounds: rect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return dst
    }

    // 以下函数与你之前贴的完全一致，无需改动
    private func upscaleSingleTile(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else {
            logger.error("❌ 输出 buffer 失败")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        CVPixelBufferLockBaseAddress(tileBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
            CVPixelBufferUnlockBaseAddress(tileBuf, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let tileBase = CVPixelBufferGetBaseAddress(tileBuf) else {
            logger.error("❌ 单 Tile base address 失败")
            return nil
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tileRowBytes = CVPixelBufferGetBytesPerRow(tileBuf)
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let tilePtr = tileBase.assumingMemoryBound(to: UInt8.self)

        guard extractReflectTile(srcPtr: srcPtr, srcRowBytes: srcRowBytes, srcW: srcW, srcH: srcH,
                                 dstPtr: tilePtr, dstRowBytes: tileRowBytes,
                                 x: 0, y: 0, w: inputWidth, h: inputHeight) else {
            logger.error("❌ 单 Tile 裁剪失败")
            return nil
        }

        guard bgraToTensor(tileBuf) else { return nil }

        let tPred = CFAbsoluteTimeGetCurrent()
        do { _ = try model.prediction(from: inputProvider, options: predOpts) }
        catch {
            logger.error("❌ 推理失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let predMs = (CFAbsoluteTimeGetCurrent() - tPred) * 1000

        let copyW = min(outW, inputWidth * scaleFactor)
        let copyH = min(outH, inputHeight * scaleFactor)
        _ = writeTileBack(to: outBuffer, srcX: 0, srcY: 0, dstX: 0, dstY: 0, w: copyW, h: copyH)

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)

        let total = (CFAbsoluteTimeGetCurrent() - tFrameStart) * 1000
        logger.info("✅ 单Tile \(srcW, privacy: .public)x\(srcH, privacy: .public)→\(outW, privacy: .public)x\(outH, privacy: .public) 推理 \(predMs, privacy: .public)ms 总 \(total, privacy: .public)ms")
        return outBuffer
    }

    private func upscaleTiled(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else { return nil }

        let effIn = tileEffIn, effOut = tileEffOut, pad = tilePad
        let cols = max(1, (srcW + effIn - 1) / effIn)
        let rows = max(1, (srcH + effIn - 1) / effIn)
        logger.info("🎬 Tile 网格 \(cols, privacy: .public)x\(rows, privacy: .public)")

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        CVPixelBufferLockBaseAddress(tileBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
            CVPixelBufferUnlockBaseAddress(tileBuf, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let tileBase = CVPixelBufferGetBaseAddress(tileBuf) else {
            logger.error("❌ Tiled base address 失败")
            return nil
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tileRowBytes = CVPixelBufferGetBytesPerRow(tileBuf)
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let tilePtr = tileBase.assumingMemoryBound(to: UInt8.self)

        for ty in 0..<rows {
            for tx in 0..<cols {
                cancelLock.lock(); let c = isCancelledFlag; cancelLock.unlock()
                if c { return nil }

                let srcX = tx * effIn - pad
                let srcY = ty * effIn - pad

                guard extractReflectTile(srcPtr: srcPtr, srcRowBytes: srcRowBytes, srcW: srcW, srcH: srcH,
                                         dstPtr: tilePtr, dstRowBytes: tileRowBytes,
                                         x: srcX, y: srcY, w: inputWidth, h: inputHeight) else { continue }
                guard bgraToTensor(tileBuf) else { continue }

                let tPred = CFAbsoluteTimeGetCurrent()
                do { _ = try model.prediction(from: inputProvider, options: predOpts) }
                catch {
                    logger.error("❌ Tile[\(tx, privacy: .public),\(ty, privacy: .public)] 推理失败: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                let predMs = (CFAbsoluteTimeGetCurrent() - tPred) * 1000

                let dstX = tx * effOut, dstY = ty * effOut
                let copyW = min(effOut, outW - dstX)
                let copyH = min(effOut, outH - dstY)
                guard copyW > 0, copyH > 0 else { continue }
                _ = writeTileBack(to: outBuffer, srcX: pad * scaleFactor, srcY: pad * scaleFactor,
                                  dstX: dstX, dstY: dstY, w: copyW, h: copyH)

                logger.info("🧩 Tile[\(tx, privacy: .public),\(ty, privacy: .public)] 推理 \(predMs, privacy: .public)ms")
            }
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)
        let total = (CFAbsoluteTimeGetCurrent() - tFrameStart) * 1000
        logger.info("✅ Tiled 完成 \(total, privacy: .public)ms")
        return outBuffer
    }

    // 以下与之前完全一致
    private func extractReflectTile(srcPtr: UnsafeMutablePointer<UInt8>, srcRowBytes: Int,
                                    srcW: Int, srcH: Int,
                                    dstPtr: UnsafeMutablePointer<UInt8>, dstRowBytes: Int,
                                    x: Int, y: Int, w: Int, h: Int) -> Bool {
        if x >= 0 && y >= 0 && x + w <= srcW && y + h <= srcH {
            for row in 0..<h {
                memcpy(dstPtr.advanced(by: row * dstRowBytes),
                       srcPtr.advanced(by: (y + row) * srcRowBytes + x * 4), w * 4)
            }
            return true
        }
        let leftEnd = min(w, max(0, -x))
        let rightStart = min(w, max(leftEnd, srcW - x))
        for ty in 0..<h {
            let sy = Self.reflect(y + ty, srcH)
            let srcRow = srcPtr.advanced(by: sy * srcRowBytes)
            let dstRow = dstPtr.advanced(by: ty * dstRowBytes)
            var tx = 0
            while tx < leftEnd {
                let sx = Self.reflect(x + tx, srcW)
                let s = srcRow.advanced(by: sx * 4)
                let d = dstRow.advanced(by: tx * 4)
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                tx += 1
            }
            if rightStart > leftEnd {
                memcpy(dstRow.advanced(by: leftEnd * 4),
                       srcRow.advanced(by: (x + leftEnd) * 4),
                       (rightStart - leftEnd) * 4)
                tx = rightStart
            }
            while tx < w {
                let sx = Self.reflect(x + tx, srcW)
                let s = srcRow.advanced(by: sx * 4)
                let d = dstRow.advanced(by: tx * 4)
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                tx += 1
            }
        }
        return true
    }

    @inline(__always)
    private static func reflect(_ v: Int, _ n: Int) -> Int {
        if n <= 1 { return 0 }
        let period = 2 * (n - 1)
        var m = v % period
        if m < 0 { m += period }
        return m < n ? m : period - m
    }

    private func bgraToTensor(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let w = inputWidth, h = inputHeight
        let planeCount = w * h
        let channels = inputArray.shape[1].intValue

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: planeCount * 3) { u8Buf in
            let r8 = u8Buf.baseAddress!
            let g8 = r8.advanced(by: planeCount)
            let b8 = g8.advanced(by: planeCount)

            var r8b = vImage_Buffer(data: r8, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var g8b = vImage_Buffer(data: g8, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var b8b = vImage_Buffer(data: b8, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)

            guard vImageConvert_BGRX8888ToPlanar8(&src, &b8b, &g8b, &r8b, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return false
            }

            return withUnsafeTemporaryAllocation(of: Float.self, capacity: planeCount * 3) { fBuf in
                let rF = fBuf.baseAddress!
                let gF = rF.advanced(by: planeCount)
                let bF = gF.advanced(by: planeCount)

                var rFb = vImage_Buffer(data: rF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var gFb = vImage_Buffer(data: gF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var bFb = vImage_Buffer(data: bF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)

                vImageConvert_Planar8toPlanarF(&r8b, &rFb, 1.0 / 255.0, 0.0, vImage_Flags(kvImageNoFlags))
                vImageConvert_Planar8toPlanarF(&g8b, &gFb, 1.0 / 255.0, 0.0, vImage_Flags(kvImageNoFlags))
                vImageConvert_Planar8toPlanarF(&b8b, &bFb, 1.0 / 255.0, 0.0, vImage_Flags(kvImageNoFlags))

                let dst = inputArray.dataPointer.assumingMemoryBound(to: Float16.self)
                var rF16 = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                var gF16 = vImage_Buffer(data: dst.advanced(by: planeCount), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                var bF16 = vImage_Buffer(data: dst.advanced(by: 2 * planeCount), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)

                vImageConvert_PlanarFtoPlanar16F(&rFb, &rF16, vImage_Flags(kvImageNoFlags))
                vImageConvert_PlanarFtoPlanar16F(&gFb, &gF16, vImage_Flags(kvImageNoFlags))
                vImageConvert_PlanarFtoPlanar16F(&bFb, &bF16, vImage_Flags(kvImageNoFlags))

                if channels == 12 {
                    let planeBytes = planeCount * MemoryLayout<Float16>.size
                    for frame in 1..<4 {
                        let b = frame * 3 * planeCount
                        memcpy(dst.advanced(by: b), dst, planeBytes)
                        memcpy(dst.advanced(by: b + planeCount), dst.advanced(by: planeCount), planeBytes)
                        memcpy(dst.advanced(by: b + 2 * planeCount), dst.advanced(by: 2 * planeCount), planeBytes)
                    }
                }
                return true
            }
        }
    }

    private func float16PlanarToBGRA(_ array: MLMultiArray, into buffer: CVPixelBuffer) -> Bool {
        let width = modelOutW, height = modelOutH
        let planeCount = width * height

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        let src = array.dataPointer.assumingMemoryBound(to: Float16.self)

        let rF = tmpFloat, gF = rF.advanced(by: planeCount), bF = gF.advanced(by: planeCount)
        let r8 = tmpU8, g8 = r8.advanced(by: planeCount), b8 = g8.advanced(by: planeCount)

        var r16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
        var g16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
        var b16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: 2 * planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)

        var rFb = vImage_Buffer(data: rF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var gFb = vImage_Buffer(data: gF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var bFb = vImage_Buffer(data: bF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)

        vImageConvert_Planar16FtoPlanarF(&r16, &rFb, vImage_Flags(kvImageNoFlags))
        vImageConvert_Planar16FtoPlanarF(&g16, &gFb, vImage_Flags(kvImageNoFlags))
        vImageConvert_Planar16FtoPlanarF(&b16, &bFb, vImage_Flags(kvImageNoFlags))

        var r8b = vImage_Buffer(data: r8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var g8b = vImage_Buffer(data: g8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var b8b = vImage_Buffer(data: b8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)

        vImageConvert_PlanarFtoPlanar8(&rFb, &r8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&gFb, &g8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&bFb, &b8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))

        var dstBuf = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        return vImageConvert_Planar8ToBGRX8888(&b8b, &g8b, &r8b, 255, &dstBuf, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }

    private func writeTileBack(to outBuffer: CVPixelBuffer, srcX: Int, srcY: Int, dstX: Int, dstY: Int, w: Int, h: Int) -> Bool {
        guard float16PlanarToBGRA(outputArray, into: outTileBGRA) else { return false }
        CVPixelBufferLockBaseAddress(outTileBGRA, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outTileBGRA, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(outTileBGRA),
              let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else { return false }
        let srcRB = CVPixelBufferGetBytesPerRow(outTileBGRA)
        let dstRB = CVPixelBufferGetBytesPerRow(outBuffer)
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            memcpy(dstPtr.advanced(by: (dstY + row) * dstRB + dstX * 4),
                   srcPtr.advanced(by: (srcY + row) * srcRB + srcX * 4), w * 4)
        }
        return true
    }

    // ← 去掉 IOSurface（内部 CPU buffer 不需要）
    private static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buf) == kCVReturnSuccess else { return nil }
        return buf
    }

    // 输出 pool 保留 IOSurface（下游可能 GPU 渲染）
    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if outputPool == nil || poolW != width || poolH != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferCGImageCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                          attrs as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            outputPool = pool
            poolW = width
            poolH = height
            logger.info("📦 输出 Pool \(width, privacy: .public)x\(height, privacy: .public)")
        }
        guard let pool = outputPool else { return nil }
        var buf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        return buf
    }

    private func copyColorSpaceAttachments(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        let keys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferChromaLocationTopFieldKey
        ]
        for key in keys {
            if let v = CVBufferGetAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, v.takeUnretainedValue(), .shouldPropagate)
            }
        }
    }
}

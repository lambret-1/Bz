import CoreML
import CoreVideo
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

    // 从模型描述自动推断，不再硬编码
    let inputWidth: Int
    let inputHeight: Int
    let scaleFactor: Int

    private let tilePad: Int = 16
    private var tileEffIn: Int { inputWidth - 2 * tilePad }
    private var tileEffOut: Int { tileEffIn * scaleFactor }

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let inputProvider: ReusableInput
    private let outputKey: String

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
        logger.info("🚀 初始化 RealESRGAN 引擎...")

        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGANx2.modelFileName,
            withExtension: "mlmodelc"
        ) else {
            logger.error("❌ 找不到模型: \(SuperResolutionEngineType.realESRGANx2.modelFileName).mlmodelc")
            return nil
        }
        logger.info("📂 模型路径: \(modelURL.path)")

        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error("❌ 模型加载失败: \(error)")
            return nil
        }

        // ===== 打印完整模型描述，第一行就能看出模型对不对 =====
        let desc = model.modelDescription
        logger.info("📋 输入 keys: \(desc.inputDescriptionsByName.keys.sorted())")
        logger.info("📋 输出 keys: \(desc.outputDescriptionsByName.keys.sorted())")
        for (name, d) in desc.inputDescriptionsByName {
            if let c = d.multiArrayConstraint {
                logger.info("  ⬅️ input[\(name)] shape=\(c.shape) dtype=\(c.dataType.rawValue)")
            } else {
                logger.info("  ⬅️ input[\(name)] 非 multiArray: \(d.type)")
            }
        }
        for (name, d) in desc.outputDescriptionsByName {
            if let c = d.multiArrayConstraint {
                logger.info("  ➡️ output[\(name)] shape=\(c.shape) dtype=\(c.dataType.rawValue)")
            } else {
                logger.info("  ➡️ output[\(name)] 非 multiArray: \(d.type)")
            }
        }

        guard let inDesc = desc.inputDescriptionsByName["input"]?.multiArrayConstraint,
              let outEntry = desc.outputDescriptionsByName.first(where: { $0.value.multiArrayConstraint != nil }) else {
            logger.error("❌ 模型缺少 input 或 output multiArray")
            return nil
        }
        let outName = outEntry.key
        let outDesc = outEntry.value.multiArrayConstraint!

        let inShape = inDesc.shape.map { $0.intValue }
        let outShape = outDesc.shape.map { $0.intValue }
        guard inShape.count == 4, outShape.count == 4 else {
            logger.error("❌ 模型 IO 不是 4D: in=\(inShape), out=\(outShape)")
            return nil
        }

        let inC = inShape[1], inH = inShape[2], inW = inShape[3]
        let outC = outShape[1], outH = outShape[2], outW = outShape[3]

        guard outW % inW == 0, outH % inH == 0, outW / inW == outH / inH else {
            logger.error("❌ 输出不是输入整数倍: in=\(inShape), out=\(outShape)")
            return nil
        }
        let inferredScale = outW / inW
        logger.info("✅ 推断: scale=\(inferredScale)x, inC=\(inC), outC=\(outC), outKey=\(outName)")

        self.inputWidth = inW
        self.inputHeight = inH
        self.scaleFactor = inferredScale
        self.modelOutW = outW
        self.modelOutH = outH
        self.outputKey = outName

        guard let inputArray = try? MLMultiArray(
            shape: inShape.map { NSNumber(value: $0) },
            dataType: inDesc.dataType
        ) else {
            logger.error("❌ inputArray 创建失败")
            return nil
        }
        self.inputArray = inputArray
        self.inputProvider = ReusableInput(input: inputArray)

        guard let tileBuf = Self.makeBGRA(width: inW, height: inH),
              let outTileBGRA = Self.makeBGRA(width: outW, height: outH) else {
            logger.error("❌ 中间 buffer 创建失败")
            return nil
        }
        self.tileBuf = tileBuf
        self.outTileBGRA = outTileBGRA

        let planeCount = outW * outH
        self.tmpFloat = .allocate(capacity: planeCount * 3)
        self.tmpU8 = .allocate(capacity: planeCount * 3)

        let elapsed = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        logger.info("✅ 初始化完成 \(elapsed, format: .fixed(precision: 2))ms")
    }

    deinit {
        tmpFloat.deallocate()
        tmpU8.deallocate()
    }

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        cancelLock.lock(); isCancelledFlag = false; cancelLock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        if srcW <= inputWidth && srcH <= inputHeight {
            return upscaleSingleTile(pixelBuffer)
        }
        return upscaleTiled(pixelBuffer)
    }

    func cancel() {
        cancelLock.lock(); isCancelledFlag = true; cancelLock.unlock()
    }

    // MARK: - 单 Tile

    private func upscaleSingleTile(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tStart = CFAbsoluteTimeGetCurrent()
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else {
            logger.error("❌ 输出 buffer 申请失败 \(outW)x\(outH)")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        CVPixelBufferLockBaseAddress(tileBuf, [])   // 关键修复
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
            CVPixelBufferUnlockBaseAddress(tileBuf, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let tileBase = CVPixelBufferGetBaseAddress(tileBuf) else {
            logger.error("❌ 获取 base address 失败")
            return nil
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tileRowBytes = CVPixelBufferGetBytesPerRow(tileBuf)

        guard extractReflectTile(
            srcPtr: srcBase.assumingMemoryBound(to: UInt8.self),
            srcRowBytes: srcRowBytes, srcW: srcW, srcH: srcH,
            dstPtr: tileBase.assumingMemoryBound(to: UInt8.self),
            dstRowBytes: tileRowBytes,
            x: 0, y: 0, w: inputWidth, h: inputHeight
        ) else {
            logger.error("❌ 反射裁剪失败")
            return nil
        }

        guard bgraToTensor(tileBuf) else {
            logger.error("❌ BGRA→Tensor 失败")
            return nil
        }

        let tPred = CFAbsoluteTimeGetCurrent()
        let prediction: MLPrediction
        do {
            prediction = try model.prediction(from: inputProvider)
        } catch {
            logger.error("❌ 推理失败: \(error.localizedDescription)")
            return nil
        }
        let predMs = (CFAbsoluteTimeGetCurrent() - tPred) * 1000

        guard let outArray = prediction.featureValue(for: outputKey)?.multiArrayValue else {
            logger.error("❌ 输出不是 MLMultiArray，keys=\(prediction.featureNames)")
            return nil
        }

        let copyW = min(outW, inputWidth * scaleFactor)
        let copyH = min(outH, inputHeight * scaleFactor)
        guard writeTileBack(outArray: outArray, to: outBuffer,
                            srcX: 0, srcY: 0, dstX: 0, dstY: 0,
                            w: copyW, h: copyH) else {
            logger.error("❌ 写回失败")
            return nil
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)

        let total = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        logger.debug("✅ \(srcW)x\(srcH)→\(outW)x\(outH) 推理 \(predMs, format: .fixed(precision: 2))ms 总 \(Buffertotal, format: .fixed(precision: 2))ms")
?        return outBuffer
    }

    // {
 MARK: - 多 Tile

           private func upscaleTiled(_ pixelBuffer let: CVPixelBuffer) -> CVPixel srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else { return nil }

        let effIn = tileEffIn, effOut = tileEffOut, pad = tilePad
        let cols = max(1, (srcW + effIn - 1) / effIn)
        let rows = max(1, (srcH + effIn - 1) / effIn)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        CVPixelBufferLockBaseAddress(tileBuf, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
            CVPixelBufferUnlockBaseAddress(tileBuf, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let tileBase = CVPixelBufferGetBaseAddress(tileBuf) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tileRowBytes = CVPixelBufferGetBytesPerRow(tileBuf)

        for ty in 0..<rows {
            for tx in 0..<cols {
                cancelLock.lock(); let c = isCancelledFlag; cancelLock.unlock()
                if c { return nil }

                let srcX = tx * effIn - pad
                let srcY = ty * effIn - pad

                guard extractReflectTile(
                    srcPtr: srcBase.assumingMemoryBound(to: UInt8.self),
                    srcRowBytes: srcRowBytes, srcW: srcW, srcH: srcH,
                    dstPtr: tileBase.assumingMemoryBound(to: UInt8.self),
                    dstRowBytes: tileRowBytes,
                    x: srcX, y: srcY, w: inputWidth, h: inputHeight
                ) else { continue }

                guard bgraToTensor(tileBuf) else { continue }

                let prediction: MLPrediction
                do { prediction = try model.prediction(from: inputProvider) }
                catch {
                    logger.error("❌ Tile[\(tx),\(ty)] 推理失败: \(error.localizedDescription)")
                    continue
                }
                guard let outArray = prediction.featureValue(for: outputKey)?.multiArrayValue else { continue }

                let dstX = tx * effOut, dstY = ty * effOut
                let copyW = min(effOut, outW - dstX)
                let copyH = min(effOut, outH - dstY)
                guard copyW > 0, copyH > 0 else { continue }

                _ = writeTileBack(outArray: outArray, to: outBuffer,
                                  srcX: pad * scaleFactor, srcY: pad * scaleFactor,
                                  dstX: dstX, dstY: dstY, w: copyW, h: copyH)
            }
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)
        return outBuffer
    }

    // MARK: - BGRA → MLMultiArray

    private func bgraToTensor(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let w = inputWidth, h = inputHeight
        let planeCount = w * h
        let channels = inputArray.shape[1].intValue
        let isFP16 = (inputArray.dataType == .float16)

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
                logger.error("❌ BGRX→Planar8 失败")
                return false
            }

            return withUnsafeTemporaryAllocation(of: Float.self, capacity: planeCount * 3) { fBuf in
                let rF = fBuf.baseAddress!
                let gF = rF.advanced(by: planeCount)
                let bF = gF.advanced(by: planeCount)

                var rFb = vImage_Buffer(data: rF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var gFb = vImage_Buffer(data: gF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var bFb = vImage_Buffer(data: bF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)

                vImageConvert_Planar8toPlanarF(&r8b, &rFb, 1.0/255.0, 0.0, vImage_Flags(kvImageNoFlags))
                vImageConvert_Planar8toPlanarF(&g8b, &gFb, 1.0/255.0, 0.0, vImage_Flags(kvImageNoFlags))
                vImageConvert_Planar8toPlanarF(&b8b, &bFb, 1.0/255.0, 0.0, vImage_Flags(kvImageNoFlags))

                if isFP16 {
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
                } else {
                    let dst = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
                    let bytes = planeCount * MemoryLayout<Float>.size
                    memcpy(dst, rF, bytes)
                    memcpy(dst.advanced(by: planeCount), gF, bytes)
                    memcpy(dst.advanced(by: 2 * planeCount), bF, bytes)
                    if channels == 12 {
                        for frame in 1..<4 {
                            let b = frame * 3 * planeCount
                            memcpy(dst.advanced(by: b), dst, bytes)
                            memcpy(dst.advanced(by: b + planeCount), dst.advanced(by: planeCount), bytes)
                            memcpy(dst.advanced(by: b + 2 * planeCount), dst.advanced(by: 2 * planeCount), bytes)
                        }
                    }
                }
                return true
            }
        }
    }

    // MARK: - MLMultiArray → BGRA 写回

    private func writeTileBack(outArray: MLMultiArray, to outBuffer: CVPixelBuffer,
                               srcX: Int, srcY: Int, dstX: Int, dstY: Int,
                               w: Int, h: Int) -> Bool {
        guard multiArrayToBGRA(outArray, into: outTileBGRA) else { return false }

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
                   srcPtr.advanced(by: (srcY + row) * srcRB + srcX * 4),
                   w * 4)
        }
        return true
    }

    private func multiArrayToBGRA(_ array: MLMultiArray, into buffer: CVPixelBuffer) -> Bool {
        let width = modelOutW, height = modelOutH
        let planeCount = width * height

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        let src = array.dataPointer
        let isFP16 = (array.dataType == .float16)

        let rF = tmpFloat, gF = rF.advanced(by: planeCount), bF = gF.advanced(by: planeCount)
        let r8 = tmpU8,    g8 = r8.advanced(by: planeCount),    b8 = g8.advanced(by: planeCount)

        var rFb = vImage_Buffer(data: rF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var gFb = vImage_Buffer(data: gF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var bFb = vImage_Buffer(data: bF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)

        if isFP16 {
            let s16 = src.assumingMemoryBound(to: Float16.self)
            var r16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s16), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
            var g16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s16.advanced(by: planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
            var b16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s16.advanced(by: 2 * planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
            vImageConvert_Planar16FtoPlanarF(&r16, &rFb, vImage_Flags(kvImageNoFlags))
            vImageConvert_Planar16FtoPlanarF(&g16, &gFb, vImage_Flags(kvImageNoFlags))
            vImageConvert_Planar16FtoPlanarF(&b16, &bFb, vImage_Flags(kvImageNoFlags))
        } else {
            let s32 = src.assumingMemoryBound(to: Float.self)
            rFb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s32), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            gFb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s32.advanced(by: planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            bFb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s32.advanced(by: 2 * planeCount)), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        }

        var r8b = vImage_Buffer(data: r8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var g8b = vImage_Buffer(data: g8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var b8b = vImage_Buffer(data: b8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)

        vImageConvert_PlanarFtoPlanar8(&rFb, &r8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&gFb, &g8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&bFb, &b8b, 255.0, 0.0, vImage_Flags(kvImageNoFlags))

        var dstBuf = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let err = vImageConvert_Planar8ToBGRX8888(&b8b, &g8b, &r8b, 255, &dstBuf, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError {
            logger.error("❌ Planar8→BGRX 失败: \(err)")
            return false
        }
        return true
    }

    // MARK: - 反射裁剪

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

    // MARK: - Buffers

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

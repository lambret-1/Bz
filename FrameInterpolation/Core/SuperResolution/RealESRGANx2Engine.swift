import CoreML
import CoreVideo
import Accelerate
import OSLog

// MARK: - 复用 Input Provider
private final class ReusableInput: MLFeatureProvider {
    let input: MLMultiArray
    init(input: MLMultiArray) { self.input = input }
    var featureNames: Set<String> { ["input"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == "input" ? MLFeatureValue(multiArray: input) : nil
    }
}

// MARK: - RealESRGAN 4x 引擎（256 输入 -> 1024 输出）
final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2

    // 模型固定输入
    let inputWidth: Int = 256
    let inputHeight: Int = 256
    // 模型实际 4x（输出 1024 = 256 × 4）
    let scaleFactor: Int = 4

    // 多 Tile 路径参数（仅大图使用）
    private let tilePad: Int = 16
    private var tileEffIn: Int { inputWidth - 2 * tilePad }   // 224
    private var tileEffOut: Int { tileEffIn * scaleFactor }   // 896

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let outputArray: MLMultiArray
    private let inputProvider: ReusableInput
    private let predOpts: MLPredictionOptions

    // 复用的中间 buffer
    private let tileBuf: CVPixelBuffer        // 256x256 BGRA 输入 tile
    private let outTileBGRA: CVPixelBuffer    // 1024x1024 BGRA 输出 tile
    private let modelOutW: Int
    private let modelOutH: Int

    // 预分配后处理临时 buffer，避免每 tile 分配 15MB
    private let tmpFloat: UnsafeMutablePointer<Float>
    private let tmpU8: UnsafeMutablePointer<UInt8>

    // 最终输出 pool
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
            logger.error("❌ 找不到模型文件: \(SuperResolutionEngineType.realESRGANx2.modelFileName).mlmodelc")
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error("❌ 模型加载失败: \(error)")
            return nil
        }

        guard let inShape = model.modelDescription.inputDescriptionsByName["input"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              let outShape = model.modelDescription.outputDescriptionsByName["output"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              inShape.count == 4, outShape.count == 4 else {
            logger.error("❌ 模型输入/输出格式不是 4D Tensor")
            return nil
        }

        logger.info("📐 模型实际 IO: in=\(inShape), out=\(outShape)")

        let inN = inShape[0], inC = inShape[1], inH = inShape[2], inW = inShape[3]
        let outN = outShape[0], outC = outShape[1], outH = outShape[2], outW = outShape[3]

        // 用局部变量避免闭包内 self 捕获检查
        let expectedInW = inputWidth
        let expectedInH = inputHeight
        let expectedOutW = inputWidth * scaleFactor
        let expectedOutH = inputHeight * scaleFactor

        guard inN == 1, inW == expectedInW, inH == expectedInH,
              outN == 1, outC == 3,
              outW == expectedOutW, outH == expectedOutH else {
            logger.error("❌ 模型维度不符！期望: [1,\(inC),\(expectedInH),\(expectedInW)] -> [1,3,\(expectedOutH),\(expectedOutW)]；实际: \(inShape) -> \(outShape)")
            return nil
        }
        self.modelOutW = outW
        self.modelOutH = outH

        guard let inputArray = try? MLMultiArray(shape: inShape.map { NSNumber(value: $0) }, dataType: .float16),
              let outputArray = try? MLMultiArray(shape: outShape.map { NSNumber(value: $0) }, dataType: .float16) else {
            logger.error("❌ MLMultiArray 创建失败 (可能内存不足)")
            return nil
        }
        self.inputArray = inputArray
        self.outputArray = outputArray
        self.inputProvider = ReusableInput(input: inputArray)

        let opts = MLPredictionOptions()
        opts.outputBackings = ["output": outputArray]
        self.predOpts = opts

        guard let tileBuf = Self.makeBGRA(width: expectedInW, height: expectedInH),
              let outTileBGRA = Self.makeBGRA(width: outW, height: outH) else {
            logger.error("❌ 复用 Tile Buffer 创建失败")
            return nil
        }
        self.tileBuf = tileBuf
        self.outTileBGRA = outTileBGRA

        // 预分配后处理临时 buffer（放在所有 guard 之后，deinit 语义安全）
        let planeCount = outW * outH
        self.tmpFloat = UnsafeMutablePointer<Float>.allocate(capacity: planeCount * 3)
        self.tmpU8 = UnsafeMutablePointer<UInt8>.allocate(capacity: planeCount * 3)

        let elapsed = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        logger.info("✅ 引擎初始化成功！耗时: \(elapsed, format: .fixed(precision: 2))ms。输入: \(inW)x\(inH) 通道:\(inC)，输出: \(outW)x\(outH)，scale=\(self.scaleFactor)x")
    }

    deinit {
        tmpFloat.deallocate()
        tmpU8.deallocate()
        logger.info("♻️ RealESRGANx2Engine deinit")
    }

    // MARK: - 公共接口

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        cancelLock.lock(); isCancelledFlag = false; cancelLock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        // 源 ≤ 模型输入时走单 tile 快速路径
        if srcW <= inputWidth && srcH <= inputHeight {
            return upscaleSingleTile(pixelBuffer)
        }
        return upscaleTiled(pixelBuffer)
    }

    func cancel() {
        cancelLock.lock(); isCancelledFlag = true; cancelLock.unlock()
        logger.info("⚠️ 触发 cancel() 信号")
    }

    // MARK: - 单 Tile 快速路径（源 ≤ 256，pad=0，一次推理直出）

    private func upscaleSingleTile(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else {
            logger.error("❌ 申请输出 Buffer 失败: \(outW)x\(outH)")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
        }

        guard extractReflectTile(from: pixelBuffer, into: tileBuf,
                                 x: 0, y: 0, w: inputWidth, h: inputHeight) else {
            logger.error("❌ 单 Tile 反射裁剪失败")
            return nil
        }

        let tConvertStart = CFAbsoluteTimeGetCurrent()
        guard bgraToTensor(tileBuf) else {
            logger.error("❌ 单 Tile 格式转换失败")
            return nil
        }
        let tConvertCost = (CFAbsoluteTimeGetCurrent() - tConvertStart) * 1000

        let tPredictStart = CFAbsoluteTimeGetCurrent()
        guard (try? model.prediction(from: inputProvider, options: predOpts)) != nil else {
            logger.error("❌ 单 Tile 模型推理失败")
            return nil
        }
        let tPredictCost = (CFAbsoluteTimeGetCurrent() - tPredictStart) * 1000

        let copyW = min(outW, inputWidth * scaleFactor)
        let copyH = min(outH, inputHeight * scaleFactor)
        let tWriteStart = CFAbsoluteTimeGetCurrent()
        _ = writeTileBack(to: outBuffer,
                          srcX: 0, srcY: 0,
                          dstX: 0, dstY: 0,
                          w: copyW, h: copyH)
        let tWriteCost = (CFAbsoluteTimeGetCurrent() - tWriteStart) * 1000

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)

        let totalCost = (CFAbsoluteTimeGetCurrent() - tFrameStart) * 1000
        logger.debug("✅ 单 Tile 完成！源 \(srcW)x\(srcH) -> \(outW)x\(outH)，转换 \(tConvertCost, format: .fixed(precision: 2))ms，推理 \(tPredictCost, format: .fixed(precision: 2))ms，写回 \(tWriteCost, format: .fixed(precision: 2))ms，总 \(totalCost, format: .fixed(precision: 2))ms")
        return outBuffer
    }

    // MARK: - 多 Tile 路径（大图）

    private func upscaleTiled(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor

        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else {
            logger.error("❌ 申请输出 Buffer 失败: \(outW)x\(outH)")
            return nil
        }

        let effIn = tileEffIn      // 224
        let effOut = tileEffOut    // 896
        let pad = tilePad          // 16

        let cols = max(1, (srcW + effIn - 1) / effIn)
        let rows = max(1, (srcH + effIn - 1) / effIn)
        let totalTiles = cols * rows

        logger.debug("🎬 开始处理帧: 源图 \(srcW)x\(srcH) -> 目标 \(outW)x\(outH), Tile网格: \(cols)x\(rows) (共 \(totalTiles) 块)")

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
        }

        for ty in 0..<rows {
            for tx in 0..<cols {
                cancelLock.lock(); let cancelled = isCancelledFlag; cancelLock.unlock()
                if cancelled {
                    logger.debug("🛑 收到取消信号，中断当前帧 Tile 循环 (已完成 \(ty * cols + tx) / \(totalTiles) 块)")
                    return nil
                }

                let tTileStart = CFAbsoluteTimeGetCurrent()
                let srcX = tx * effIn - pad
                let srcY = ty * effIn - pad

                guard extractReflectTile(from: pixelBuffer, into: tileBuf,
                                         x: srcX, y: srcY,
                                         w: inputWidth, h: inputHeight) else {
                    logger.error("❌ Tile[\(tx),\(ty)] 反射裁剪失败")
                    continue
                }

                let tConvertStart = CFAbsoluteTimeGetCurrent()
                guard bgraToTensor(tileBuf) else {
                    logger.error("❌ Tile[\(tx),\(ty)] 格式转换失败")
                    continue
                }
                let tConvertCost = (CFAbsoluteTimeGetCurrent() - tConvertStart) * 1000

                let tPredictStart = CFAbsoluteTimeGetCurrent()
                guard (try? model.prediction(from: inputProvider, options: predOpts)) != nil else {
                    logger.error("❌ Tile[\(tx),\(ty)] 模型推理失败")
                    continue
                }
                let tPredictCost = (CFAbsoluteTimeGetCurrent() - tPredictStart) * 1000

                let dstX = tx * effOut
                let dstY = ty * effOut
                let copyW = min(effOut, outW - dstX)
                let copyH = min(effOut, outH - dstY)
                guard copyW > 0, copyH > 0 else { continue }

                let tWriteStart = CFAbsoluteTimeGetCurrent()
                _ = writeTileBack(to: outBuffer,
                                  srcX: pad * scaleFactor, srcY: pad * scaleFactor,
                                  dstX: dstX, dstY: dstY,
                                  w: copyW, h: copyH)
                let tWriteCost = (CFAbsoluteTimeGetCurrent() - tWriteStart) * 1000

                let tileCost = (CFAbsoluteTimeGetCurrent() - tTileStart) * 1000
                logger.debug("  🧩 Tile[\(tx),\(ty)] 耗时: \(tileCost, format: .fixed(precision: 2))ms (转换: \(tConvertCost, format: .fixed(precision: 2))ms, 推理: \(tPredictCost, format: .fixed(precision: 2))ms, 写回: \(tWriteCost, format: .fixed(precision: 2))ms)")
            }
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)

        let totalCost = (CFAbsoluteTimeGetCurrent() - tFrameStart) * 1000
        logger.debug("✅ 帧处理完成！总耗时: \(totalCost, format: .fixed(precision: 2))ms")
        return outBuffer
    }

    // MARK: - Tile 提取（反射 padding）
    private func extractReflectTile(from src: CVPixelBuffer,
                                    into dst: CVPixelBuffer,
                                    x: Int, y: Int, w: Int, h: Int) -> Bool {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dst)
        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return false }
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        let leftEnd    = min(w, max(0, -x))
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

    // MARK: - BGRA 到 Tensor (vImage 加速)
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

            let err1 = vImageConvert_BGRX8888ToPlanar8(&src, &b8b, &g8b, &r8b, vImage_Flags(kvImageNoFlags))
            guard err1 == kvImageNoError else {
                logger.error("❌ vImageConvert_BGRX8888ToPlanar8 失败: \(err1)")
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

                return withUnsafeTemporaryAllocation(of: Float16.self, capacity: planeCount * 3) { f16Buf in
                    let r16 = f16Buf.baseAddress!
                    let g16 = r16.advanced(by: planeCount)
                    let b16 = g16.advanced(by: planeCount)

                    var rF16 = vImage_Buffer(data: r16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                    var gF16 = vImage_Buffer(data: g16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                    var bF16 = vImage_Buffer(data: b16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)

                    vImageConvert_PlanarFtoPlanar16F(&rFb, &rF16, vImage_Flags(kvImageNoFlags))
                    vImageConvert_PlanarFtoPlanar16F(&gFb, &gF16, vImage_Flags(kvImageNoFlags))
                    vImageConvert_PlanarFtoPlanar16F(&bFb, &bF16, vImage_Flags(kvImageNoFlags))

                    let dst = inputArray.dataPointer.assumingMemoryBound(to: Float16.self)
                    let planeBytes = planeCount * MemoryLayout<Float16>.size

                    if channels == 3 {
                        memcpy(dst, r16, planeBytes)
                        memcpy(dst.advanced(by: planeCount), g16, planeBytes)
                        memcpy(dst.advanced(by: 2 * planeCount), b16, planeBytes)
                    } else if channels == 12 {
                        for frame in 0..<4 {
                            let base = frame * 3 * planeCount
                            memcpy(dst.advanced(by: base), r16, planeBytes)
                            memcpy(dst.advanced(by: base + planeCount), g16, planeBytes)
                            memcpy(dst.advanced(by: base + 2 * planeCount), b16, planeBytes)
                        }
                    } else {
                        logger.error("❌ 不支持的输入通道数: \(channels)")
                        return false
                    }
                    return true
                }
            }
        }
    }

    // MARK: - Tensor 转 BGRA（预分配 buffer + vImage 一次性组装）
    // 注意：tmpFloat / tmpU8 是实例级复用 buffer，本方法不可并发调用。
    private func float16PlanarToBGRA(_ array: MLMultiArray, into buffer: CVPixelBuffer) -> Bool {
        let width = modelOutW, height = modelOutH
        let planeCount = width * height

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        let src = array.dataPointer.assumingMemoryBound(to: Float16.self)

        let rF = tmpFloat
        let gF = rF.advanced(by: planeCount)
        let bF = gF.advanced(by: planeCount)

        let r8 = tmpU8
        let g8 = r8.advanced(by: planeCount)
        let b8 = g8.advanced(by: planeCount)

        var r16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
        var g16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: planeCount)),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
        var b16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: 2 * planeCount)),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)

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

        // 修正：函数名 To 大写
        var dstBuf = vImage_Buffer(
            data: base,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let err = vImageConvert_Planar8ToBGRX8888(&b8b, &g8b, &r8b, 255, &dstBuf, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError {
            logger.error("❌ vImageConvert_Planar8ToBGRX8888 失败: \(err)")
            return false
        }
        return true
    }

    // MARK: - Tile 写回
    private func writeTileBack(to outBuffer: CVPixelBuffer,
                               srcX: Int, srcY: Int,
                               dstX: Int, dstY: Int,
                               w: Int, h: Int) -> Bool {
        guard float16PlanarToBGRA(outputArray, into: outTileBGRA) else { return false }

        CVPixelBufferLockBaseAddress(outTileBGRA, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outTileBGRA, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(outTileBGRA),
              let dstBase = CVPixelBufferGetBaseAddress(outBuffer) else { return false }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(outTileBGRA)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(outBuffer)
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        for row in 0..<h {
            let s = srcPtr.advanced(by: (srcY + row) * srcRowBytes + srcX * 4)
            let d = dstPtr.advanced(by: (dstY + row) * dstRowBytes + dstX * 4)
            memcpy(d, s, w * 4)
        }
        return true
    }

    // MARK: - Buffer 管理与辅助
    private static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
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
            logger.info("📦 创建新的输出 Buffer Pool: \(width)x\(height)")
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

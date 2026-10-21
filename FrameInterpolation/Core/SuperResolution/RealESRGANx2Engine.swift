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

// MARK: - RealESRGAN x2 引擎（256 tile -> 512 输出）
final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2

    // 模型固定输入
    let inputWidth: Int = 256
    let inputHeight: Int = 256
    // 2x 超分
    let scaleFactor: Int = 2

    // Tile 参数：pad 覆盖 RRDB 边界衰减，effIn=224，effOut=448
    private let pad: Int = 16
    private var effIn: Int { inputWidth - 2 * pad }   // 224
    private var effOut: Int { effIn * scaleFactor }   // 448

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let outputArray: MLMultiArray
    private let inputProvider: ReusableInput
    private let predOpts: MLPredictionOptions

    // 复用的中间 buffer
    private let tileBuf: CVPixelBuffer        // 256x256 BGRA 输入 tile
    private let outTileBGRA: CVPixelBuffer    // 512x512 BGRA 输出 tile
    private let modelOutW: Int
    private let modelOutH: Int

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
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
            logger.error("❌ 模型加载失败")
            return nil
        }
        self.model = model

        guard let inShape = model.modelDescription.inputDescriptionsByName["input"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              let outShape = model.modelDescription.outputDescriptionsByName["output"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              inShape.count == 4, outShape.count == 4 else {
            logger.error("❌ 模型输入/输出格式不是 4D Tensor")
            return nil
        }
        let inN = inShape[0], inC = inShape[1], inH = inShape[2], inW = inShape[3]
        let outN = outShape[0], outC = outShape[1], outH = outShape[2], outW = outShape[3]

        // 验证输入输出维度符合 x2 预期
        guard inN == 1, inW == inputWidth, inH == inputHeight,
              outN == 1, outC == 3,
              outW == inputWidth * scaleFactor, outH == inputHeight * scaleFactor else {
            logger.error("❌ 模型维度不符！期望: [1,\(inC),\(inputHeight),\(inputWidth)] -> [1,3,\(inputHeight*2),\(inputWidth*2)]；实际: \(inShape) -> \(outShape)")
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

        guard let tileBuf = Self.makeBGRA(width: inputWidth, height: inputHeight),
              let outTileBGRA = Self.makeBGRA(width: outW, height: outH) else {
            logger.error("❌ 复用 Tile Buffer 创建失败")
            return nil
        }
        self.tileBuf = tileBuf
        self.outTileBGRA = outTileBGRA

        let elapsed = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        logger.info("✅ 引擎初始化成功！耗时: \(elapsed, format: .fixed(precision: 2))ms。输入: \(inW)x\(inH) 通道:\(inC)，输出: \(outW)x\(outH)")
    }

    // MARK: - 公共接口

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        cancelLock.lock(); isCancelledFlag = false; cancelLock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor
        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else {
            logger.error("❌ 申请输出 Buffer 失败: \(outW)x\(outH)")
            return nil
        }

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

                // 1. 反射 padding 抽取 tile
                guard extractReflectTile(from: pixelBuffer, into: tileBuf,
                                         x: srcX, y: srcY,
                                         w: inputWidth, h: inputHeight) else {
                    logger.error("❌ Tile[\(tx),\(ty)] 反射裁剪失败")
                    continue
                }

                // 2. BGRA -> Tensor (FP16)
                let tConvertStart = CFAbsoluteTimeGetCurrent()
                guard bgraToTensor(tileBuf) else {
                    logger.error("❌ Tile[\(tx),\(ty)] 格式转换失败")
                    continue
                }
                let tConvertCost = (CFAbsoluteTimeGetCurrent() - tConvertStart) * 1000

                // 3. 推理
                let tPredictStart = CFAbsoluteTimeGetCurrent()
                guard (try? model.prediction(from: inputProvider, options: predOpts)) != nil else {
                    logger.error("❌ Tile[\(tx),\(ty)] 模型推理失败")
                    continue
                }
                let tPredictCost = (CFAbsoluteTimeGetCurrent() - tPredictStart) * 1000

                // 4. 裁剪写回
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

                let tTileEnd = CFAbsoluteTimeGetCurrent()
                let tileCost = (tTileEnd - tTileStart) * 1000

                logger.debug("  🧩 Tile[\(tx),\(ty)] 耗时: \(tileCost, format: .fixed(precision: 2))ms (转换: \(tConvertCost, format: .fixed(precision: 2))ms, 推理: \(tPredictCost, format: .fixed(precision: 2))ms, 写回: \(tWriteCost, format: .fixed(precision: 2))ms)")
            }
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)
        
        let tFrameEnd = CFAbsoluteTimeGetCurrent()
        let totalCost = (tFrameEnd - tFrameStart) * 1000
        logger.debug("✅ 帧处理完成！总耗时: \(totalCost, format: .fixed(precision: 2))ms")
        
        return outBuffer
    }

    func cancel() {
        cancelLock.lock(); isCancelledFlag = true; cancelLock.unlock()
        logger.info("⚠️ 触发 cancel() 信号")
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

    // MARK: - Tensor 转 BGRA (vImage 加速 + 手动合并)
    private func float16PlanarToBGRA(_ array: MLMultiArray, into buffer: CVPixelBuffer) -> Bool {
        let width = modelOutW, height = modelOutH
        let planeCount = width * height

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        let src = array.dataPointer.assumingMemoryBound(to: Float16.self)

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: planeCount * 3) { fBuf in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: planeCount * 3) { u8Buf in
                let rF = fBuf.baseAddress!
                let gF = rF.advanced(by: planeCount)
                let bF = gF.advanced(by: planeCount)

                let r8 = u8Buf.baseAddress!
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

                // 手工组装 BGRA，规避 Xcode 16 中宏签名不兼容的问题 (512x512 耗时仅 < 1ms)
                let dstPtr = base.assumingMemoryBound(to: UInt8.self)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                
                for y in 0..<height {
                    let srcRowOffset = y * width
                    let dstRowOffset = y * dstBytesPerRow
                    for x in 0..<width {
                        let srcIdx = srcRowOffset + x
                        let dstIdx = dstRowOffset + x * 4
                        dstPtr[dstIdx + 0] = b8[srcIdx]
                        dstPtr[dstIdx + 1] = g8[srcIdx]
                        dstPtr[dstIdx + 2] = r8[srcIdx]
                        dstPtr[dstIdx + 3] = 255
                    }
                }
                
                return true
            }
        }
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

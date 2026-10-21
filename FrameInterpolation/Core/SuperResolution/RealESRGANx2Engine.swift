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

// MARK: - RealESRGAN x2 引擎（256 tile → 512 输出）

final class RealESRGANx2Engine: SuperResolutionEngine {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "RealESRGANx2Engine")

    static let engineType: SuperResolutionEngineType = .realESRGANx2

    // 模型固定输入
    let inputWidth: Int = 256
    let inputHeight: Int = 256
    // 2x
    let scaleFactor: Int = 2

    // tile 参数：pad 覆盖 RRDB 边界衰减，effIn=224，effOut=448
    private let pad: Int = 16
    private var effIn: Int { inputWidth - 2 * pad }   // 224
    private var effOut: Int { effIn * scaleFactor }   // 448

    private let model: MLModel
    private let inputArray: MLMultiArray
    private let outputArray: MLMultiArray
    private let inputProvider: ReusableInput
    private let predOpts: MLPredictionOptions

    // 复用的中间 buffer
    private let tileBuf: CVPixelBuffer        // 256×256 BGRA 输入 tile
    private let outTileBGRA: CVPixelBuffer    // 512×512 BGRA 输出 tile
    private let modelOutW: Int
    private let modelOutH: Int

    // 最终输出 pool
    private var outputPool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    private var isCancelledFlag = false
    private let cancelLock = NSLock()

    init?() {
        guard let modelURL = Bundle.main.url(
            forResource: SuperResolutionEngineType.realESRGANx2.modelFileName,
            withExtension: "mlmodelc"
        ) else { return nil }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else { return nil }
        self.model = model

        // 从模型描述读 shape，彻底避免硬编码
        guard let inShape = model.modelDescription.inputDescriptionsByName["input"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              let outShape = model.modelDescription.outputDescriptionsByName["output"]?
                .multiArrayConstraint?.shape.map({ $0.intValue }),
              inShape.count == 4, outShape.count == 4 else {
            return nil
        }
        let inN = inShape[0], inC = inShape[1], inH = inShape[2], inW = inShape[3]
        let outN = outShape[0], outC = outShape[1], outH = outShape[2], outW = outShape[3]

        guard inN == 1, inW == inputWidth, inH == inputHeight,
              outN == 1, outC == 3,
              outW == inputWidth * scaleFactor, outH == inputHeight * scaleFactor else {
            return nil
        }
        self.modelOutW = outW
        self.modelOutH = outH

        guard let inputArray = try? MLMultiArray(shape: inShape.map { NSNumber(value: $0) }, dataType: .float16),
              let outputArray = try? MLMultiArray(shape: outShape.map { NSNumber(value: $0) }, dataType: .float16) else {
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
            return nil
        }
        self.tileBuf = tileBuf
        self.outTileBGRA = outTileBGRA

        logger.info("RealESRGAN x2 初始化：输入 \(inW)x\(inH) 通道 \(inC)，输出 \(outW)x\(outH)")
    }

    // MARK: - 公共接口

    func upscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        cancelLock.lock(); isCancelledFlag = false; cancelLock.unlock()

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        let outW = srcW * scaleFactor
        let outH = srcH * scaleFactor
        guard let outBuffer = makeOutputBuffer(width: outW, height: outH) else { return nil }

        let cols = max(1, (srcW + effIn - 1) / effIn)
        let rows = max(1, (srcH + effIn - 1) / effIn)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outBuffer, [])
        }

        for ty in 0..<rows {
            for tx in 0..<cols {
                cancelLock.lock(); let cancelled = isCancelledFlag; cancelLock.unlock()
                if cancelled { return nil }

                let srcX = tx * effIn - pad
                let srcY = ty * effIn - pad

                guard extractReflectTile(from: pixelBuffer, into: tileBuf,
                                         x: srcX, y: srcY,
                                         w: inputWidth, h: inputHeight) else { continue }

                guard bgraToTensor(tileBuf) else { continue }

                guard (try? model.prediction(from: inputProvider, options: predOpts)) != nil else {
                    logger.error("tile 推理失败")
                    continue
                }

                let dstX = tx * effOut
                let dstY = ty * effOut
                let copyW = min(effOut, outW - dstX)
                let copyH = min(effOut, outH - dstY)
                guard copyW > 0, copyH > 0 else { continue }

                _ = writeTileBack(to: outBuffer,
                                  srcX: pad * scaleFactor, srcY: pad * scaleFactor,
                                  dstX: dstX, dstY: dstY,
                                  w: copyW, h: copyH)
            }
        }

        copyColorSpaceAttachments(from: pixelBuffer, to: outBuffer)
        return outBuffer
    }

    func cancel() {
        cancelLock.lock(); isCancelledFlag = true; cancelLock.unlock()
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

        // 列方向分三段：左反射 / 中间直拷 / 右反射
        let leftEnd    = min(w, max(0, -x))                  // x+tx < 0 的区域
        let rightStart = min(w, max(leftEnd, srcW - x))      // x+tx >= srcW 的区域
        let rowBytes   = w * 4

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
            _ = rowBytes // 保持可读性
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

    // MARK: - BGRA → Tensor（vImage）

    private func bgraToTensor(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let w = inputWidth, h = inputHeight
        let planeCount = w * h
        let channels = inputArray.shape[1].intValue

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: planeCount * 3) { fBuf in
            let rF = fBuf.baseAddress!
            let gF = rF.advanced(by: planeCount)
            let bF = gF.advanced(by: planeCount)

            var rPlane = vImage_Buffer(data: rF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var gPlane = vImage_Buffer(data: gF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var bPlane = vImage_Buffer(data: bF, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)

            let err = vImageConvert_BGRA8888toPlanarF(&src, &rPlane, &gPlane, &bPlane,
                                                      nil, 1.0 / 255.0, 0.0,
                                                      vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { return false }

            return withUnsafeTemporaryAllocation(of: Float16.self, capacity: planeCount * 3) { f16Buf in
                let r16 = f16Buf.baseAddress!
                let g16 = r16.advanced(by: planeCount)
                let b16 = g16.advanced(by: planeCount)

                var rF16 = vImage_Buffer(data: r16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                var gF16 = vImage_Buffer(data: g16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                var bF16 = vImage_Buffer(data: b16, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                var rSrc = rPlane, gSrc = gPlane, bSrc = bPlane

                guard vImageConvert_PlanarFtoPlanar16F(&rSrc, &rF16, kvImageNoFlags) == kvImageNoError,
                      vImageConvert_PlanarFtoPlanar16F(&gSrc, &gF16, kvImageNoFlags) == kvImageNoError,
                      vImageConvert_PlanarFtoPlanar16F(&bSrc, &bF16, kvImageNoFlags) == kvImageNoError
                else { return false }

                let dst = inputArray.dataPointer.assumingMemoryBound(to: Float16.self)
                let planeBytes = planeCount * MemoryLayout<Float16>.size

                if channels == 3 {
                    memcpy(dst, r16, planeBytes)
                    memcpy(dst.advanced(by: planeCount), g16, planeBytes)
                    memcpy(dst.advanced(by: 2 * planeCount), b16, planeBytes)
                } else if channels == 12 {
                    // 4 帧 × RGB，当前帧重复填充；换 3ch 模型后删掉这块
                    for frame in 0..<4 {
                        let base = frame * 3 * planeCount
                        memcpy(dst.advanced(by: base), r16, planeBytes)
                        memcpy(dst.advanced(by: base + planeCount), g16, planeBytes)
                        memcpy(dst.advanced(by: base + 2 * planeCount), b16, planeBytes)
                    }
                } else {
                    return false
                }
                return true
            }
        }
    }

    // MARK: - Tensor → BGRA（vImage，写进复用的 outTileBGRA）

    private func float16PlanarToBGRA(_ array: MLMultiArray, into buffer: CVPixelBuffer) -> Bool {
        let width = modelOutW, height = modelOutH
        let planeCount = width * height

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

        let src = array.dataPointer.assumingMemoryBound(to: Float16.self)

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: planeCount * 3) { fBuf in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: planeCount * 3) { u8Buf in
                let rF = fBuf.baseAddress!, gF = rF.advanced(by: planeCount), bF = gF.advanced(by: planeCount)
                let r8 = u8Buf.baseAddress!, g8 = r8.advanced(by: planeCount), b8 = g8.advanced(by: planeCount)

                var r16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                        height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
                var g16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: planeCount)),
                                        height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
                var b16 = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.advanced(by: 2 * planeCount)),
                                        height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)

                var rFb = vImage_Buffer(data: rF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var gFb = vImage_Buffer(data: gF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var bFb = vImage_Buffer(data: bF, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)

                vImageConvert_Planar16FtoPlanarF(&r16, &rFb, kvImageNoFlags)
                vImageConvert_Planar16FtoPlanarF(&g16, &gFb, kvImageNoFlags)
                vImageConvert_Planar16FtoPlanarF(&b16, &bFb, kvImageNoFlags)

                var r8b = vImage_Buffer(data: r8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var g8b = vImage_Buffer(data: g8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b8b = vImage_Buffer(data: b8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)

                vImageConvert_PlanarFtoPlanar8(&rFb, &r8b, 255.0, 0.0, kvImageNoFlags)
                vImageConvert_PlanarFtoPlanar8(&gFb, &g8b, 255.0, 0.0, kvImageNoFlags)
                vImageConvert_PlanarFtoPlanar8(&bFb, &b8b, 255.0, 0.0, kvImageNoFlags)

                var dst = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRow(buffer))
                vImageConvert_Planar8toARGB8888(&b8b, &g8b, &r8b, nil, &dst, kvImageNoFlags)
                return true
            }
        }
    }

    // MARK: - Tile 写回（crop + memcpy，outBuffer 已由 caller lock）

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

    // MARK: - Buffer 管理

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
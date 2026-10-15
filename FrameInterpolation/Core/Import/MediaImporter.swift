import AVFoundation
import UIKit
import OSLog
import CoreMedia

/// 媒体导入工具：读取视频真实元数据（时长、帧率、分辨率、文件大小、缩略图）
enum MediaImporter {
    private static let logger = Logger(subsystem: "com.lambret.bz", category: "MediaImporter")

    /// 读取视频元数据
    /// - Parameter url: 视频文件 URL
    /// - Returns: 完整的 VideoInfo 结构体
    static func loadVideoInfo(from url: URL) async throws -> VideoInfo {
        logger.info("开始读取视频元数据: \(url.lastPathComponent, privacy: .public)")

        let asset = AVURLAsset(url: url)

        // 并发加载时长和视频轨道
        async let duration = asset.load(.duration)
        async let tracks = asset.loadTracks(withMediaType: .video)

        let (resolvedDuration, resolvedTracks) = try await (duration, tracks)

        guard let track = resolvedTracks.first else {
            logger.error("未找到视频轨道")
            throw NSError(
                domain: "MediaImporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到视频轨道，文件可能不是有效的视频"]
            )
        }

        // 并发加载帧率、自然尺寸、变换矩阵、码率
        async let fps = track.load(.nominalFrameRate)
        async let naturalSize = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let dataRate = track.load(.estimatedDataRate)

        let (resolvedFps, resolvedNaturalSize, resolvedTransform, resolvedDataRate) = try await (fps, naturalSize, transform, dataRate)

        // 计算显示尺寸（应用旋转变换后）
        let displaySize = resolvedNaturalSize.applying(resolvedTransform)
        let width = Int(abs(displaySize.width))
        let height = Int(abs(displaySize.height))

        // 视频码率（Mbps）
        let bitRateMbps = resolvedDataRate > 0 ? resolvedDataRate / 1_000_000 : 0

        // 视频编码格式（从 formatDescriptions 解析 codecType）
        let codecFormat = Self.parseCodecFormat(track: track)

        // 文件大小
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }
        let sizeMB = Double(fileSize) / 1024 / 1024

        // 生成缩略图（失败不影响主流程）
        let thumbnail = try? await generateThumbnail(asset: asset)

        let durationSeconds = CMTimeGetSeconds(resolvedDuration)

        logger.info("视频元数据读取完成: 时长\(durationSeconds)s, 帧率\(resolvedFps)fps, 分辨率\(width)x\(height), 大小\(sizeMB)MB, 码率\(bitRateMbps)Mbps, 编码\(codecFormat)")

        return VideoInfo(
            url: url,
            fileName: url.lastPathComponent,
            duration: durationSeconds,
            originalFPS: Double(resolvedFps),
            originalSizeMB: sizeMB,
            width: width,
            height: height,
            codecFormat: codecFormat,
            bitRateMbps: bitRateMbps,
            thumbnail: thumbnail
        )
    }

    /// 从 AVAssetTrack 的 formatDescriptions 解析视频编码格式
    private static func parseCodecFormat(track: AVAssetTrack) -> String {
        guard let first = track.formatDescriptions.first as CMFormatDescription? else {
            return "未知"
        }
        let codecType = CMFormatDescriptionGetMediaSubType(first)
        let codec = fourCCToString(codecType)
        switch codec {
        case "avc1", "AVC1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case "jpeg": return "JPEG"
        default: return codec.uppercased()
        }
    }

    private static func fourCCToString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "未知"
    }

    /// 生成视频缩略图（取第 0.5 秒帧）
    private static func generateThumbnail(asset: AVAsset) async throws -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image
        return UIImage(cgImage: cgImage)
    }
}

import SwiftUI
import AVFoundation

/// 缩放级别
enum ZoomLevel: CGFloat, CaseIterable {
    case l0 = 0.5    // 宏观
    case l1 = 2.0    // 中观
    case l2 = 10.0   // 微观
    case l3 = 20.0   // 逐帧
}

/// 时间线视图：刻度尺 + 胶片轨道 + 播放头
struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentZoom: ZoomLevel = .l1
    @State private var currentFrame: Int = 0
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var selectedSegmentID: UUID?

    private var totalFrames: Int {
        guard let video = appState.currentProject?.videoInfo else { return 0 }
        return Int(video.duration * video.originalFPS)
    }

    private var fps: Double {
        appState.currentProject?.videoInfo.originalFPS ?? 30
    }

    private var frameWidth: CGFloat { currentZoom.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            // 刻度尺
            rulerView

            // 胶片轨道
            filmstripView

            // 逐帧微调（L2/L3 显示）
            if currentZoom == .l2 || currentZoom == .l3 {
                frameStepControl
            }

            // 添加音频按钮
            audioAddButton
        }
        .background(Color.timelineBg)
    }

    // MARK: - 刻度尺
    private var rulerView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<max(totalFrames, 1), id: \.self) { index in
                    if index % 10 == 0 {
                        Text("\(index)f")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .frame(width: frameWidth * 10, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, UIScreen.main.bounds.width / 2)
        }
        .frame(height: 24)
        .background(Color.timelineBg)
    }

    // MARK: - 胶片轨道
    private var filmstripView: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(0..<max(totalFrames, 1), id: \.self) { index in
                        ZStack {
                            if let thumb = thumbnails[index] {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: frameWidth, height: 80)
                                    .clipped()
                            } else {
                                Rectangle()
                                    .fill(Color(uiColor: .tertiarySystemBackground))
                                    .frame(width: frameWidth, height: 80)
                            }
                        }
                        .onAppear { loadThumbnailIfNeeded(at: index) }
                    }
                }
                .padding(.horizontal, UIScreen.main.bounds.width / 2)
            }
            .gesture(
                MagnificationGesture()
                    .onEnded { value in
                        if value > 1.0 {
                            if let idx = ZoomLevel.allCases.firstIndex(of: currentZoom),
                               idx < ZoomLevel.allCases.count - 1 {
                                currentZoom = ZoomLevel.allCases[idx + 1]
                            }
                        } else {
                            if let idx = ZoomLevel.allCases.firstIndex(of: currentZoom), idx > 0 {
                                currentZoom = ZoomLevel.allCases[idx - 1]
                            }
                        }
                    }
            )

            // 播放头固定居中
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 80)
        }
        .frame(height: 80)
    }

    // MARK: - 逐帧微调
    private var frameStepControl: some View {
        HStack {
            Button {
                currentFrame = max(0, currentFrame - 1)
                UISelectionFeedbackGenerator().selectionChanged()
                seekToFrame(currentFrame)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("上一帧")
                }
                .font(.system(size: 14))
                .foregroundColor(.topBarText)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 20).background(Color.gray)

            Button {
                currentFrame = min(max(totalFrames - 1, 0), currentFrame + 1)
                UISelectionFeedbackGenerator().selectionChanged()
                seekToFrame(currentFrame)
            } label: {
                HStack(spacing: 4) {
                    Text("下一帧")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 14))
                .foregroundColor(.topBarText)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - 添加音频
    private var audioAddButton: some View {
        Button {
            // 音频选择器（后续实现）
        } label: {
            HStack {
                Image(systemName: "plus")
                Text("添加音频")
            }
            .font(.system(size: 14))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(uiColor: .secondarySystemBackground))
        }
    }

    // MARK: - 缩略图加载
    private func loadThumbnailIfNeeded(at index: Int) {
        guard thumbnails[index] == nil,
              let url = appState.currentProject?.videoInfo.url else { return }

        let time = CMTime(value: Int64(index), timescale: Int32(fps))
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            if let cgImage {
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { thumbnails[index] = image }
            }
        }
    }

    private func seekToFrame(_ frame: Int) {
        let time = Double(frame) / fps
        PlayerManager.shared.seek(to: time)
    }
}

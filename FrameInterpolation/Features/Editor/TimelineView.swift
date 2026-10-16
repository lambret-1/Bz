import SwiftUI
import AVFoundation

/// 缩放级别
enum ZoomLevel: CGFloat, CaseIterable {
    case l0 = 0.5    // 宏观
    case l1 = 2.0    // 中观
    case l2 = 10.0   // 微观
    case l3 = 20.0   // 逐帧
}

/// 时间线视图：刻度尺 + 片段卡片 + 播放头 + 缩放 + 逐帧 + 音频轨 + 转场
struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentZoom: ZoomLevel = .l1
    @State private var currentFrame: Int = 0
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var audioSegment: AudioSegment?
    @State private var transition: TransitionType = .none
    @State private var transitionDuration: TimeInterval = 0.3
    @State private var timeObserver: Any?
    @State private var isScrubbing = false

    private var selectedSegmentID: UUID? { appState.selectedSegmentID }

    private var totalFrames: Int {
        guard let video = appState.currentProject?.videoInfo else { return 0 }
        return Int(video.duration * video.originalFPS)
    }

    private var fps: Double {
        appState.currentProject?.videoInfo.originalFPS ?? 30
    }

    private var frameWidth: CGFloat { currentZoom.rawValue }

    private var segments: [VideoSegment] {
        appState.currentProject?.segments ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // 刻度尺
            rulerView

            // 片段轨道（含胶片缩略图 + 选中态 + 裁剪把手）
            segmentTrackView

            // 逐帧微调（L2/L3 显示）
            if currentZoom == .l2 || currentZoom == .l3 {
                frameStepControl
            }

            // 音频轨
            if let audioSegment {
                AudioTrackView(audioSegment: audioSegment, isSelected: false)
                    .frame(height: 44)
                    .padding(.horizontal, 16)
            }

            // 转场按钮 + 添加音频
            bottomControls
        }
        .background(Color.timelineBg)
        .onAppear { setupPlayerObserver() }
        .onDisappear { removePlayerObserver() }
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
        .accessibilityLabel("时间刻度尺")
    }

    // MARK: - 片段轨道
    private var segmentTrackView: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        segmentCard(segment, index: index)
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
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )

            // 播放头固定居中（帧吸附）
            playheadView
        }
        .frame(height: 100)
    }

    // MARK: - 片段卡片
    private func segmentCard(_ segment: VideoSegment, index: Int) -> some View {
        SegmentCardView(
            segment: segment,
            index: index,
            isSelected: selectedSegmentID == segment.id,
            frameWidth: frameWidth,
            fps: fps,
            thumbnails: thumbnails,
            onTap: {
                appState.selectedSegmentID = selectedSegmentID == segment.id ? nil : segment.id
                UISelectionFeedbackGenerator().selectionChanged()
            },
            onTrim: { newStart, newEnd in
                trimSegment(segment, start: newStart, end: newEnd)
            }
        )
        .onAppear { loadSegmentThumbnails(segment) }
    }

    // MARK: - 播放头（帧吸附）
    private var playheadView: some View {
        VStack(spacing: 0) {
            // 顶部三角
            Triangle()
                .fill(Color.accentPink)
                .frame(width: 12, height: 8)
            // 竖线
            Rectangle()
                .fill(Color.accentPink)
                .frame(width: 2, height: 92)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("播放头，当前第 \(currentFrame) 帧")
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
            .accessibilityLabel("上一帧")

            Divider().frame(height: 20).background(Color.gray)

            Text("f\(String(format: "%03d", currentFrame))")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.accentPink)
                .frame(width: 80)

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
            .accessibilityLabel("下一帧")
        }
        .frame(height: 44)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - 底部控制（转场 + 添加音频）
    private var bottomControls: some View {
        HStack(spacing: 12) {
            // 转场按钮
            TransitionButton(transition: $transition, duration: $transitionDuration)
                .padding(.leading, 16)

            Spacer()

            // 添加音频按钮
            Button {
                // 音频选择器（后续实现）
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("添加音频")
                }
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(8)
            }
            .padding(.trailing, 16)
            .accessibilityLabel("添加音频")
        }
        .frame(height: 52)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - 播放器观察者（播放头与播放器同步）
    private func setupPlayerObserver() {
        guard let player = PlayerManager.shared.player else { return }
        let interval = CMTime(seconds: 0.033, preferredTimescale: 600) // ~30fps
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing else { return }
            let seconds = CMTimeGetSeconds(time)
            let frame = Int(seconds * fps)
            if frame != currentFrame {
                currentFrame = frame
            }
        }
    }

    private func removePlayerObserver() {
        if let observer = timeObserver, let player = PlayerManager.shared.player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    // MARK: - 缩略图加载
    private func loadSegmentThumbnails(_ segment: VideoSegment) {
        let startFrame = Int(segment.startTime * fps)
        let frameCount = max(1, Int(segment.duration * fps))
        let step = max(1, frameCount / 10)

        for i in stride(from: 0, to: frameCount, by: step) {
            loadThumbnailIfNeeded(at: startFrame + i)
        }
    }

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

    // MARK: - 帧吸附跳转
    private func seekToFrame(_ frame: Int) {
        // 帧吸附：对齐到最近的帧边界
        let snappedFrame = max(0, min(totalFrames - 1, frame))
        let time = Double(snappedFrame) / fps
        PlayerManager.shared.seek(to: time)
        currentFrame = snappedFrame
    }

    // MARK: - 片段裁剪
    private func trimSegment(_ segment: VideoSegment, start: TimeInterval, end: TimeInterval) {
        guard let project = appState.currentProject,
              let index = project.segments.firstIndex(where: { $0.id == segment.id }) else { return }

        let videoDuration = project.videoInfo.duration
        let clampedStart = max(0, min(start, end - 0.1))
        let clampedEnd = max(clampedStart + 0.1, min(end, videoDuration))

        appState.updateCurrentProject { project in
            project.segments[index].startTime = clampedStart
            project.segments[index].duration = clampedEnd - clampedStart
        }
    }
}

/// 片段卡片视图（独立组件，避免表达式过复杂）
struct SegmentCardView: View {
    let segment: VideoSegment
    let index: Int
    let isSelected: Bool
    let frameWidth: CGFloat
    let fps: Double
    let thumbnails: [Int: UIImage]
    let onTap: () -> Void
    let onTrim: (TimeInterval, TimeInterval) -> Void

    private var segmentFrames: Int { max(1, Int(segment.duration * fps)) }
    private var segmentWidth: CGFloat { CGFloat(segmentFrames) * frameWidth }
    private var thumbnailCount: Int { min(segmentFrames, 20) }
    private var thumbWidth: CGFloat { max(segmentWidth / CGFloat(thumbnailCount), 1) }

    var body: some View {
        ZStack(alignment: .leading) {
            // 胶片缩略图背景
            filmstripBackground

            // 选中态边框
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentPink : Color.clear, lineWidth: 2)

            // 片段序号
            if isSelected {
                segmentLabel
            }

            // 裁剪把手（选中时显示）
            if isSelected {
                SegmentTrimOverlay(segment: segment, onTrim: onTrim)
            }
        }
        .frame(width: segmentWidth, height: 100)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel("片段 \(index + 1)，时长 \(String(format: "%.1f", segment.duration))秒")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var filmstripBackground: some View {
        HStack(spacing: 0) {
            ForEach(0..<thumbnailCount, id: \.self) { frameOffset in
                let absoluteFrame = Int(segment.startTime * fps) + frameOffset
                if let thumb = thumbnails[absoluteFrame] {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbWidth, height: 80)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .tertiarySystemBackground))
                        .frame(width: thumbWidth, height: 80)
                }
            }
        }
    }

    private var segmentLabel: some View {
        VStack {
            HStack {
                Text("片段 \(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentPink)
                    .cornerRadius(4)
                Spacer()
            }
            Spacer()
        }
        .padding(4)
    }
}

/// 三角形（播放头顶部）
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

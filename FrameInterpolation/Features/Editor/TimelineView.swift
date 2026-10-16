import SwiftUI
import AVFoundation

/// 缩放级别
enum ZoomLevel: CGFloat, CaseIterable {
    case l0 = 4.0    // 宏观（每帧4pt，确保最小可交互宽度）
    case l1 = 8.0    // 中观（每帧8pt，缩略图可辨认）
    case l2 = 20.0   // 微观（每帧20pt）
    case l3 = 40.0   // 逐帧（每帧40pt）
}

/// 时间线视图：刻度尺 + 片段卡片 + 播放头 + 缩放 + 逐帧 + 音频轨 + 转场
/// 单 ScrollView 架构：刻度尺与片段轨道同步滚动，避免双 ScrollView 不同步
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
    @State private var viewAlive = true  // 标记视图存活，避免异步回调写入已销毁视图

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
            // 统一滚动区域：刻度尺 + 片段轨道在同一个 ScrollView 内，保证同步
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // 刻度尺
                    rulerView
                    // 片段轨道（含胶片缩略图 + 选中态 + 裁剪把手）
                    segmentTrackView
                }
                .padding(.horizontal, UIScreen.main.bounds.width / 2)
            }
            .frame(height: 124)  // 24(刻度尺) + 100(片段轨道)
            .background(Color.timelineBg)
            // 缩放手势（用 simultaneousGesture 避免与滚动手势冲突）
            .simultaneousGesture(
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
            // 拖动开始/结束时设置 isScrubbing，防止播放器回调抢帧号
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        if !isScrubbing { isScrubbing = true }
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )

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
        .onAppear {
            viewAlive = true
            setupPlayerObserver()
        }
        .onDisappear {
            viewAlive = false
            removePlayerObserver()
        }
        // 监听项目变化（异步导入完成后刷新片段轨道）
        .onChange(of: appState.currentProject?.id) { _ in
            // 触发视图刷新，重新计算 segments
        }
    }

    // MARK: - 刻度尺
    private var rulerView: some View {
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
        .frame(height: 24)
        .accessibilityLabel("时间刻度尺")
    }

    // MARK: - 片段轨道
    private var segmentTrackView: some View {
        ZStack(alignment: .top) {
            if segments.isEmpty {
                // 空状态占位
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                        Text("等待视频导入…")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                }
                .frame(height: 100)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        segmentCard(segment, index: index)
                    }
                }
            }

            // 播放头固定居中（帧吸附），ZStack 顶部对齐，白色
            if !segments.isEmpty {
                playheadView
            }
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
            onTrimChanged: { newStart, newEnd in
                // 实时预览：临时更新片段（不保存到撤销栈）
                trimSegmentPreview(segment, start: newStart, end: newEnd)
            },
            onTrimEnded: { newStart, newEnd in
                // 结束时保存（推入撤销栈）
                trimSegment(segment, start: newStart, end: newEnd)
            }
        )
        .onAppear { loadSegmentThumbnails(segment) }
    }

    // MARK: - 播放头（帧吸附，白色）
    private var playheadView: some View {
        VStack(spacing: 0) {
            // 顶部三角
            Triangle()
                .fill(Color.white)
                .frame(width: 12, height: 8)
            // 竖线（填充剩余高度）
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
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
            HStack(spacing: 6) {
                TransitionButton(transition: $transition, duration: $transitionDuration)
                Text("转场")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .padding(.leading, 16)

            Spacer()

            // 添加音频按钮
            Button {
                appState.showToast("音频轨道功能即将上线", style: .warning)
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
        // 降低刷新频率到 20fps（0.05s），减少主线程压力
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard self.viewAlive else { return }
            guard !self.isScrubbing else { return }  // 拖动时不覆盖帧号
            let seconds = CMTimeGetSeconds(time)
            let frame = Int(seconds * self.fps)
            if frame != self.currentFrame {
                self.currentFrame = frame
            }
        }
    }

    private func removePlayerObserver() {
        if let observer = timeObserver, let player = PlayerManager.shared.player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    // MARK: - 缩略图加载（加载20个，与显示数量一致）
    private func loadSegmentThumbnails(_ segment: VideoSegment) {
        let startFrame = Int(segment.startTime * fps)
        let frameCount = max(1, Int(segment.duration * fps))
        let thumbnailCount = min(frameCount, 20)  // 与 SegmentCardView 显示数量一致
        let step = max(1, frameCount / thumbnailCount)

        for i in stride(from: 0, to: frameCount, by: step) {
            loadThumbnailIfNeeded(at: startFrame + i)
        }
    }

    private func loadThumbnailIfNeeded(at index: Int) {
        guard thumbnails[index] == nil,
              let url = appState.currentProject?.videoInfo.url else { return }

        // 用 600 timescale 避免 fps 截断（29.97fps 不会变 29）
        let time = CMTime(value: Int64(Double(index) * 600 / fps), timescale: 600)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            guard self.viewAlive else { return }  // 检查视图存活
            if let cgImage {
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    guard self.viewAlive else { return }
                    self.thumbnails[index] = image
                }
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

    /// 裁剪实时预览（不推入撤销栈，拖动结束时再调用trimSegment保存）
    private func trimSegmentPreview(_ segment: VideoSegment, start: TimeInterval, end: TimeInterval) {
        guard let project = appState.currentProject,
              let index = project.segments.firstIndex(where: { $0.id == segment.id }) else { return }

        let videoDuration = project.videoInfo.duration
        let clampedStart = max(0, min(start, end - 0.1))
        let clampedEnd = max(clampedStart + 0.1, min(end, videoDuration))

        // 直接更新，不调用updateCurrentProject（避免每次拖动都保存）
        if var updated = appState.currentProject {
            updated.segments[index].startTime = clampedStart
            updated.segments[index].duration = clampedEnd - clampedStart
            appState.currentProject = updated
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
    let onTrimChanged: (TimeInterval, TimeInterval) -> Void
    let onTrimEnded: (TimeInterval, TimeInterval) -> Void

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

            // 裁剪把手（选中时显示，实时反馈）
            if isSelected {
                SegmentTrimOverlay(
                    segment: segment,
                    frameWidth: frameWidth,
                    fps: fps,
                    onTrimChanged: onTrimChanged,
                    onTrimEnded: onTrimEnded
                )
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
                    .background(Color.accentPink.opacity(0.8))
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

import SwiftUI
import AVFoundation
import AVKit

/// 播放控制条：时间码显示 + 播放/暂停 + 撤销/重做 + 全屏
struct PlaybackControlBar: View {
    @EnvironmentObject var appState: AppState

    @State private var currentTime: TimeInterval = 0
    @State private var totalTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var isFrameMode = false
    @State private var showFullScreen = false
    @State private var durationObserver: NSKeyValueObservation?

    private var fps: Double {
        appState.currentProject?.videoInfo.originalFPS ?? 30
    }

    private var videoDuration: TimeInterval {
        appState.currentProject?.videoInfo.duration ?? 0
    }

    var body: some View {
        HStack {
            // 时间码/帧号显示
            TimecodeDisplay(
                currentFrame: Int(currentTime * fps),
                totalFrames: Int(totalTime * fps),
                currentTime: currentTime,
                totalTime: totalTime,
                isFrameMode: isFrameMode,
                thumbnail: nil
            )
            .onTapGesture {
                isFrameMode.toggle()
            }

            Spacer()

            // 播放/暂停
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.topBarText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            Spacer()

            // 撤销/重做/全屏
            HStack(spacing: 16) {
                Button {
                    appState.undoSegmentEdit()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20))
                        .foregroundColor(appState.canUndo ? .topBarText : .gray)
                }
                .disabled(!appState.canUndo)
                .accessibilityLabel("撤销")

                Button {
                    appState.redoSegmentEdit()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 20))
                        .foregroundColor(appState.canRedo ? .topBarText : .gray)
                }
                .disabled(!appState.canRedo)
                .accessibilityLabel("重做")

                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 20))
                        .foregroundColor(.topBarText)
                }
                .accessibilityLabel("全屏预览")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.topBarBg)
        .onAppear { setupPlayerObservers() }
        .onDisappear { cleanup() }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPlayerView()
                .environmentObject(appState)
        }
    }

    private func togglePlayback() {
        PlayerManager.shared.togglePlayback()
        isPlaying.toggle()
    }

    private func setupPlayerObservers() {
        guard let player = PlayerManager.shared.player else {
            // player未就绪时，从项目数据读取总时长
            totalTime = videoDuration
            return
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
        }

        // 先尝试从项目数据读取总时长
        totalTime = videoDuration

        // 同时观察player item的duration变化（异步加载完成后更新）
        if let item = player.currentItem {
            durationObserver = item.observe(\.duration, options: [.new]) { _, change in
                if let newDuration = change.newValue, newDuration.seconds > 0 {
                    DispatchQueue.main.async {
                        totalTime = newDuration.seconds
                    }
                }
            }
            // 如果已经加载完成，直接读取
            if item.status == .readyToPlay && item.duration.seconds > 0 {
                totalTime = item.duration.seconds
            }
        }
    }

    private func cleanup() {
        if let observer = timeObserver {
            PlayerManager.shared.removeTimeObserver(observer)
        }
        timeObserver = nil
        durationObserver?.invalidate()
        durationObserver = nil
    }
}

/// 全屏播放器视图
struct FullScreenPlayerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // 关闭按钮
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            if let url = appState.currentProject?.videoInfo.url {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

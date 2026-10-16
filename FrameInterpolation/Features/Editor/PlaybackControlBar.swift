import SwiftUI
import AVFoundation

/// 播放控制条：时间码显示 + 播放/暂停 + 撤销/重做 + 全屏
struct PlaybackControlBar: View {
    @EnvironmentObject var appState: AppState

    @State private var currentTime: TimeInterval = 0
    @State private var totalTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var isFrameMode = false

    private var fps: Double {
        appState.currentProject?.videoInfo.originalFPS ?? 30
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
                    // 全屏预览（暂未实现）
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
        .onDisappear { removePlayerObservers() }
    }

    private func togglePlayback() {
        PlayerManager.shared.togglePlayback()
        isPlaying.toggle()
    }

    private func setupPlayerObservers() {
        guard let player = PlayerManager.shared.player else { return }
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
        }
        if let item = player.currentItem {
            totalTime = CMTimeGetSeconds(item.duration)
        }
    }

    private func removePlayerObservers() {
        if let observer = timeObserver {
            PlayerManager.shared.removeTimeObserver(observer)
        }
        timeObserver = nil
    }
}

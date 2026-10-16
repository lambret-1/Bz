import SwiftUI
import AVFoundation
import AVKit

/// 播放控制条：时间码显示 + 播放/暂停 + 撤销/重做 + 全屏
/// 直接绑定 PlayerManager 的 @Published 属性，状态自动同步
struct PlaybackControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var playerManager = PlayerManager.shared
    @State private var isFrameMode = false
    @State private var showFullScreen = false

    private var fps: Double {
        appState.currentProject?.videoInfo.originalFPS ?? 30
    }

    /// 总时长：优先用 player 的 duration，未加载时用项目数据
    private var totalTime: TimeInterval {
        playerManager.duration > 0 ? playerManager.duration : (appState.currentProject?.videoInfo.duration ?? 0)
    }

    var body: some View {
        HStack {
            // 时间码/帧号显示
            TimecodeDisplay(
                currentFrame: Int(playerManager.currentTime * fps),
                totalFrames: Int(totalTime * fps),
                currentTime: playerManager.currentTime,
                totalTime: totalTime,
                isFrameMode: isFrameMode,
                thumbnail: nil
            )
            .onTapGesture {
                isFrameMode.toggle()
            }

            Spacer()

            // 播放/暂停（直接绑定 playerManager.isPlaying）
            Button {
                playerManager.togglePlayback()
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.topBarText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(playerManager.isPlaying ? "暂停" : "播放")

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
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPlayerView()
                .environmentObject(appState)
        }
    }
}

/// 全屏播放器视图
struct FullScreenPlayerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var playerManager = PlayerManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playerManager.player {
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
    }
}

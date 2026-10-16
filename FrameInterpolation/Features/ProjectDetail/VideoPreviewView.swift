import SwiftUI
import AVFoundation
import AVKit

/// 视频预览视图：16:9 比例，纯黑背景，底部半透明播放控制条
/// 点击画面切换播放/暂停，支持播放头时间绑定
struct VideoPreviewView: UIViewControllerRepresentable {
    let url: URL
    @Binding var currentTime: TimeInterval
    @Binding var isPlaying: Bool
    var onTimeUpdate: ((TimeInterval) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black

        let player = AVPlayer(url: url)
        controller.player = player

        // 监听播放结束
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        // 定期观察时间
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            context.coordinator.parent.currentTime = seconds
            context.coordinator.parent.onTimeUpdate?(seconds)
        }

        context.coordinator.player = player
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        guard let player = context.coordinator.player else { return }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.player = nil
    }

    // MARK: - 协调器
    final class Coordinator: NSObject {
        var parent: VideoPreviewView
        var player: AVPlayer?
        private var timeObserver: Any?

        init(_ parent: VideoPreviewView) {
            self.parent = parent
        }

        @objc func playerDidFinish() {
            parent.isPlaying = false
            parent.currentTime = 0
            player?.seek(to: .zero)
        }
    }
}

/// 视频预览容器：包含 AVPlayer 视图 + 自定义控制条
struct VideoPreviewContainer: View {
    let url: URL
    @Binding var currentTime: TimeInterval
    @Binding var isPlaying: Bool
    let duration: TimeInterval

    var body: some View {
        ZStack(alignment: .bottom) {
            // 视频画面（16:9）
            VideoPreviewView(url: url, currentTime: $currentTime, isPlaying: $isPlaying)
                .aspectRatio(16/9, contentMode: .fit)
                .background(DesignTokens.Colors.videoBackground)
                .onTapGesture {
                    isPlaying.toggle()
                }

            // 底部半透明控制条
            HStack(spacing: DesignTokens.Spacing.s) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? "暂停" : "播放")

                Text(TimeFormatter.format(currentTime))
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(.white)

                Text("/")
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(.white.opacity(0.6))

                Text(TimeFormatter.format(duration))
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.s)
            .frame(height: 44)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .cornerRadius(DesignTokens.Radius.m)
        .background(DesignTokens.Colors.videoBackground)
    }
}

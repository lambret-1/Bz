import SwiftUI
import AVFoundation
import AVKit
import Photos
import UIKit

/// 结果预览页（独立 NavigationStack，全屏展示）
/// 上下对比播放器 + 处理信息卡片 + 保存/分享/再次处理
struct ResultView: View {
    let outputURL: URL
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var originalPlayer: AVPlayer?
    @State private var processedPlayer: AVPlayer?
    @State private var isPlaying = false
    @State private var isSaving = false
    @State private var timeObserver: Any?
    @State private var shareAnchor: UIView?

    private var project: Project? { appState.currentProject }
    private var originalURL: URL? { project?.videoInfo.url }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // 对比播放器（上下排列，避免并排太小）
                    comparisonPlayer

                    // 处理信息卡片
                    processingInfoCard

                    // 操作按钮
                    actionButtons
                }
                .padding(DesignTokens.Spacing.m)
            }
            .background(DesignTokens.Colors.bgPrimary)
            .navigationTitle("处理结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                setupPlayers()
            }
            .onDisappear {
                cleanupPlayers()
            }
            // Toast
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                }
            }
        }
    }

    // MARK: - 对比播放器（上下排列）
    private var comparisonPlayer: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            // 原始
            VStack(spacing: 4) {
                Text("原始")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                CustomPlayerView(player: originalPlayer)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)
            }

            // 处理后
            VStack(spacing: 4) {
                Text("处理后")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundColor(DesignTokens.Colors.accent)
                CustomPlayerView(player: processedPlayer)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)
            }

            // 统一控制条
            HStack(spacing: DesignTokens.Spacing.m) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DesignTokens.Colors.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? "暂停" : "播放")

                Button {
                    seekToZero()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("重新播放")

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.s)
        }
        .padding(DesignTokens.Spacing.s)
        .background(DesignTokens.Colors.videoBackground)
        .cornerRadius(DesignTokens.Radius.m)
    }

    // MARK: - 处理信息卡片
    private var processingInfoCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                if let project = project {
                    // 原始信息
                    Text("原始")
                        .font(DesignTokens.Fonts.subheadline)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    Text("\(project.resolutionLabel) · \(project.fpsLabel)\(project.videoInfo.bitRateMbps > 0 ? " · \(String(format: "%.1f", project.videoInfo.bitRateMbps)) Mbps" : "")")
                        .font(DesignTokens.Fonts.body)
                        .foregroundColor(DesignTokens.Colors.textPrimary)

                    Divider()
                        .background(DesignTokens.Colors.border)

                    // 输出信息
                    Text("输出")
                        .font(DesignTokens.Fonts.subheadline)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    Text(outputDescription)
                        .font(DesignTokens.Fonts.body)
                        .foregroundColor(DesignTokens.Colors.accent)

                    Divider()
                        .background(DesignTokens.Colors.border)

                    // 已应用
                    Text("已应用：\(appliedEnhancements)")
                        .font(DesignTokens.Fonts.subheadline)
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                } else {
                    Text("处理完成")
                        .font(DesignTokens.Fonts.headline)
                }
            }
        }
    }

    private var outputDescription: String {
        guard let project = project else { return "未知" }
        var parts: [String] = []
        switch project.enhancement.mode {
        case .frameInterpolation:
            let outputFPS = Int(project.videoInfo.originalFPS) * project.enhancement.frameMultiplier.rawValue
            parts.append("\(project.resolutionLabel) · \(outputFPS)fps")
        case .superResolution:
            let width = project.videoInfo.width * 2
            let height = project.videoInfo.height * 2
            parts.append("\(width)×\(height) · \(project.fpsLabel)")
        case .none:
            parts.append("\(project.resolutionLabel) · \(project.fpsLabel)")
        }
        return parts.joined(separator: " · ")
    }

    private var appliedEnhancements: String {
        guard let project = project else { return "无" }
        var items: [String] = []
        switch project.enhancement.mode {
        case .frameInterpolation:
            items.append("补帧 \(project.enhancement.frameMultiplier.label)")
        case .superResolution:
            items.append("超分 \(project.enhancement.srModel.rawValue)")
        case .none:
            break
        }
        if project.enhancement.clarity.denoiseEnabled { items.append("降噪") }
        if project.enhancement.clarity.sharpenEnabled { items.append("锐化") }
        if project.enhancement.clarity.contrastEnabled { items.append("对比度") }
        if project.enhancement.clarity.colorEnabled { items.append("色彩") }
        if project.enhancement.audio.repairEnabled { items.append("音频修复") }
        return items.isEmpty ? "基础导出" : items.joined(separator: " + ")
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            HStack(spacing: DesignTokens.Spacing.m) {
                PrimaryButton(
                    title: isSaving ? "保存中…" : "保存到相册",
                    isLoading: isSaving
                ) {
                    saveToPhotoLibrary()
                }

                Button {
                    shareVideo()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(DesignTokens.Colors.bgSecondary)
                        .cornerRadius(DesignTokens.Radius.m)
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                }
                .accessibilityLabel("分享视频")
                .background(
                    // 用于iPad popover定位的隐藏锚点
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                shareAnchor = UIView()
                            }
                    }
                )
            }

            Button {
                // 再次处理：关闭结果页，回到编辑器
                dismiss()
            } label: {
                Text("再次处理")
                    .font(DesignTokens.Fonts.headline)
                    .foregroundColor(DesignTokens.Colors.accent)
                    .frame(height: DesignTokens.minTapArea)
            }
            .accessibilityLabel("再次处理")
        }
    }

    // MARK: - 播放器管理
    private func setupPlayers() {
        if let url = originalURL {
            originalPlayer = AVPlayer(url: url)
        }
        processedPlayer = AVPlayer(url: outputURL)

        // 同步播放：监听处理后播放器的时间，按比例同步到原始
        // 补帧后时长不变，但为了兼容性，按实际时长比例同步
        if let processedPlayer = processedPlayer {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = processedPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak originalPlayer, weak processedPlayer] time in
                guard let originalPlayer = originalPlayer,
                      let processedPlayer = processedPlayer else { return }

                let processedDuration = CMTimeGetSeconds(processedPlayer.currentItem?.duration ?? .zero)
                let originalDuration = CMTimeGetSeconds(originalPlayer.currentItem?.duration ?? .zero)

                guard processedDuration > 0, originalDuration > 0 else { return }

                // 按比例同步：原始时间 = 处理后时间 * (原始时长 / 处理后时长)
                let ratio = originalDuration / processedDuration
                let originalTime = CMTimeGetSeconds(time) * ratio
                let syncedTime = CMTime(seconds: originalTime, preferredTimescale: 600)
                originalPlayer.seek(to: syncedTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func cleanupPlayers() {
        if let observer = timeObserver, let player = processedPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        originalPlayer?.pause()
        processedPlayer?.pause()
        originalPlayer = nil
        processedPlayer = nil
        isPlaying = false
    }

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            originalPlayer?.play()
            processedPlayer?.play()
        } else {
            originalPlayer?.pause()
            processedPlayer?.pause()
        }
    }

    private func seekToZero() {
        originalPlayer?.seek(to: .zero)
        processedPlayer?.seek(to: .zero)
        if !isPlaying {
            isPlaying = true
            originalPlayer?.play()
            processedPlayer?.play()
        }
    }

    // MARK: - 保存到相册
    private func saveToPhotoLibrary() {
        isSaving = true

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        isSaving = false
                        if success {
                            appState.showToast("已保存到相册")
                        } else {
                            appState.showToast(error?.localizedDescription ?? "保存失败", style: .error)
                        }
                    }
                }
            case .denied, .restricted:
                DispatchQueue.main.async {
                    isSaving = false
                    appState.showToast("没有相册写入权限，请在设置中开启", style: .error)
                }
            case .notDetermined:
                DispatchQueue.main.async {
                    isSaving = false
                }
            @unknown default:
                DispatchQueue.main.async {
                    isSaving = false
                }
            }
        }
    }

    // MARK: - 分享
    private func shareVideo() {
        let activity = UIActivityViewController(
            activityItems: [outputURL],
            applicationActivities: nil
        )

        // iPad popover 定位：使用当前窗口的中心点
        if let popover = activity.popoverPresentationController {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.keyWindow {
                popover.sourceView = window
                popover.sourceRect = CGRect(
                    x: window.bounds.midX,
                    y: window.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.keyWindow?.rootViewController {
            root.present(activity, animated: true)
        }
    }
}

/// 自定义播放器视图（隐藏原生控制条，仅显示画面）
struct CustomPlayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player = player
    }
}

/// 播放器容器视图（使用 AVPlayerLayer，无原生控件）
final class PlayerContainerView: UIView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

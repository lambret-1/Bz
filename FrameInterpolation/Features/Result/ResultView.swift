import SwiftUI
import AVFoundation
import AVKit
import Photos
import UIKit

/// 结果预览页（独立 NavigationStack，全屏展示）
/// 左右对比播放器 + 处理信息卡片 + 保存/分享/再次处理
/// 左上角返回按钮 + 支持边缘左滑手势返回
struct ResultView: View {
    let outputURL: URL
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var originalPlayer: AVPlayer?
    @State private var processedPlayer: AVPlayer?
    @State private var isPlaying = false
    @State private var isSaving = false
    @State private var timeObserver: Any?

    private var project: Project? { appState.currentProject }
    private var originalURL: URL? { project?.videoInfo.url }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // 对比播放器
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
                        appState.outputURL = nil
                        appState.isProcessing = false
                        appState.closeProjectDetail()
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
                }
            }
        }
    }

    // MARK: - 对比播放器
    private var comparisonPlayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                // 原始
                VStack(spacing: 4) {
                    Text("原始")
                        .font(DesignTokens.Fonts.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    playerView(player: originalPlayer)
                }
                // 处理后
                VStack(spacing: 4) {
                    Text("处理后")
                        .font(DesignTokens.Fonts.caption)
                        .foregroundColor(DesignTokens.Colors.accent)
                    playerView(player: processedPlayer)
                }
            }
            .frame(maxWidth: .infinity)

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

    private func playerView(player: AVPlayer?) -> some View {
        VideoPlayer(player: player)
            .aspectRatio(16/9, contentMode: .fit)
            .disabled(true) // 禁用原生控制，使用统一控制
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
            }

            Button {
                appState.outputURL = nil
                appState.isProcessing = false
                // 回到项目详情页
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

        // 同步播放：监听处理后播放器的时间，同步到原始
        if let processedPlayer = processedPlayer {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = processedPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak originalPlayer] time in
                originalPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    appState.showToast("没有相册写入权限，请在设置中开启", style: .error)
                }
                return
            }

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
        }
    }

    // MARK: - 分享
    private func shareVideo() {
        let activity = UIActivityViewController(
            activityItems: [outputURL],
            applicationActivities: nil
        )

        if let popover = activity.popoverPresentationController {
            popover.sourceView = UIView()
            popover.sourceRect = CGRect(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.keyWindow?.rootViewController {
            root.present(activity, animated: true)
        }
    }
}

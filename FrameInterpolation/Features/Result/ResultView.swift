import SwiftUI
import AVKit
import Photos
import UIKit

/// 结果预览页（独立 NavigationStack，全屏展示）
/// 左上角返回按钮 + 支持边缘左滑手势返回
/// 提供视频预览、保存到相册、分享、返回首页功能
struct ResultView: View {
    let outputURL: URL
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var isSaving = false
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 可滚动内容区
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                        // 视频播放器（16:9 自适应）
                        CardView {
                            VideoPlayer(player: player)
                                .aspectRatio(16/9, contentMode: .fit)
                                .cornerRadius(DesignTokens.Radius.m)
                                .onAppear {
                                    player = AVPlayer(url: outputURL)
                                    player?.play()
                                }
                                .onDisappear {
                                    player?.pause()
                                }
                        }

                        // 文件信息
                        CardView {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                                infoRow("输出文件", outputURL.lastPathComponent)
                                Divider()
                                infoRow("处理状态", "处理完成", highlight: true)
                                Divider()
                                infoRow("当前模式", appState.processingMode.isEmpty ? "未知" : appState.processingMode)
                                Divider()
                                // 处理统计
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("处理统计")
                                        .font(.subheadline)
                                        .foregroundColor(DesignTokens.Colors.textSecondary)
                                    HStack {
                                        statItem("总耗时", formatDuration(appState.totalElapsedSeconds))
                                        Spacer()
                                        statItem("CPU平均", String(format: "%.0f%%", appState.cpuAverage))
                                        Spacer()
                                        statItem("CPU峰值", String(format: "%.0f%%", appState.cpuPeak))
                                    }
                                    HStack {
                                        statItem("内存平均", String(format: "%.0f MB", appState.memoryAverageMB))
                                        Spacer()
                                        statItem("内存峰值", String(format: "%.0f MB", appState.memoryPeakMB))
                                        Spacer()
                                        statItem("帧率", "\(appState.processedFrames)帧")
                                    }
                                }
                                if !appState.debugInfo.isEmpty {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("调试信息")
                                            .font(.subheadline)
                                            .foregroundColor(DesignTokens.Colors.textSecondary)
                                        Text(appState.debugInfo)
                                            .font(.caption.monospaced())
                                            .foregroundColor(DesignTokens.Colors.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("音频诊断")
                                        .font(.subheadline)
                                        .foregroundColor(DesignTokens.Colors.textSecondary)
                                    Text(VideoPipeline.音频诊断结果)
                                        .font(.caption.monospaced())
                                        .foregroundColor(DesignTokens.Colors.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.m)
                }

                // 底部固定操作区
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
                            Group {
                                if isSharing {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.title3)
                                }
                            }
                            .frame(width: 52, height: 52)
                            .background(DesignTokens.Colors.bgSecondary)
                            .cornerRadius(DesignTokens.Radius.m)
                        }
                        .disabled(isSharing || isSaving)
                        .accessibilityLabel("分享视频")
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.top, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.m)
                .background(DesignTokens.Colors.bgPrimary)
            }
            .background(DesignTokens.Colors.bgPrimary)
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("处理结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        // 关闭结果页，同时关闭处理页，回到参数设置页
                        appState.outputURL = nil
                        appState.isProcessing = false
                    }
                }
            }
        }
    }

    // MARK: - 信息行
    private func infoRow(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(highlight ? DesignTokens.Colors.accent : DesignTokens.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - 统计项
    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 格式化时长
    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1f秒", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)分\(secs)秒"
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
        isSharing = true
        let activity = UIActivityViewController(
            activityItems: [outputURL],
            applicationActivities: nil
        )
        activity.completionWithItemsHandler = { _, _, _, _ in
            isSharing = false
        }

        // iPad 适配：设置弹出来源
        if let popover = activity.popoverPresentationController {
            popover.sourceView = UIView()
            popover.sourceRect = CGRect(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        // 从顶层presentedViewController present，兼容fullScreenCover
        var topVC = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController

        while let presented = topVC?.presentedViewController {
            topVC = presented
        }

        if let topVC = topVC {
            topVC.present(activity, animated: true)
        } else {
            isSharing = false
        }
    }
}

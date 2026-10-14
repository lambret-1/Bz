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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // 视频播放器
                    CardView {
                        VideoPlayer(player: player)
                            .frame(height: 220)
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
                        VStack(spacing: DesignTokens.Spacing.s) {
                            infoRow("输出文件", outputURL.lastPathComponent)
                            Divider()
                            infoRow("处理状态", "处理完成", highlight: true)
                            Divider()
                            infoRow("当前模式", "空转管线（帧率不变）")
                        }
                    }

                    // 操作按钮
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
                        }
                        .accessibilityLabel("分享视频")
                    }

                    // 返回首页
                    Button {
                        appState.resetAll()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: "house.fill")
                            Text("返回首页")
                        }
                        .font(.subheadline)
                        .foregroundColor(DesignTokens.Colors.accent)
                    }
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

        // iPad 适配：设置弹出来源
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

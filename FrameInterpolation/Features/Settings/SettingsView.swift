import SwiftUI

/// 参数设置页（独立 NavigationStack，全屏展示）
/// 左上角返回按钮 + 支持边缘左滑手势返回（NavigationStack 原生支持）
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // 视频预览卡片
                    if let video = appState.selectedVideo {
                        videoPreviewCard(video: video)
                    }

                    // 补帧倍数
                    frameMultiplierSection

                    // 输出分辨率
                    resolutionSection

                    // 快速模式
                    fastModeCard

                    // 预估信息
                    estimatedInfoCard

                    Spacer(minLength: DesignTokens.Spacing.xl)
                }
                .padding(DesignTokens.Spacing.m)
            }
            .background(DesignTokens.Colors.bgPrimary)
            .navigationTitle("参数设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "开始补帧", isLoading: appState.isProcessing) {
                    appState.startProcessing()
                }
                .padding(DesignTokens.Spacing.m)
                .background(DesignTokens.Colors.bgPrimary)
            }
            // 处理中页（独立全屏，覆盖在设置页之上）
            .fullScreenCover(isPresented: $appState.isProcessing) {
                ProcessingView()
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - 视频预览卡片
    private func videoPreviewCard(video: VideoInfo) -> some View {
        CardView {
            VStack(spacing: DesignTokens.Spacing.s) {
                HStack(spacing: DesignTokens.Spacing.m) {
                    // 缩略图
                    if let thumbnail = video.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 45)
                            .clipped()
                            .cornerRadius(DesignTokens.Radius.s)
                    } else {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                            .fill(DesignTokens.Colors.bgTertiary)
                            .frame(width: 80, height: 45)
                            .overlay(
                                Image(systemName: "video.fill")
                                    .foregroundColor(DesignTokens.Colors.textSecondary)
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.fileName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("时长 \(formattedDuration(video.duration)) · 原始 \(Int(video.originalFPS))fps")
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                        Text("分辨率 \(video.width)×\(video.height)")
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    Text("原始大小 \(String(format: "%.1f", video.originalSizeMB)) MB")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text("预计输出 \(estimatedSize) MB")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.accent)
                }
            }
        }
    }

    // MARK: - 补帧倍数
    private var frameMultiplierSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("补帧倍数")
                .font(.headline)
            SegmentedPicker(
                items: FrameMultiplier.allCases,
                selection: $appState.frameMultiplier,
                label: { $0.label }
            )
            if appState.frameMultiplier == .x4 {
                Text("4x 仅 A16 及以上设备推荐使用")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.warning)
            }
        }
    }

    // MARK: - 输出分辨率
    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("输出分辨率")
                .font(.headline)
            SegmentedPicker(
                items: OutputResolution.allCases,
                selection: $appState.outputResolution,
                label: { $0.rawValue }
            )
        }
    }

    // MARK: - 快速模式
    private var fastModeCard: some View {
        CardView {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("快速模式")
                        .font(.headline)
                    Text("AI插值与帧混合交替，速度提升约40%")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $appState.fastMode)
                    .labelsHidden()
            }
        }
    }

    // MARK: - 预估信息
    private var estimatedInfoCard: some View {
        CardView {
            VStack(spacing: DesignTokens.Spacing.s) {
                infoRow("预计耗时", value: estimatedTime)
                Divider()
                infoRow("预计输出大小", value: "\(estimatedSize) MB")
                Divider()
                infoRow("输出帧率", value: outputFPS)
            }
        }
    }

    // MARK: - 辅助方法
    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var estimatedSize: String {
        guard let video = appState.selectedVideo else { return "0" }
        let base = video.originalSizeMB
        let multiplier = Double(appState.frameMultiplier.rawValue) / 2.0
        let resolutionFactor: Double = appState.outputResolution == .p1080 ? 1.5 : 1.0
        return String(format: "%.0f", base * multiplier * resolutionFactor)
    }

    private var estimatedTime: String {
        guard let video = appState.selectedVideo else { return "约 0 秒" }
        // 空转管线预估：约视频时长的 0.3 倍
        let base = video.duration * 0.3
        let resolutionFactor: Double = appState.outputResolution == .p1080 ? 1.5 : 1.0
        let fastFactor: Double = appState.fastMode ? 0.4 : 1.0
        let seconds = base * resolutionFactor * fastFactor
        if seconds < 60 { return String(format: "约 %.0f 秒", seconds) }
        return String(format: "约 %.1f 分钟", seconds / 60)
    }

    private var outputFPS: String {
        guard let video = appState.selectedVideo else { return "60fps" }
        let fps = Int(video.originalFPS) * appState.frameMultiplier.rawValue
        return "\(fps)fps"
    }
}

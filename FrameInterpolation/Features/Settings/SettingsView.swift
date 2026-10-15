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
                    Text("静态画面自动帧混合，运动画面AI插值")
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
        let n = appState.frameMultiplier.rawValue
        let usingAI = appState.isUsingAI

        // 基础系数：优先用本机实测速度系数，无实测时用默认值
        // 实测系数 = 视频时长/实际耗时，越大越快；预估耗时 = 视频时长/速度系数
        let defaultSpeed: Double = usingAI ? 0.8 : 3.0 // AI约0.8倍速，空转约3倍速
        let speedFactor = appState.measuredSpeedFactor ?? defaultSpeed
        var base = video.duration / speedFactor

        // 倍数系数：4x递归3次推理，工作量约为2x的1.5倍
        let multFactor = n == 2 ? 1.0 : 1.5
        base *= multFactor

        // 分辨率：720p比1080p快约40%，1080p比原始慢约30%
        switch appState.outputResolution {
        case .p720: base *= 0.6
        case .p1080: base *= 1.3
        case .auto: break
        }

        // 快速模式：静态帧走GPU blend，实际加速约1.4倍
        if appState.fastMode { base /= 1.4 }

        let seconds = max(base, 1)
        if seconds < 60 { return String(format: "约 %.0f 秒", seconds) }
        return String(format: "约 %.1f 分钟", seconds / 60)
    }

    private var outputFPS: String {
        guard let video = appState.selectedVideo else { return "60fps" }
        let fps = Int(video.originalFPS) * appState.frameMultiplier.rawValue
        return "\(fps)fps"
    }
}

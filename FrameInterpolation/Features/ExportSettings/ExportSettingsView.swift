import SwiftUI

/// 导出设置页（独立 NavigationStack，全屏展示）
/// 视频编码、码率模式、容器格式、音频模式、预计输出实时计算
/// 左上角返回按钮 + 支持边缘左滑手势返回
struct ExportSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var project: Project? { appState.currentProject }
    private var settings: ExportSettings {
        project?.exportSettings ?? ExportSettings()
    }

    var body: some View {
        NavigationStack {
            List {
                // 视频编码
                Section("视频编码") {
                    Picker("编码格式", selection: Binding(
                        get: { settings.codec },
                        set: { newValue in updateSettings { $0.codec = newValue } }
                    )) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("码率模式", selection: Binding(
                        get: { settings.bitrateMode },
                        set: { newValue in updateSettings { $0.bitrateMode = newValue } }
                    )) {
                        ForEach(BitrateMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 容器格式
                Section("容器格式") {
                    Picker("容器", selection: Binding(
                        get: { settings.container },
                        set: { newValue in updateSettings { $0.container = newValue } }
                    )) {
                        ForEach(ContainerFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 音频
                Section("音频") {
                    Picker("音频处理", selection: Binding(
                        get: { settings.audioMode },
                        set: { newValue in updateSettings { $0.audioMode = newValue } }
                    )) {
                        ForEach(AudioMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 预计输出
                Section("预计输出") {
                    estimatedOutputContent
                }
            }
            .background(DesignTokens.Colors.bgPrimary)
            .scrollContentBackground(.hidden)
            .navigationTitle("导出设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    resetToDefault()
                } label: {
                    Text("重置为默认")
                        .font(DesignTokens.Fonts.headline)
                        .foregroundColor(DesignTokens.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: DesignTokens.buttonHeight)
                }
                .background(DesignTokens.Colors.bgPrimary)
            }
        }
    }

    // MARK: - 预计输出内容
    private var estimatedOutputContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            InfoRow(title: "分辨率", value: estimatedResolution)
            InfoRow(title: "帧率", value: estimatedFPS)
            InfoRow(title: "码率", value: estimatedBitrate)
            InfoRow(title: "文件大小", value: estimatedFileSize, highlight: true)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var estimatedResolution: String {
        guard let project = project else { return "未知" }
        switch project.enhancement.mode {
        case .superResolution:
            let width = project.videoInfo.width * 2
            let height = project.videoInfo.height * 2
            return "\(width)×\(height)"
        default:
            return project.resolutionLabel
        }
    }

    private var estimatedFPS: String {
        guard let project = project else { return "未知" }
        switch project.enhancement.mode {
        case .frameInterpolation:
            let fps = Int(project.videoInfo.originalFPS) * project.enhancement.frameMultiplier.rawValue
            return "\(fps)fps"
        default:
            return project.fpsLabel
        }
    }

    private var estimatedBitrate: String {
        guard let project = project else { return "未知" }
        let baseBitrate = max(project.videoInfo.bitRateMbps, 2.0)
        var factor = settings.bitrateMode.factor

        // 超分分辨率翻倍，码率约 ×2
        if project.enhancement.mode == .superResolution {
            factor *= 2.0
        }
        // 补帧帧率翻倍，码率约 ×1.3
        if project.enhancement.mode == .frameInterpolation {
            factor *= 1.3
        }

        let bitrate = baseBitrate * factor
        return String(format: "%.1f Mbps", bitrate)
    }

    private var estimatedFileSize: String {
        guard let project = project else { return "未知" }
        let duration = project.totalDuration
        let baseBitrate = max(project.videoInfo.bitRateMbps, 2.0)
        var factor = settings.bitrateMode.factor
        if project.enhancement.mode == .superResolution { factor *= 2.0 }
        if project.enhancement.mode == .frameInterpolation { factor *= 1.3 }

        let bitrateMbps = baseBitrate * factor
        // 文件大小 MB = 码率 Mbps × 时长 s / 8
        let sizeMB = bitrateMbps * duration / 8.0
        if sizeMB < 1 {
            return String(format: "%.0f KB", sizeMB * 1024)
        }
        return String(format: "约 %.0f MB", sizeMB)
    }

    // MARK: - 操作
    private func updateSettings(_ mutation: (inout ExportSettings) -> Void) {
        guard let project = project else { return }
        var updated = project.exportSettings
        mutation(&updated)
        appState.updateExportSettings(updated)
    }

    private func resetToDefault() {
        let defaults = ExportSettings(
            codec: appState.defaultCodec,
            bitrateMode: appState.defaultBitrateMode,
            container: appState.defaultContainer,
            audioMode: .passthrough
        )
        appState.updateExportSettings(defaults)
        appState.showToast("已重置为默认设置", style: .warning)
    }
}

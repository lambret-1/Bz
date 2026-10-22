import SwiftUI

/// 参数设置页（独立 NavigationStack，全屏展示）
/// 左上角返回按钮 + 支持边缘左滑手势返回（NavigationStack 原生支持）
/// 支持补帧与超分两种互斥模式，超分模式下可选择 Fast-SRGAN / Real-ESRGAN 引擎
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 当前是否为超分模式
    private var isSuperResolutionMode: Bool {
        if case .superResolution = appState.selectedMode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // 视频预览卡片
                    if let video = appState.selectedVideo {
                        videoPreviewCard(video: video)
                    }

                    // 处理模式选择（补帧 / 超分，互斥）
                    processingModeSection

                    // 补帧模式专属参数
                    if !isSuperResolutionMode {
                        frameMultiplierSection
                        fastModeCard
                    }

                    // 超分模式专属参数
                    if isSuperResolutionMode {
                        superResolutionEngineSection
                    }

                    // 输出分辨率（两种模式共用）
                    resolutionSection

                    // 预估信息
                    estimatedInfoCard

                    // 日志查看入口
                    NavigationLink(destination: LogViewerView()) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(DesignTokens.Colors.accent)
                            Text("查看运行日志")
                                .foregroundColor(DesignTokens.Colors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                        .padding(DesignTokens.Spacing.m)
                        .background(DesignTokens.Colors.bgSecondary)
                        .cornerRadius(DesignTokens.Radius.s)
                    }

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
                PrimaryButton(title: startButtonTitle, isLoading: appState.isProcessing) {
                    // 先关闭设置页，等待全屏盖层消失后再启动处理
                    // 避免与 HomeView 的 fullScreenCover 同时弹出导致冲突崩溃
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.startProcessing()
                    }
                }
                .padding(DesignTokens.Spacing.m)
                .background(DesignTokens.Colors.bgPrimary)
            }
        }
    }

    // MARK: - 开始按钮标题

    private var startButtonTitle: String {
        isSuperResolutionMode ? "开始超分" : "开始补帧"
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
                        Text("\(video.codecFormat) · \(Int(video.width))×\(video.height)\(video.bitRateMbps > 0 ? " · \(String(format: "%.1f", video.bitRateMbps)) Mbps" : "")")
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

    // MARK: - 处理模式选择

    private var processingModeSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("处理模式")
                .font(.headline)

            HStack(spacing: DesignTokens.Spacing.m) {
                // 补帧模式卡片
                modeCard(
                    title: "补帧",
                    subtitle: "让画面更流畅",
                    icon: "film",
                    isSelected: !isSuperResolutionMode
                ) {
                    appState.selectedMode = .interpolation(appState.frameMultiplier)
                }

                // 超分模式卡片
                modeCard(
                    title: "超分",
                    subtitle: "让画面更清晰",
                    icon: "sparkles",
                    isSelected: isSuperResolutionMode
                ) {
                    appState.selectedMode = .superResolution(appState.superResolutionEngine, appState.superResolutionScale)
                }
            }
        }
    }

    /// 模式选择卡片
    private func modeCard(title: String, subtitle: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(isSelected ? .white : DesignTokens.Colors.textSecondary)
                Text(title)
                    .font(.headline)
                    .foregroundColor(isSelected ? .white : DesignTokens.Colors.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : DesignTokens.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.m)
                    .fill(isSelected ? DesignTokens.Colors.accent : DesignTokens.Colors.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.m)
                    .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
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

    // MARK: - 超分引擎选择

    private var superResolutionEngineSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("超分引擎")
                .font(.headline)

            ForEach(SuperResolutionEngineType.allCases) { engine in
                engineRow(engine: engine)
            }
        }
    }

    /// 超分引擎选择行
    private func engineRow(engine: SuperResolutionEngineType) -> some View {
        let isSelected = appState.superResolutionEngine == engine
        return Button {
            appState.superResolutionEngine = engine
            appState.selectedMode = .superResolution(engine, appState.superResolutionScale)
        } label: {
            HStack(spacing: DesignTokens.Spacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                    Text(engine.engineDescription)
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                Spacer()
            }
            .padding(.vertical, DesignTokens.Spacing.s)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                    .fill(isSelected ? DesignTokens.Colors.accent.opacity(0.1) : DesignTokens.Colors.bgSecondary)
            )
        }
        .buttonStyle(.plain)
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
            if isSuperResolutionMode {
                Text("超分模式下自动放大分辨率，此选项用于限制最大输出高度")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
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
                if isSuperResolutionMode {
                    Divider()
                    infoRow("输出分辨率", value: outputResolutionText)
                }
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

        if isSuperResolutionMode {
            // 超分模式：分辨率提升，数据量增加，帧率不变
            let scaleFactor = Double(appState.superResolutionScale.rawValue)
            let resolutionFactor: Double = appState.outputResolution == .p1080 ? 1.0 : (appState.outputResolution == .p720 ? 0.5 : scaleFactor)
            return String(format: "%.0f", base * resolutionFactor * 1.5)
        } else {
            // 补帧模式：帧率提升
            let multiplier = Double(appState.frameMultiplier.rawValue) / 2.0
            let resolutionFactor: Double = appState.outputResolution == .p1080 ? 1.5 : 1.0
            return String(format: "%.0f", base * multiplier * resolutionFactor)
        }
    }

    private var estimatedTime: String {
        guard let video = appState.selectedVideo else { return "约 0 秒" }

        if isSuperResolutionMode {
            // 超分模式耗时估算
            if appState.superResolutionScale == .x1 {
                // 1x 模式不执行 AI 推理，仅复制帧，速度极快
                let seconds = max(video.duration / 10.0, 1)
                if seconds < 60 { return String(format: "约 %.0f 秒", seconds) }
                return String(format: "约 %.1f 分钟", seconds / 60)
            }

            let defaultSpeed: Double = appState.superResolutionEngine == .fastSRGAN ? 1.0 : 0.3
            let speedFactor = appState.measuredSpeedFactor ?? defaultSpeed
            var base = video.duration / speedFactor

            // Real-ESRGAN 瓦片拼接较慢
            if appState.superResolutionEngine == .realESRGAN {
                base *= 2.5
            }

            // 分辨率限制
            switch appState.outputResolution {
            case .p720: base *= 0.7
            case .p1080: base *= 1.2
            case .auto: break
            }

            let seconds = max(base, 1)
            if seconds < 60 { return String(format: "约 %.0f 秒", seconds) }
            return String(format: "约 %.1f 分钟", seconds / 60)
        } else {
            // 补帧模式耗时估算（原有逻辑）
            let n = appState.frameMultiplier.rawValue
            let usingAI = appState.isUsingAI
            let defaultSpeed: Double = usingAI ? 0.8 : 3.0
            let speedFactor = appState.measuredSpeedFactor ?? defaultSpeed
            var base = video.duration / speedFactor

            let multFactor = n == 2 ? 1.0 : 1.5
            base *= multFactor

            switch appState.outputResolution {
            case .p720: base *= 0.6
            case .p1080: base *= 1.3
            case .auto: break
            }

            if appState.fastMode { base /= 1.4 }

            let seconds = max(base, 1)
            if seconds < 60 { return String(format: "约 %.0f 秒", seconds) }
            return String(format: "约 %.1f 分钟", seconds / 60)
        }
    }

    private var outputFPS: String {
        guard let video = appState.selectedVideo else { return "60fps" }
        if isSuperResolutionMode {
            // 超分模式帧率不变
            return "\(Int(video.originalFPS))fps（保持不变）"
        } else {
            let fps = Int(video.originalFPS) * appState.frameMultiplier.rawValue
            return "\(fps)fps"
        }
    }

    private var outputResolutionText: String {
        guard let video = appState.selectedVideo else { return "—" }
        let scale = appState.superResolutionScale.rawValue
        var outWidth = video.width * scale
        var outHeight = video.height * scale

        // 应用输出分辨率限制（按短边，自动识别横竖屏）
        switch appState.outputResolution {
        case .auto:
            break
        case .p720:
            let currentShort = min(outWidth, outHeight)
            if currentShort > 720 {
                let s = 720.0 / Double(currentShort)
                outWidth = Int(Double(outWidth) * s)
                outHeight = Int(Double(outHeight) * s)
            }
        case .p1080:
            let currentShort = min(outWidth, outHeight)
            if currentShort > 1080 {
                let s = 1080.0 / Double(currentShort)
                outWidth = Int(Double(outWidth) * s)
                outHeight = Int(Double(outHeight) * s)
            }
        }

        // 确保偶数
        outWidth = outWidth - (outWidth % 2)
        outHeight = outHeight - (outHeight % 2)

        return "\(outWidth)×\(outHeight)"
    }
}

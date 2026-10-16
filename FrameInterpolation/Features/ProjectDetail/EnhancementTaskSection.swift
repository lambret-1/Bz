import SwiftUI

/// 增强任务区域：互斥组（补帧/超分）+ 清晰度增强折叠区 + 音频修复
struct EnhancementTaskSection: View {
    @EnvironmentObject var appState: AppState
    @State private var clarityExpanded = false

    private var enhancement: EnhancementConfig {
        appState.currentProject?.enhancement ?? EnhancementConfig()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            // 标题
            Text("视频增强")
                .font(DesignTokens.Fonts.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)

            // 互斥组
            VStack(spacing: DesignTokens.Spacing.s) {
                enhancementCard(
                    mode: .frameInterpolation,
                    icon: "timeline.selection",
                    title: "补帧",
                    isSelected: enhancement.mode == .frameInterpolation
                ) {
                    appState.setEnhancementMode(.frameInterpolation)
                } content: {
                    SegmentedPicker(
                        items: FrameMultiplier.allCases,
                        selection: Binding(
                            get: { enhancement.frameMultiplier },
                            set: { appState.setFrameMultiplier($0) }
                        ),
                        label: { $0.label }
                    )
                    .frame(width: 120)
                }

                enhancementCard(
                    mode: .superResolution,
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: "超分",
                    isSelected: enhancement.mode == .superResolution
                ) {
                    appState.setEnhancementMode(.superResolution)
                } content: {
                    SegmentedPicker(
                        items: SuperResolutionModel.allCases,
                        selection: Binding(
                            get: { enhancement.srModel },
                            set: { appState.setSuperResolutionModel($0) }
                        ),
                        label: { $0.rawValue }
                    )
                    .frame(width: 200)
                }
            }

            // 互斥提示
            if enhancement.mode != .none {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("补帧与超分无法同时使用，切换将取消当前选择")
                        .font(DesignTokens.Fonts.caption)
                }
                .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            // 清晰度增强折叠区
            CardView {
                VStack(spacing: 0) {
                    CollapsibleSectionHeader(title: "清晰度增强", isExpanded: $clarityExpanded)

                    if clarityExpanded {
                        clarityContent
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            // 音频修复
            CardView {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(DesignTokens.Colors.accent)
                            Text("音频修复")
                                .font(DesignTokens.Fonts.headline)
                        }
                        Text("保持原始音频，修复容器兼容问题")
                            .font(DesignTokens.Fonts.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { enhancement.audio.repairEnabled },
                        set: { appState.toggleAudioRepair($0) }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - 增强卡片
    private func enhancementCard<Content: View>(
        mode: EnhancementMode,
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.m) {
                // 单选圆圈
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.subheadline)
                        Text(title)
                            .font(DesignTokens.Fonts.headline)
                    }
                    .foregroundColor(DesignTokens.Colors.textPrimary)

                    if isSelected {
                        content()
                    }
                }

                Spacer()
            }
            .padding(DesignTokens.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.m)
                    .fill(isSelected ? DesignTokens.Colors.accent.opacity(0.1) : DesignTokens.Colors.bgTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.m)
                    .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(isSelected ? "，已选中" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 清晰度内容
    private var clarityContent: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            claritySliderRow(
                title: "降噪",
                icon: "wind",
                isEnabled: Binding(
                    get: { enhancement.clarity.denoiseEnabled },
                    set: { newValue in appState.updateClarity { $0.denoiseEnabled = newValue } }
                ),
                value: Binding(
                    get: { enhancement.clarity.denoiseIntensity },
                    set: { newValue in appState.updateClarity { $0.denoiseIntensity = newValue } }
                ),
                range: 0.0...1.0,
                format: "%.1f"
            )

            claritySliderRow(
                title: "锐化",
                icon: "dial.medium",
                isEnabled: Binding(
                    get: { enhancement.clarity.sharpenEnabled },
                    set: { newValue in appState.updateClarity { $0.sharpenEnabled = newValue } }
                ),
                value: Binding(
                    get: { enhancement.clarity.sharpenIntensity },
                    set: { newValue in appState.updateClarity { $0.sharpenIntensity = newValue } }
                ),
                range: 0.0...1.0,
                format: "%.1f"
            )

            claritySliderRow(
                title: "对比度",
                icon: "circle.lefthalf.filled",
                isEnabled: Binding(
                    get: { enhancement.clarity.contrastEnabled },
                    set: { newValue in appState.updateClarity { $0.contrastEnabled = newValue } }
                ),
                value: Binding(
                    get: { enhancement.clarity.contrastIntensity },
                    set: { newValue in appState.updateClarity { $0.contrastIntensity = newValue } }
                ),
                range: 0.8...1.5,
                format: "%.1f"
            )

            claritySliderRow(
                title: "色彩",
                icon: "paintpalette",
                isEnabled: Binding(
                    get: { enhancement.clarity.colorEnabled },
                    set: { newValue in appState.updateClarity { $0.colorEnabled = newValue } }
                ),
                value: Binding(
                    get: { enhancement.clarity.colorIntensity },
                    set: { newValue in appState.updateClarity { $0.colorIntensity = newValue } }
                ),
                range: 0.5...1.5,
                format: "%.2f"
            )
        }
        .padding(.top, DesignTokens.Spacing.s)
    }

    private func claritySliderRow(
        title: String,
        icon: String,
        isEnabled: Binding<Bool>,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(DesignTokens.Fonts.subheadline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
            }

            HStack(spacing: DesignTokens.Spacing.s) {
                Slider(value: value, in: range)
                    .tint(DesignTokens.Colors.accent)
                    .disabled(!isEnabled.wrappedValue)
                    .opacity(isEnabled.wrappedValue ? 1.0 : 0.4)

                Text(String(format: format, value.wrappedValue))
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 45, alignment: .trailing)
            }
        }
    }
}

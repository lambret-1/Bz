import SwiftUI

// MARK: - 主按钮
/// 高度 52pt，圆角 12pt，强调色背景
/// 按下态：opacity 0.8 + scale 0.98；禁用态：accent 30% + textSecondary；加载态：左侧 ProgressView
struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if isLoading {
                    ProgressView().tint(.white)
                }
                Text(title)
                    .font(DesignTokens.Fonts.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.buttonHeight)
            .background(
                isDisabled || isLoading
                ? DesignTokens.Colors.accent.opacity(0.3)
                : DesignTokens.Colors.accent
            )
            .foregroundColor(isDisabled || isLoading ? DesignTokens.Colors.textSecondary : .white)
            .cornerRadius(DesignTokens.Radius.m)
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// 主按钮按下态样式
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 卡片容器
/// 背景 bgSecondary，圆角 16pt，内边距 16pt
/// 深色模式无阴影，浅色模式阴影 black.opacity(0.06), radius 8, y 2
struct CardView<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(DesignTokens.Spacing.m)
            .background(DesignTokens.Colors.bgSecondary)
            .cornerRadius(DesignTokens.Radius.l)
            .shadow(
                color: colorScheme == .light ? .black.opacity(0.06) : .clear,
                radius: 8, y: 2
            )
    }
}

// MARK: - Toast 提示
/// 顶部滑入，2 秒后自动消失，支持成功/错误/警告三种样式
struct ToastView: View {
    let message: String
    let style: ToastStyle

    private var iconName: String {
        switch style {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch style {
        case .success: return DesignTokens.Colors.success
        case .error: return DesignTokens.Colors.error
        case .warning: return DesignTokens.Colors.warning
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            Text(message)
                .font(DesignTokens.Fonts.subheadline)
                .foregroundColor(DesignTokens.Colors.textPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s + 4)
        .background(DesignTokens.Colors.bgSecondary)
        .cornerRadius(DesignTokens.Radius.m)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

// MARK: - 分段选择控件
/// 高度 36pt，背景 bgTertiary，选中项强调色背景，支持泛型类型
struct SegmentedPicker<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = item
                    }
                } label: {
                    Text(label(item))
                        .font(DesignTokens.Fonts.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            selection == item
                            ? DesignTokens.Colors.accent
                            : Color.clear
                        )
                        .foregroundColor(
                            selection == item ? .white : DesignTokens.Colors.textPrimary
                        )
                        .cornerRadius(DesignTokens.Radius.s)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(DesignTokens.Colors.bgTertiary)
        .cornerRadius(DesignTokens.Radius.m)
    }
}

// MARK: - 环形进度视图
/// 外径 160pt，线宽 12pt，渐变色进度环，中心显示百分比与帧数
/// 唯一进度条，不在下方重复显示百分比
struct RingProgressView: View {
    let progress: Double
    let processedFrames: Int
    let totalFrames: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(DesignTokens.Colors.bgTertiary, lineWidth: DesignTokens.ringLineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1.0)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [DesignTokens.Colors.accent, .cyan]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: DesignTokens.ringLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)

            VStack(spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                if totalFrames > 0 {
                    Text("\(processedFrames) / \(totalFrames) 帧")
                        .font(DesignTokens.Fonts.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
        }
        .frame(width: DesignTokens.ringDiameter, height: DesignTokens.ringDiameter)
    }
}

// MARK: - 空状态视图
/// 大图标 64pt + 标题 + 副文案 + 可选操作按钮
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Text(title)
                .font(DesignTokens.Fonts.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)
            Text(subtitle)
                .font(DesignTokens.Fonts.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle = actionTitle, let action = action {
                PrimaryButton(title: actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }
}

// MARK: - 任务标签
/// 圆角 6pt，内边距 6×12，字号 caption2，白色文字，颜色按任务类型区分
struct TaskTag: View {
    let type: TaskTagType

    var body: some View {
        Text(type.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(type.color)
            .cornerRadius(6)
    }
}

// MARK: - 带触觉反馈的按钮包装
/// 点击时触发 UIImpactFeedbackGenerator(.light)
struct HapticButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    private let generator = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Button {
            generator.impactOccurred()
            action()
        } label: {
            label()
        }
    }
}

// MARK: - 折叠区标题
/// 高 44pt，点击展开/收起，带 chevron 动画
struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text(title)
                    .font(DesignTokens.Fonts.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(DesignTokens.Fonts.subheadline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.3), value: isExpanded)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起\(title)" : "展开\(title)")
    }
}

// MARK: - 信息行
/// 左标题右值的信息展示行
struct InfoRow: View {
    let title: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(DesignTokens.Fonts.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Fonts.subheadline.weight(.medium))
                .foregroundColor(highlight ? DesignTokens.Colors.accent : DesignTokens.Colors.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 工具栏按钮
/// 编辑工具栏中的图标+文字按钮，支持禁用态
struct ToolbarActionButton: View {
    let icon: String
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(width: 80, height: 56)
            .foregroundColor(isDisabled ? DesignTokens.Colors.textSecondary.opacity(0.4) : DesignTokens.Colors.textPrimary)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

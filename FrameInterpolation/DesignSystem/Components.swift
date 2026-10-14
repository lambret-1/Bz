import SwiftUI

// MARK: - 主按钮
/// 高度 52pt，圆角 12pt，强调色背景，支持加载态与禁用态
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
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.buttonHeight)
            .background(
                isDisabled || isLoading
                ? DesignTokens.Colors.accent.opacity(0.3)
                : DesignTokens.Colors.accent
            )
            .foregroundColor(.white)
            .cornerRadius(DesignTokens.Radius.m)
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(.plain)
    }
}

// MARK: - 卡片容器
/// 背景 bgSecondary，圆角 16pt，内边距 16pt
struct CardView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(DesignTokens.Spacing.m)
            .background(DesignTokens.Colors.bgSecondary)
            .cornerRadius(DesignTokens.Radius.l)
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
                .font(.subheadline)
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
                        .font(.subheadline.weight(.medium))
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
struct RingProgressView: View {
    let progress: Double
    let processedFrames: Int
    let totalFrames: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(DesignTokens.Colors.bgTertiary, lineWidth: 12)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [DesignTokens.Colors.accent, .cyan]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)

            VStack(spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                if totalFrames > 0 {
                    Text("已处理 \(processedFrames) / \(totalFrames) 帧")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
        }
        .frame(width: 160, height: 160)
    }
}

// MARK: - 空状态视图
/// 大图标 + 标题 + 副文案 + 可选操作按钮
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
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle = actionTitle, let action = action {
                PrimaryButton(title: actionTitle, action: action)
                    .frame(maxWidth: 240)
            }
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

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

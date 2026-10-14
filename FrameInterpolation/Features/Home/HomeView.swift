import SwiftUI

/// 首页：导入卡片 + 最近记录（阶段0为最小闭环，仅展示导入卡片与 Toast 验证）
struct HomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                // 顶部标题
                HStack {
                    Text("补帧")
                        .font(.largeTitle.bold())
                    Spacer()
                }

                // 导入卡片
                CardView {
                    VStack(spacing: DesignTokens.Spacing.m) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(DesignTokens.Colors.accent)

                        Text("导入视频开始补帧")
                            .font(.headline)

                        Text("支持 30fps → 60fps，完全本地处理")
                            .font(.subheadline)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .multilineTextAlignment(.center)

                        PrimaryButton(title: "从相册选择") {
                            // 阶段0：验证构建闭环，弹出 Toast
                            appState.showToast("构建成功，工程底座已就绪", style: .success)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(DesignTokens.Spacing.m)
        }
        .background(DesignTokens.Colors.bgPrimary)
        .overlay(alignment: .top) {
            if let message = appState.toastMessage {
                ToastView(message: message, style: appState.toastStyle)
                    .padding(.top, DesignTokens.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

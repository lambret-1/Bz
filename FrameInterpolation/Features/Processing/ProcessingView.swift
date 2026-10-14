import SwiftUI
import UIKit

/// 处理中页（独立全屏，禁止手势返回防止误触取消）
/// 左上角取消按钮 + 防息屏 + 热状态提示
/// 处理完成后自动全屏展示结果页
struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            // 顶部栏：取消按钮
            HStack {
                Button {
                    showCancelConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .frame(width: DesignTokens.minTapArea, height: DesignTokens.minTapArea)
                }
                .accessibilityLabel("取消处理")
                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.m)

            Spacer()

            // 环形进度
            RingProgressView(
                progress: appState.progress,
                processedFrames: appState.processedFrames,
                totalFrames: appState.totalFrames
            )

            // 状态文案
            Text(appState.stage.rawValue)
                .font(.headline)

            // 进度百分比
            Text("\(Int(appState.progress * 100))%")
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundColor(DesignTokens.Colors.accent)

            Spacer()

            // 提示条
            HStack(spacing: DesignTokens.Spacing.s) {
                Image(systemName: "thermometer.high")
                    .foregroundColor(DesignTokens.Colors.warning)
                Text("处理期间请保持 App 在前台，屏幕将保持常亮")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.bottom, DesignTokens.Spacing.l)
        }
        .background(DesignTokens.Colors.bgPrimary)
        // 禁止手势返回，防止处理中误触
        .interactiveDismissDisabled()
        // 防息屏
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 取消确认弹窗
        .confirmationDialog("确定要取消吗？", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("取消并退出", role: .destructive) {
                appState.cancelProcessing()
                dismiss()
            }
            Button("继续处理", role: .cancel) {}
        } message: {
            Text("已处理的部分将被丢弃，无法恢复。")
        }
        // 处理完成后展示结果页（独立全屏，覆盖在处理页之上）
        .fullScreenCover(isPresented: Binding(
            get: { appState.outputURL != nil },
            set: { if !$0 { appState.outputURL = nil } }
        )) {
            if let url = appState.outputURL {
                ResultView(outputURL: url)
                    .environmentObject(appState)
            }
        }
    }
}

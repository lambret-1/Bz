import SwiftUI
import UIKit

/// 处理中页（独立全屏，禁止手势返回防止误触取消）
/// 左上角回首页+取消按钮 + 防息屏 + 热状态提示
/// 后台任务统一由 AppState 管理，处理全程持有（包括最小化到首页）
/// 处理完成后自动全屏展示结果页
struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            // 顶部栏：回首页 + 取消
            HStack {
                Button {
                    appState.minimizeProcessing()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "house")
                        Text("回首页")
                    }
                    .font(.subheadline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(height: DesignTokens.minTapArea)
                }
                .accessibilityLabel("最小化到首页")

                Spacer()

                Button {
                    showCancelConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .frame(width: DesignTokens.minTapArea, height: DesignTokens.minTapArea)
                }
                .accessibilityLabel("取消处理")
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

            // 预计剩余时间
            if appState.estimatedRemaining > 1 {
                Text("预计剩余时间：约 \(Int(appState.estimatedRemaining)) 秒")
                    .font(.subheadline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }



            Spacer()

            // 提示条，
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
        // 防息屏（后台任务由AppState统一管理）
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

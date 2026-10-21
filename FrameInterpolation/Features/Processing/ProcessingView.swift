import SwiftUI
import UIKit

/// 处理中页（独立全屏，禁止手势返回防止误触取消）
/// 修复了刘海屏/灵动岛遮挡问题
struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false

    var body: some View {
        // 核心内容（去掉了原本放在最顶部的 HStack）
        VStack(spacing: DesignTokens.Spacing.l) {
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

            // CPU 和内存监控
            HStack(spacing: DesignTokens.Spacing.xl) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundColor(cpuColor)
                    Text(String(format: "CPU %.0f%%", appState.performanceMonitor.cpuUsage))
                        .font(.caption.weight(.medium))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption)
                        .foregroundColor(memoryColor)
                    Text(String(format: "内存 %.0f MB", appState.performanceMonitor.memoryUsageMB))
                        .font(.caption.weight(.medium))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 修复 1：让背景色铺满全屏（包括刘海和底部黑条）
        .background(DesignTokens.Colors.bgPrimary.ignoresSafeArea())
        // 修复 2：利用 safeAreaInset 将顶部栏安全地固定在刘海下方
        .safeAreaInset(edge: .top, spacing: 0) {
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
            .padding(.top, 8) // 稍微留点边距，看起来更舒服
            .background(DesignTokens.Colors.bgPrimary) // 保证导航栏背景色与全局一致
        }
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
        // 处理完成后展示结果页
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

    // MARK: - 性能指标颜色

    private var cpuColor: Color {
        if appState.performanceMonitor.cpuUsage < 50 { return .green }
        if appState.performanceMonitor.cpuUsage < 80 { return .orange }
        return .red
    }

    private var memoryColor: Color {
        if appState.performanceMonitor.memoryUsageMB < 500 { return .green }
        if appState.performanceMonitor.memoryUsageMB < 800 { return .orange }
        return .red
    }
}
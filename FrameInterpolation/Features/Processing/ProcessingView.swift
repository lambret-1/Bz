import SwiftUI
import UIKit

/// 处理中页（独立全屏）
/// 唯一进度环 + 任务清单 + 状态文案 + 剩余时间 + 底部提示
/// 左上角回首页按钮 + 取消按钮，防息屏，处理完成后全屏展示结果页
struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirm = false
    @State private var isThermalWarning = false

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
                    .font(DesignTokens.Fonts.subheadline)
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

            // 唯一进度环
            RingProgressView(
                progress: appState.progress,
                processedFrames: appState.processedFrames,
                totalFrames: appState.totalFrames
            )
            .accessibilityValue("已完成\(Int(appState.progress * 100))%")

            // 任务清单
            if !appState.processingTasks.isEmpty {
                taskList
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
            }

            // 状态文案
            Text(appState.stage.rawValue)
                .font(DesignTokens.Fonts.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)

            // 预计剩余时间
            if appState.estimatedRemaining > 1 {
                Text("预计剩余时间：约 \(TimeFormatter.formatChinese(appState.estimatedRemaining))")
                    .font(DesignTokens.Fonts.subheadline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            // 底部提示
            bottomHint
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.l)
        }
        .background(DesignTokens.Colors.bgPrimary)
        .interactiveDismissDisabled()
        .onAppear {
            if appState.keepScreenAwake {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            // 监听热状态
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                isThermalWarning = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .fair
            }
            isThermalWarning = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .fair
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 取消确认
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

    // MARK: - 任务清单
    private var taskList: some View {
        VStack(spacing: 0) {
            ForEach(appState.processingTasks) { task in
                HStack(spacing: DesignTokens.Spacing.s) {
                    taskIcon(for: task.status)
                    Text(task.name)
                        .font(DesignTokens.Fonts.subheadline)
                        .foregroundColor(task.status == .completed ? DesignTokens.Colors.textSecondary.opacity(0.6) : DesignTokens.Colors.textPrimary)
                    Spacer()
                    if task.status == .running, let progress = task.progress {
                        Text("\(Int(progress * 100))%")
                            .font(DesignTokens.Fonts.monoCaption)
                            .foregroundColor(DesignTokens.Colors.accent)
                    }
                }
                .frame(height: 44)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(task.name)，\(taskStatusText(task.status))")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .background(DesignTokens.Colors.bgSecondary)
        .cornerRadius(DesignTokens.Radius.m)
    }

    private func taskIcon(for status: ProcessingTask.TaskStatus) -> some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DesignTokens.Colors.success)
            case .running:
                RotatingIcon(name: "arrow.triangle.2.circlepath", color: DesignTokens.Colors.accent)
            case .waiting:
                Image(systemName: "circle")
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
        }
        .font(.system(size: 18))
        .frame(width: 24)
    }

    private func taskStatusText(_ status: ProcessingTask.TaskStatus) -> String {
        switch status {
        case .completed: return "已完成"
        case .running: return "进行中"
        case .waiting: return "等待中"
        }
    }

    // MARK: - 底部提示
    private var bottomHint: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            if isThermalWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DesignTokens.Colors.warning)
                Text("设备温度较高，建议降低设置或暂停")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundColor(DesignTokens.Colors.warning)
            } else {
                Image(systemName: "thermometer")
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                Text("处理期间请保持 App 在前台，屏幕将保持常亮")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - 旋转图标（进行中任务的动画）
private struct RotatingIcon: View {
    let name: String
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: name)
            .foregroundColor(color)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

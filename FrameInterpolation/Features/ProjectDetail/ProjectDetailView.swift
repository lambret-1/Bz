import SwiftUI

/// 项目详情页：视频预览 + 时间线编辑 + 增强任务 + 导出设置 + 底部开始按钮
/// 独立 NavigationStack 全屏展示，左上角返回按钮 + 支持边缘左滑手势返回
struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var currentTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var selectedSegmentID: UUID?

    private var project: Project? { appState.currentProject }
    private var segments: [VideoSegment] { project?.segments ?? [] }
    private var duration: TimeInterval { project?.videoInfo.duration ?? 0 }

    /// 分切是否可用：播放头位于某个片段内部，距两端 > 0.05s
    private var canSplit: Bool {
        segments.contains {
            currentTime > $0.startTime + 0.05 && currentTime < $0.endTime - 0.05
        }
    }

    /// 复制是否可用：已选中片段
    private var canCopy: Bool { selectedSegmentID != nil }

    /// 删除是否可用：至少保留 1 个片段
    private var canDelete: Bool { segments.count > 1 && selectedSegmentID != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    if let project = project {
                        // 视频预览区
                        VideoPreviewContainer(
                            url: project.videoInfo.url,
                            currentTime: $currentTime,
                            isPlaying: $isPlaying,
                            duration: duration
                        )

                        // 时间线区域
                        CardView {
                            VStack(spacing: DesignTokens.Spacing.m) {
                                TimelineView(
                                    segments: segments,
                                    duration: duration,
                                    currentTime: $currentTime,
                                    selectedSegmentID: $selectedSegmentID
                                ) { time in
                                    // 拖动播放头时暂停
                                    isPlaying = false
                                }

                                // 编辑工具栏
                                EditToolbar(
                                    canSplit: canSplit,
                                    canCopy: canCopy,
                                    canDelete: canDelete,
                                    canUndo: appState.canUndo,
                                    onSplit: { appState.splitSegment(at: currentTime) },
                                    onCopy: {
                                        if let segment = segments.first(where: { $0.id == selectedSegmentID }) {
                                            appState.duplicateSegment(segment)
                                        }
                                    },
                                    onDelete: {
                                        if let segment = segments.first(where: { $0.id == selectedSegmentID }) {
                                            appState.deleteSegment(segment)
                                            selectedSegmentID = nil
                                        }
                                    },
                                    onUndo: { appState.undoSegmentEdit() }
                                )
                            }
                        }

                        // 增强任务区域
                        EnhancementTaskSection()

                        // 导出设置入口
                        exportSettingsEntry(project: project)
                    } else {
                        // 项目丢失（异常情况）
                        EmptyStateView(
                            icon: "exclamationmark.triangle",
                            title: "项目不存在",
                            subtitle: "请返回首页重新选择"
                        )
                    }
                }
                .padding(DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.buttonHeight + DesignTokens.Spacing.xl)
            }
            .background(DesignTokens.Colors.bgPrimary)
            .navigationTitle(project?.name ?? "项目详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPlaying = false
                        appState.closeProjectDetail()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("返回")
                        }
                        .foregroundColor(DesignTokens.Colors.accent)
                    }
                    .accessibilityLabel("返回首页")
                }
            }
            // 底部固定按钮
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            // 导出设置页（独立全屏）
            .fullScreenCover(isPresented: $appState.showExportSettings) {
                ExportSettingsView()
                    .environmentObject(appState)
            }
            // 处理中页（独立全屏）
            .fullScreenCover(isPresented: $appState.isProcessing) {
                ProcessingView()
                    .environmentObject(appState)
            }
            // Toast
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onDisappear {
                isPlaying = false
            }
        }
    }

    // MARK: - 导出设置入口
    private func exportSettingsEntry(project: Project) -> some View {
        Button {
            appState.showExportSettings = true
        } label: {
            HStack {
                Image(systemName: "gearshape")
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出设置")
                        .font(DesignTokens.Fonts.headline)
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                    Text("\(project.exportSettings.codec.rawValue) · \(project.exportSettings.bitrateMode.rawValue) · \(project.exportSettings.container.rawValue)")
                        .font(DesignTokens.Fonts.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            .padding(DesignTokens.Spacing.m)
            .background(DesignTokens.Colors.bgSecondary)
            .cornerRadius(DesignTokens.Radius.l)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导出设置")
    }

    // MARK: - 底部固定按钮
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.Colors.border)
                .frame(height: 1)
            PrimaryButton(
                title: "开始处理并导出",
                isLoading: appState.isProcessing,
                isDisabled: segments.isEmpty
            ) {
                isPlaying = false
                appState.startProcessing()
            }
            .padding(DesignTokens.Spacing.m)
        }
        .background(DesignTokens.Colors.bgPrimary)
    }
}

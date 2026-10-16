import SwiftUI

/// 首页：项目网格列表
/// 大标题「我的项目」+ 右上角导入按钮 + 设置入口
/// 项目卡片支持点击进入详情、长按弹出操作菜单
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false
    @State private var projectToDelete: Project?
    @State private var showDeleteConfirm = false
    @State private var projectToRename: Project?
    @State private var renameText = ""
    @State private var showRenameDialog = false

    private let columns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.m),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.m)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if appState.projects.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignTokens.Spacing.xl * 2)
                } else {
                    projectGrid
                        .padding(DesignTokens.Spacing.m)
                }
            }
            .background(DesignTokens.Colors.bgPrimary)
            .navigationTitle("我的项目")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(DesignTokens.Fonts.title3)
                            .foregroundColor(DesignTokens.Colors.accent)
                            .frame(width: DesignTokens.minTapArea, height: DesignTokens.minTapArea)
                    }
                    .accessibilityLabel("导入视频")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appState.showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(DesignTokens.Fonts.title3)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .frame(width: DesignTokens.minTapArea, height: DesignTokens.minTapArea)
                    }
                    .accessibilityLabel("设置")
                }
            }
            // 相册选择器
            .sheet(isPresented: $showPicker) {
                VideoPicker(
                    onPick: { url in
                        showPicker = false
                        appState.importVideo(from: url)
                    },
                    onCancel: { showPicker = false }
                )
            }
            // 项目详情页（独立全屏导航）
            .fullScreenCover(isPresented: $appState.showProjectDetail) {
                ProjectDetailView()
                    .environmentObject(appState)
            }
            // 应用设置页（独立全屏导航）
            .fullScreenCover(isPresented: $appState.showAppSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            // 处理中页（从首页横幅恢复时展示）
            .fullScreenCover(isPresented: $appState.isProcessing) {
                ProcessingView()
                    .environmentObject(appState)
            }
            // Toast 覆盖层
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            // 处理中横幅（最小化到首页时显示）
            .overlay(alignment: .top) {
                if appState.isProcessingMinimized {
                    processingBanner
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(0)
                }
            }
            // 删除确认
            .alert("删除项目", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let project = projectToDelete {
                        appState.deleteProject(project)
                    }
                    projectToDelete = nil
                }
            } message: {
                if let project = projectToDelete {
                    Text("确定删除项目「\(project.name)」吗？此操作不可撤销，已处理的视频也会被删除。")
                }
            }
            // 重命名输入框
            .alert("重命名项目", isPresented: $showRenameDialog) {
                TextField("项目名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("确定") {
                    if let project = projectToRename, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        appState.renameProject(project, newName: renameText.trimmingCharacters(in: .whitespaces))
                    }
                    projectToRename = nil
                    renameText = ""
                }
            }
        }
    }

    // MARK: - 项目网格
    private var projectGrid: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.m) {
            ForEach(appState.projects) { project in
                ProjectCard(project: project)
                    .onTapGesture {
                        appState.openProject(project)
                    }
                    .contextMenu {
                        Button {
                            projectToRename = project
                            renameText = project.name
                            showRenameDialog = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button {
                            appState.duplicateProject(project)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            projectToDelete = project
                            showDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - 空状态
    private var emptyState: some View {
        EmptyStateView(
            icon: "video.badge.plus",
            title: "还没有项目",
            subtitle: "导入视频开始增强",
            actionTitle: "导入视频",
            action: { showPicker = true }
        )
    }

    // MARK: - 处理中横幅
    private var processingBanner: some View {
        Button {
            appState.restoreProcessingView()
        } label: {
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView(value: appState.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                VStack(alignment: .leading, spacing: 2) {
                    Text("处理中 \(Int(appState.progress * 100))%")
                        .font(.caption.weight(.medium))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                    Text(appState.stage.rawValue)
                        .font(.caption2)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding(.horizontal, DesignTokens.Spacing.m)
        }
        .accessibilityLabel("恢复处理页面")
    }
}

// MARK: - 项目卡片
/// 缩略图 16:9 高 100pt 圆角 12 + 项目名称 + 分辨率/帧率 + 任务标签 + 状态
struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // 缩略图
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.m)
                    .fill(DesignTokens.Colors.bgTertiary)
                    .frame(height: 100)

                if let thumbnail = project.videoInfo.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 100)
                        .clipped()
                        .cornerRadius(DesignTokens.Radius.m)
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 32))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .frame(height: 100)
                }

                // 时长标签
                Text(TimeFormatter.format(project.totalDuration))
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(6)
            }
            .frame(height: 100)

            // 项目名称
            Text(project.name)
                .font(DesignTokens.Fonts.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)
                .lineLimit(1)

            // 分辨率 + 帧率
            Text("\(project.resolutionLabel) · \(project.fpsLabel)")
                .font(DesignTokens.Fonts.caption)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            // 任务标签
            if !project.taskTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(project.taskTags.prefix(3)), id: \.label) { tag in
                        TaskTag(type: tag)
                    }
                    if project.taskTags.count > 3 {
                        Text("+\(project.taskTags.count - 3)")
                            .font(DesignTokens.Fonts.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                }
            }

            // 状态
            HStack(spacing: 4) {
                Image(systemName: project.status.iconName)
                    .font(.system(size: 12))
                Text(project.status.rawValue)
                    .font(DesignTokens.Fonts.caption)
            }
            .foregroundColor(project.status.color)
        }
        .padding(DesignTokens.Spacing.s)
        .background(DesignTokens.Colors.bgSecondary)
        .cornerRadius(DesignTokens.Radius.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("项目\(project.name)，时长\(TimeFormatter.format(project.totalDuration))，状态\(project.status.rawValue)")
    }
}

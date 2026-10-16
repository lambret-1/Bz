import SwiftUI

/// 首页：导入卡片 + 最近记录
/// 选择视频后通过独立 fullScreenCover 展示参数设置页，不共用导航栈
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                // 顶部标题
                HStack {
                    Text("视频增强")
                        .font(.largeTitle.bold())
                    Spacer()
                }

                // 导入卡片
                CardView {
                    VStack(spacing: DesignTokens.Spacing.m) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(DesignTokens.Colors.accent)

                        Text("导入视频开始增强")
                            .font(.headline)

                        Text("支持 AI 补帧与超分辨率，完全本地处理")
                            .font(.subheadline)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .multilineTextAlignment(.center)

                        PrimaryButton(title: "从相册选择") {
                            showPicker = true
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // 最近记录
                HStack {
                    Text("最近记录")
                        .font(.headline)
                    Spacer()
                    if !appState.recentRecords.isEmpty {
                        NavigationLink {
                            RecentVideosView()
                                .environmentObject(appState)
                        } label: {
                            HStack(spacing: 2) {
                                Text("全部")
                                    .font(.subheadline)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .foregroundColor(DesignTokens.Colors.accent)
                        }
                    }
                }

                if appState.recentRecords.isEmpty {
                    EmptyStateView(
                        icon: "video.slash",
                        title: "还没有处理记录",
                        subtitle: "导入一个视频试试吧"
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.m) {
                            ForEach(appState.recentRecords.prefix(10)) { record in
                                RecentRecordCard(record: record) {
                                    // 点击卡片：如果输出文件仍存在则直接展示结果，否则提示重新导入
                                    appState.replayRecentRecord(record)
                                }
                            }
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.m)
        }
        .background(DesignTokens.Colors.bgPrimary)
        // 相册选择器
        .sheet(isPresented: $showPicker) {
            VideoPicker(
                onPick: { url in
                    showPicker = false
                    appState.importVideo(from: url)
                },
                onCancel: {
                    showPicker = false
                }
            )
        }
        // 参数设置页（独立全屏导航，不共用首页导航栈）
        .fullScreenCover(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        // Toast 覆盖层
        .overlay(alignment: .top) {
            if let message = appState.toastMessage {
                ToastView(message: message, style: appState.toastStyle)
                    .padding(.top, DesignTokens.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 处理中横幅（最小化到首页时显示）
        .overlay(alignment: .top) {
            if appState.isProcessingMinimized {
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
                    .padding(.top, DesignTokens.Spacing.s)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 处理中页（从首页横幅恢复时展示）
        .fullScreenCover(isPresented: $appState.isProcessing) {
            ProcessingView()
                .environmentObject(appState)
        }
    }
}

// MARK: - 最近记录卡片
struct RecentRecordCard: View {
    let record: RecentRecord
    var onTap: (() -> Void)? = nil

    private var thumbnailImage: UIImage? {
        guard let data = record.thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // 缩略图区域
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                        .fill(DesignTokens.Colors.bgTertiary)
                        .frame(width: 180, height: 101)

                    if let image = thumbnailImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 180, height: 101)
                            .clipped()
                            .cornerRadius(DesignTokens.Radius.s)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 32))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }

                    // 时长标签
                    if let duration = record.durationText {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(6)
                    }

                    // 处理模式标签（右上角）
                    if let mode = record.processingMode {
                        Text(mode)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignTokens.Colors.accent.opacity(0.9))
                            .cornerRadius(4)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: 180, height: 101)

                // 文件名
                Text(record.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                // 元信息行
                HStack(spacing: 6) {
                    if let resolution = record.resolutionText {
                        Text(resolution)
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    Text("\(Int(record.outputFPS))fps")
                        .font(.system(size: 10))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    if let size = record.fileSizeText {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                        Text(size)
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                }
                .frame(width: 180, alignment: .leading)

                // 时间
                Text(record.formattedDate)
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Colors.textSecondary.opacity(0.7))
                    .frame(width: 180, alignment: .leading)
            }
            .frame(width: 180)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                // 删除操作由父视图处理
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

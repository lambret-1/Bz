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
                            ForEach(appState.recentRecords) { record in
                                RecentRecordCard(record: record)
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
                            Text("补帧中 \(Int(appState.progress * 100))%")
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

    private var thumbnailImage: UIImage? {
        guard let data = record.thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                    .fill(DesignTokens.Colors.bgTertiary)
                    .frame(width: 160, height: 90)

                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 90)
                        .clipped()
                        .cornerRadius(DesignTokens.Radius.s)
                } else {
                    Image(systemName: "video.fill")
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
            .frame(width: 160, height: 90)

            Text(record.fileName)
                .font(.caption)
                .lineLimit(1)
            Text("\(Int(record.outputFPS))fps")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DesignTokens.Colors.accent)
                .foregroundColor(.white)
                .cornerRadius(4)
        }
        .frame(width: 160)
    }
}

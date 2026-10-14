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
    }
}

// MARK: - 最近记录卡片
struct RecentRecordCard: View {
    let record: RecentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                .fill(DesignTokens.Colors.bgTertiary)
                .frame(width: 160, height: 90)
                .overlay(
                    Image(systemName: "video.fill")
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                )
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

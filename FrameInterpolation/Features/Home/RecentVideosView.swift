import SwiftUI

/// 最近视频列表页（独立 NavigationStack，全屏展示）
/// 显示所有处理记录，支持点击重播、左滑删除、清空全部
struct RecentVideosView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.recentRecords.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(appState.recentRecords) { record in
                            RecentVideoRow(record: record) {
                                appState.replayRecentRecord(record)
                                dismiss()
                            }
                        }
                        .onDelete(perform: deleteRecords)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(DesignTokens.Colors.bgPrimary)
            .navigationTitle("最近视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !appState.recentRecords.isEmpty {
                        Button("清空") {
                            showClearConfirm = true
                        }
                        .foregroundColor(DesignTokens.Colors.error)
                    }
                }
            }
            .alert("清空所有记录", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    appState.clearAllRecentRecords()
                }
            } message: {
                Text("确定要清空所有最近视频记录吗？此操作不可撤销。")
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Text("还没有处理记录")
                .font(.headline)
                .foregroundColor(DesignTokens.Colors.textPrimary)
            Text("处理完成的视频会显示在这里")
                .font(.subheadline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.bgPrimary)
    }

    // MARK: - 删除记录

    private func deleteRecords(at offsets: IndexSet) {
        offsets.forEach { index in
            let record = appState.recentRecords[index]
            appState.deleteRecentRecord(record)
        }
    }
}

// MARK: - 最近视频行

struct RecentVideoRow: View {
    let record: RecentRecord
    var onTap: (() -> Void)? = nil

    private var thumbnailImage: UIImage? {
        guard let data = record.thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: DesignTokens.Spacing.m) {
                // 缩略图
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                        .fill(DesignTokens.Colors.bgTertiary)
                        .frame(width: 120, height: 68)

                    if let image = thumbnailImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 68)
                            .clipped()
                            .cornerRadius(DesignTokens.Radius.s)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 24))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }

                    if let duration = record.durationText {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(3)
                            .padding(4)
                    }
                }
                .frame(width: 120, height: 68)

                // 信息区域
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.fileName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)

                    if let mode = record.processingMode {
                        Text(mode)
                            .font(.system(size: 12))
                            .foregroundColor(DesignTokens.Colors.accent)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let resolution = record.resolutionText {
                            Text(resolution)
                                .font(.system(size: 11))
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                        Text("\(Int(record.outputFPS))fps")
                            .font(.system(size: 11))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                        if let size = record.fileSizeText {
                            Text(size)
                                .font(.system(size: 11))
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                    }

                    Text(record.formattedDate)
                        .font(.system(size: 11))
                        .foregroundColor(DesignTokens.Colors.textSecondary.opacity(0.7))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignTokens.Colors.textSecondary.opacity(0.5))
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .buttonStyle(.plain)
    }
}

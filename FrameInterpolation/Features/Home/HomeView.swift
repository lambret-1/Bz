import SwiftUI
import PhotosUI

/// 首页：导入卡片 + 最近记录
/// 选择视频后通过独立 fullScreenCover 展示参数设置页，不共用导航栈
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false
    @State private var showAppSettings = false

    // --- 图片超分新增状态 ---
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var inputImage: UIImage?
    @State private var outputImage: UIImage?
    @State private var isProcessingImage = false
    @State private var isSavingImage = false
    private let imageSRService = ImageSuperResolutionService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                // 顶部标题
                HStack {
                    Text("AI 增强")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button {
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                    }
                }

                // 功能入口：视频增加 + 图片超分 并排大图标
                HStack(spacing: DesignTokens.Spacing.l) {
                    // 视频增加
                    Button {
                        showPicker = true
                    } label: {
                        VStack(spacing: DesignTokens.Spacing.s) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 44))
                                .foregroundColor(DesignTokens.Colors.accent)
                            Text("视频增强")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DesignTokens.Colors.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .background(DesignTokens.Colors.bgSecondary)
                        .cornerRadius(DesignTokens.Radius.l)
                    }
                    .buttonStyle(.plain)

                    // 图片超分
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                        VStack(spacing: DesignTokens.Spacing.s) {
                            if isProcessingImage {
                                ProgressView()
                                    .scaleEffect(1.2)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 44))
                                    .foregroundColor(DesignTokens.Colors.accent)
                            }
                            Text(isProcessingImage ? "处理中…" : "图片超分")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DesignTokens.Colors.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .background(DesignTokens.Colors.bgSecondary)
                        .cornerRadius(DesignTokens.Radius.l)
                    }
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            await MainActor.run {
                                self.inputImage = uiImage
                                startImageUpscale(uiImage)
                            }
                        }
                    }
                }

                // 3. 最近记录
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
                                RecentRecordCard(
                                    record: record,
                                    onTap: { appState.replayRecentRecord(record) },
                                    onDelete: { appState.deleteRecentRecord(record) },
                                    onRename: { newName in appState.renameRecord(record, newName: newName) },
                                    onEnhance: { appState.enhanceRecord(record) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.m)
        }
        .background(DesignTokens.Colors.bgPrimary)
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
        .fullScreenCover(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: $showAppSettings) {
            AppSettingsView()
                .environmentObject(appState)
        }
        .overlay(alignment: .top) {
            if let message = appState.toastMessage {
                ToastView(message: message, style: appState.toastStyle)
                    .padding(.top, DesignTokens.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        .fullScreenCover(isPresented: $appState.isProcessing) {
            ProcessingView()
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: Binding(
            get: { appState.outputURL != nil && !appState.isProcessing },
            set: { if !$0 { appState.outputURL = nil } }
        )) {
            if let url = appState.outputURL {
                ResultView(outputURL: url)
                    .environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { outputImage != nil },
            set: { if !$0 { outputImage = nil; inputImage = nil; selectedPhotoItem = nil } }
        )) {
            ImageSRResultView(
                outputImage: outputImage,
                isSaving: $isSavingImage,
                onSave: { saveImageToAlbum(outputImage!) },
                onClose: { outputImage = nil }
            )
        }
    }
    
    private func startImageUpscale(_ image: UIImage) {
        isProcessingImage = true
        imageSRService.processImage(image) { result in
            isProcessingImage = false
            if let result = result {
                self.outputImage = result
            } else {
                appState.showToast("图片超分失败，请重试", style: .error)
            }
        }
    }

    private func saveImageToAlbum(_ image: UIImage) {
        isSavingImage = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSavingImage = false
                    appState.showToast("没有相册写入权限，请在设置中开启", style: .error)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    isSavingImage = false
                    if success {
                        appState.showToast("已保存到相册")
                    } else {
                        appState.showToast(error?.localizedDescription ?? "保存失败", style: .error)
                    }
                }
            }
        }
    }
}

// MARK: - 最近记录卡片
struct RecentRecordCard: View {
    let record: RecentRecord
    var onTap: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onRename: ((String) -> Void)? = nil
    var onEnhance: (() -> Void)? = nil
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var thumbnailImage: UIImage? {
        guard let data = record.thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
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

                Text(record.displayFileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

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

                Text(record.formattedDate)
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Colors.textSecondary.opacity(0.7))
                    .frame(width: 180, alignment: .leading)
            }
            .frame(width: 180)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = record.displayFileName
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                onEnhance?()
            } label: {
                Label("视频增强", systemImage: "sparkles")
            }
            Divider()
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("输入新名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if !renameText.isEmpty {
                    onRename?(renameText)
                }
            }
        } message: {
            Text("输入新的显示名称")
        }
    }
}

// MARK: - 图片超分结果页（独立全屏）
struct ImageSRResultView: View {
    let outputImage: UIImage?
    @Binding var isSaving: Bool
    let onSave: () -> Void
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.l) {
                    if let image = outputImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(DesignTokens.Radius.m)
                            .padding(.horizontal, DesignTokens.Spacing.m)
                    }
                }
            }
            .background(DesignTokens.Colors.bgPrimary)
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("图片超分结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { onClose() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(
                    title: isSaving ? "保存中…" : "保存到相册",
                    isLoading: isSaving
                ) {
                    onSave()
                }
                .padding(DesignTokens.Spacing.m)
                .background(DesignTokens.Colors.bgPrimary)
            }
        }
    }
}

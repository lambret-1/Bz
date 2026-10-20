
import SwiftUI
import PhotosUI

/// 首页：导入卡片 + 最近记录
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false
    @State private var showAppSettings = false

    // --- 图片超分新增状态（请确保这些变量在 struct 大括号内） ---
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var inputImage: UIImage?
    @State private var outputImage: UIImage?
    @State private var isProcessingImage = false
    
    // 实例化图片处理服务
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

                // 1. 导入视频卡片
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

                        PrimaryButton(title: "从相册选择视频") {
                            showPicker = true
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // 2. 图片超分卡片
                CardView {
                    VStack(spacing: DesignTokens.Spacing.m) {
                        if isProcessingImage {
                            ProgressView()
                                .scaleEffect(1.5)
                                .padding(.vertical, 20)
                            Text("AI 正在超分图片...")
                                .font(.subheadline)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                            
                        } else if let outputImage = outputImage {
                            // 处理完成展示
                            Image(uiImage: outputImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .cornerRadius(DesignTokens.Radius.s)
                                .shadow(radius: 4)
                            
                            HStack(spacing: DesignTokens.Spacing.m) {
                                Button("保存到相册") {
                                    UIImageWriteToSavedPhotosAlbum(outputImage, nil, nil, nil)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(DesignTokens.Colors.accent)
                                
                                Button("重新选择") {
                                    self.outputImage = nil
                                    self.inputImage = nil
                                    self.selectedPhotoItem = nil
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            // 默认选择状态
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 48))
                                .foreinitygroundColor(DesignTokens.Colors.accent)

                            Text("图片 AI 超分")
                                .font(.headline)

                            Text("将模糊旧图放大 4 倍并补充细节，支持人像修复")
                                .font(.subheadline)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                                .multilineTextAlignment(.center)
)

                            PhotosPicker(selection: $selectedPhotoItem                                   , matching: .images, photoLibrary: .shared()) {
                                Text .("从相册选择图片")
                                    .font(.systempadding(size: 16, weight: .medium))
                                    .(.foregroundColor(.white)
                                    .frame(maxWidth: .infvertical, 12)
                                    .background(DesignTokens.Colors.accent)
                                    .cornerRadius(DesignTokens.Radius.m)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                // 监听图片选择
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
                                RecentRecordCard(record: record) {
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
        // 参数设置页
        .fullScreenCover(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        // 应用设置页
        .fullScreenCover(isPresented: $showAppSettings) {
            AppSettingsView()
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
        // 处理中横幅
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
        // 处理中页
        .fullScreenCover(isPresented: $appState.isProcessing) {
            ProcessingView()
                .environmentObject(appState)
        }
    }
    
    // 触发图片超分
    private func startImageUpscale(_ image: UIImage) {
        isProcessingImage = true
        imageSRService.processImage(image) { result in
            isProcessingImage = false
            if let result = result {
                self.outputImage = result
            } else {
                // 如果 appState 里有 Toast 机制，可以取消注释下面的代码
                // appState.toastMessage = "图片处理失败，请重试"
            }
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

                Text(record.fileName)
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
            Button(role: .destructive) {
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

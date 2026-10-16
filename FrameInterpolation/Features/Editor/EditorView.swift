import SwiftUI

/// 编辑器主容器：TopBar + PreviewArea + PlaybackControlBar + TimelineView + BottomToolbar
struct EditorView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var draftIndicator = DraftSaveIndicator()
    @State private var showCloseAlert = false
    @State private var showResult = false
    @State private var showStorageAlert = false
    @State private var requiredMB = 0
    @State private var availableMB = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    onClose: { showCloseAlert = true },
                    onExport: { prepareExport() }
                )

                PreviewArea()
                PlaybackControlBar()
                TimelineView()
                BottomToolbar()
            }

            // 草稿保存 Toast（顶层居中显示）
            if draftIndicator.showSaved {
                VStack {
                    Spacer().frame(height: 70)
                    DraftSavedToast()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                    Spacer()
                }
                .animation(.easeInOut(duration: 0.2), value: draftIndicator.showSaved)
            }

            // 导出处理 HUD（Editor内部使用，不触发HomeView的ProcessingView）
            if appState.isProcessing {
                ExportHUD()
                    .zIndex(90)
            }
        }
        .alert("退出编辑器？", isPresented: $showCloseAlert) {
            Button("取消", role: .cancel) {}
            Button("保存草稿并退出") {
                saveDraft()
                closeEditor()
            }
            Button("放弃修改", role: .destructive) {
                closeEditor()
            }
        } message: {
            Text("选择「保存草稿」可保留当前编辑，下次打开自动恢复；选择「放弃修改」则不保存。")
        }
        .storageAlert(
            isPresented: $showStorageAlert,
            requiredMB: requiredMB,
            availableMB: availableMB,
            onCleanCache: { cleanCache() }
        )
        // 结果页：标准 fullScreenCover，支持手势关闭
        .fullScreenCover(isPresented: $showResult) {
            if let outputURL = appState.outputURL {
                ResultView(outputURL: outputURL)
                    .environmentObject(appState)
                    .onDisappear {
                        // 关闭结果页时重置状态
                        appState.outputURL = nil
                        appState.isProcessing = false
                    }
            }
        }
        .onChange(of: appState.outputURL) { newValue in
            if newValue != nil {
                showResult = true
            } else {
                showResult = false
            }
        }
    }

    // MARK: - 导出准备
    private func prepareExport() {
        guard appState.currentProject != nil else { return }

        // 检查磁盘空间
        let estimated = estimateOutputSizeMB()
        let available = availableStorageMB()

        if estimated > available {
            requiredMB = estimated
            availableMB = available
            showStorageAlert = true
            return
        }

        appState.startProcessing()
    }

    // MARK: - 草稿保存
    private func saveDraft() {
        draftIndicator.triggerSave()
        if let segments = appState.currentProject?.segments {
            DraftStore.shared.saveDraft(segments: segments)
        }
    }

    // MARK: - 关闭编辑器
    private func closeEditor() {
        PlayerManager.shared.release()
        appState.closeProjectDetail()
    }

    // MARK: - 存储空间
    private func estimateOutputSizeMB() -> Int {
        guard let video = appState.currentProject?.videoInfo else { return 0 }

        // 基础码率估算（Mbps）：按分辨率和码率模式
        let height = video.height
        let baseBitrate: Double
        switch appState.outputResolution {
        case .p720: baseBitrate = 8.0
        case .p1080: baseBitrate = 16.0
        case .auto:
            baseBitrate = height >= 1080 ? 16.0 : (height >= 720 ? 8.0 : 4.0)
        }

        // 码率模式系数
        let bitrateFactor: Double
        switch appState.currentProject?.exportSettings.bitrateMode ?? .auto {
        case .high: bitrateFactor = 1.5
        case .balanced: bitrateFactor = 1.0
        case .small: bitrateFactor = 0.5
        case .auto: bitrateFactor = 1.0
        }

        // 补帧倍数系数（帧率翻倍，码率需求增加）
        let multiplier = appState.currentProject?.enhancement.frameMultiplier.rawValue ?? 1
        let fpsFactor = Double(multiplier)

        // 文件大小 = 码率(Mbps) × 时长(s) / 8 (转MB) × 系数
        let sizeMB = (baseBitrate * bitrateFactor * fpsFactor * video.duration) / 8.0
        return Int(max(sizeMB, 5))  // 最少5MB
    }

    private func availableStorageMB() -> Int {
        guard let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return 0
        }
        let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_048_576)
    }

    private func cleanCache() {
        appState.clearCache()
    }
}

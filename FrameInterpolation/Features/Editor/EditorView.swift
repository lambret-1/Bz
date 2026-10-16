import SwiftUI

/// 编辑器主容器：TopBar + PreviewArea + PlaybackControlBar + TimelineView + BottomToolbar
struct EditorView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCloseAlert = false
    @State private var showResult = false

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
                    .frame(maxHeight: .infinity)
                BottomToolbar()
            }

            // 导出处理 HUD
            if appState.isProcessing {
                ExportHUD()
            }

            // 结果页
            if showResult, let outputURL = appState.outputURL {
                ResultView(outputURL: outputURL)
                    .environmentObject(appState)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showResult = false
                            appState.outputURL = nil
                            appState.isProcessing = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
            }
        }
        .alert("放弃编辑？", isPresented: $showCloseAlert) {
            Button("取消", role: .cancel) {}
            Button("放弃", role: .destructive) {
                closeEditor()
            }
        } message: {
            Text("当前编辑将不会保存，确定要退出吗？")
        }
        .onChange(of: appState.outputURL) { newValue in
            if newValue != nil {
                showResult = true
            }
        }
    }

    // MARK: - 导出准备
    private func prepareExport() {
        guard appState.currentProject != nil else { return }
        appState.startProcessing()
    }

    // MARK: - 关闭编辑器
    private func closeEditor() {
        PlayerManager.shared.release()
        appState.closeProjectDetail()
    }
}

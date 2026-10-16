import SwiftUI

/// 编辑器顶部栏：关闭按钮 + 任务选择器 + 导出按钮
struct TopBar: View {
    @EnvironmentObject var appState: AppState
    let onClose: () -> Void
    let onExport: () -> Void
    @State private var showTaskSheet = false

    /// 任务标签显示逻辑（与TaskSheet联动）
    private var taskLabel: String {
        guard let project = appState.currentProject else { return "未导入" }

        // 分辨率：优先显示用户选择的输出分辨率
        let resolution: String
        switch appState.outputResolution {
        case .auto:
            resolution = "\(project.videoInfo.height)P"
        case .p720:
            resolution = "720P"
        case .p1080:
            resolution = "1080P"
        }

        // 帧率：优先显示用户选择的输出帧率
        let fpsLabel: String
        switch appState.outputFPS {
        case .original:
            fpsLabel = "\(Int(project.videoInfo.originalFPS))fps"
        case .fps60:
            fpsLabel = "60fps"
        case .fps120:
            fpsLabel = "120fps"
        }

        switch project.enhancement.mode {
        case .frameInterpolation:
            let multiplier = project.enhancement.frameMultiplier.rawValue
            return "补帧 \(multiplier)x · \(resolution) · \(fpsLabel)"
        case .superResolution:
            return "超分 \(project.enhancement.srModel.rawValue) · \(resolution)"
        case .none:
            return "\(resolution) · \(fpsLabel)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 关闭按钮
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.topBarText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("关闭编辑器")

            Spacer()

            // 任务与分辨率选择器
            Button {
                showTaskSheet = true
            } label: {
                HStack(spacing: 4) {
                    Text(taskLabel)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(.topBarText)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(6)
            }
            .accessibilityLabel("选择处理任务")

            // 导出按钮（处理中显示加载态）
            Button(action: onExport) {
                HStack(spacing: 6) {
                    if appState.isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("处理中")
                            .font(.system(size: 14, weight: .semibold))
                    } else {
                        Text("导出")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(width: appState.isProcessing ? 96 : 72, height: 40)
                .background(appState.isProcessing ? Color.gray.opacity(0.6) : Color.accentPink)
                .cornerRadius(8)
            }
            .disabled(appState.isProcessing)
            .accessibilityLabel(appState.isProcessing ? "正在处理中" : "导出视频")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Color.topBarBg)
        .sheet(isPresented: $showTaskSheet) {
            TaskSheet()
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
        }
    }
}

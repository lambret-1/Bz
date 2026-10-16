import SwiftUI

/// 编辑器顶部栏：关闭按钮 + 任务选择器 + 导出按钮
struct TopBar: View {
    @EnvironmentObject var appState: AppState
    let onClose: () -> Void
    let onExport: () -> Void
    @State private var showTaskSheet = false

    /// 任务标签显示逻辑
    private var taskLabel: String {
        guard let project = appState.currentProject else { return "未导入" }

        let resolution = "\(project.videoInfo.width)P"

        switch project.enhancement.mode {
        case .frameInterpolation:
            let fps = Int(project.videoInfo.originalFPS) * project.enhancement.frameMultiplier.rawValue
            return "补帧 \(fps)fps · \(resolution)"
        case .superResolution:
            return "超分 \(project.enhancement.srModel.rawValue) · \(resolution)"
        case .none:
            return resolution
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

            // 导出按钮
            Button(action: onExport) {
                Text("导出")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 72, height: 40)
                    .background(appState.isProcessing ? Color.gray : Color.accentPink)
                    .cornerRadius(8)
            }
            .disabled(appState.isProcessing)
            .accessibilityLabel("导出视频")
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

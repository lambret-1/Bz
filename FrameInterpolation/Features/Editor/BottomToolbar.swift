import SwiftUI

/// 底部工具栏：收起/分割/变速/音量/复制/删除/粘贴
struct BottomToolbar: View {
    @EnvironmentObject var appState: AppState

    private let tools: [(String, String, Bool)] = [
        ("chevron.left", "收起", false),
        ("scissors", "分割", false),
        ("speedometer", "变速", false),
        ("speaker.wave.2", "音量", false),
        ("doc.on.doc", "复制", false),
        ("trash", "删除", false),
        ("doc.on.clipboard", "粘贴", true)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tools, id: \.0) { icon, title, isAI in
                Button {
                    handleToolTap(title)
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: icon)
                                .font(.system(size: 24))
                                .foregroundColor(.toolbarText)

                            if isAI {
                                Text("限免")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .cornerRadius(3)
                                    .offset(x: 12, y: -6)
                            }
                        }
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundColor(.toolbarText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(height: 80)
        .background(Color.toolbarBg)
    }

    private func handleToolTap(_ title: String) {
        switch title {
        case "分割":
            let currentTime = PlayerManager.shared.currentTime
            appState.splitSegment(at: currentTime)
        case "复制":
            // 复制选中片段（后续实现选中逻辑）
            appState.showToast("请先选中片段", style: .warning)
        case "删除":
            // 删除选中片段（后续实现选中逻辑）
            appState.showToast("请先选中片段", style: .warning)
        case "粘贴":
            appState.showToast("粘贴功能开发中", style: .warning)
        default:
            break
        }
    }
}

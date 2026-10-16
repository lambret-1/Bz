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
                .accessibilityLabel(title)
                .accessibilityHint(accessibilityHint(for: title))
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "复制":
            if let segment = selectedSegment {
                appState.duplicateSegment(segment)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                appState.showToast("请先选中片段", style: .warning)
            }
        case "删除":
            if let segment = selectedSegment {
                appState.deleteSegment(segment)
                appState.selectedSegmentID = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                appState.showToast("请先选中片段", style: .warning)
            }
        case "粘贴":
            appState.showToast("粘贴功能开发中", style: .warning)
        case "变速":
            appState.showToast("变速功能开发中", style: .warning)
        case "音量":
            appState.showToast("音量调节开发中", style: .warning)
        case "收起":
            appState.showToast("收起时间线", style: .warning)
        default:
            break
        }
    }

    private var selectedSegment: VideoSegment? {
        guard let id = appState.selectedSegmentID else { return nil }
        return appState.currentProject?.segments.first(where: { $0.id == id })
    }

    private func accessibilityHint(for title: String) -> String {
        switch title {
        case "分割": return "在当前播放位置分割片段"
        case "复制": return "复制选中的片段"
        case "删除": return "删除选中的片段"
        default: return ""
        }
    }
}

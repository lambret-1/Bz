import SwiftUI

/// 底部工具栏：收起/分割/变速/音量/复制/删除/粘贴
struct BottomToolbar: View {
    @EnvironmentObject var appState: AppState
    @State private var isTimelineCollapsed = false
    @State private var showSpeedSheet = false
    @State private var showVolumeSheet = false

    private let tools: [(String, String)] = [
        ("chevron.left", "收起"),
        ("scissors", "分割"),
        ("speedometer", "变速"),
        ("speaker.wave.2", "音量"),
        ("doc.on.doc", "复制"),
        ("trash", "删除"),
        ("doc.on.clipboard", "粘贴")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tools, id: \.0) { icon, title in
                Button {
                    handleToolTap(title)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 24))
                            .foregroundColor(buttonColor(title))
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundColor(buttonColor(title))
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(title)
                .accessibilityHint(accessibilityHint(for: title))
                .disabled(isDisabled(title))
            }
        }
        .padding(.vertical, 8)
        .frame(height: 80)
        .background(Color.toolbarBg)
        .sheet(isPresented: $showSpeedSheet) {
            SpeedSettingsView()
                .environmentObject(appState)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showVolumeSheet) {
            VolumeSettingsView()
                .environmentObject(appState)
                .presentationDetents([.medium])
        }
    }

    private func buttonColor(_ title: String) -> Color {
        if isDisabled(title) {
            return .gray
        }
        if title == "收起" && isTimelineCollapsed {
            return Color.accentPink
        }
        return .toolbarText
    }

    private func isDisabled(_ title: String) -> Bool {
        switch title {
        case "复制", "删除":
            return appState.selectedSegmentID == nil
        default:
            return false
        }
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
            }
        case "删除":
            if let segment = selectedSegment {
                appState.deleteSegment(segment)
                appState.selectedSegmentID = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        case "粘贴":
            appState.showToast("粘贴功能即将上线", style: .warning)
        case "变速":
            showSpeedSheet = true
        case "音量":
            showVolumeSheet = true
        case "收起":
            isTimelineCollapsed.toggle()
            NotificationCenter.default.post(
                name: .timelineCollapseChanged,
                object: nil,
                userInfo: ["collapsed": isTimelineCollapsed]
            )
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
        case "收起": return isTimelineCollapsed ? "展开时间线" : "收起时间线"
        default: return ""
        }
    }
}

/// 变速设置视图
struct SpeedSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var speed: Double = 1.0

    var body: some View {
        NavigationView {
            Form {
                Section("播放速度") {
                    Picker("速度", selection: $speed) {
                        Text("0.5x").tag(0.5)
                        Text("0.75x").tag(0.75)
                        Text("1.0x 正常").tag(1.0)
                        Text("1.25x").tag(1.25)
                        Text("1.5x").tag(1.5)
                        Text("2.0x").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("应用到选中片段") {
                        if appState.selectedSegmentID != nil {
                            appState.showToast("已设置 \(speed)x 速度", style: .success)
                        } else {
                            appState.showToast("请先选中片段", style: .warning)
                        }
                        dismiss()
                    }
                    .foregroundColor(Color.accentPink)
                }
            }
            .navigationTitle("变速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 音量设置视图
struct VolumeSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var volume: Double = 1.0

    var body: some View {
        NavigationView {
            Form {
                Section("音量") {
                    Slider(value: $volume, in: 0...2, step: 0.1)
                    Text("当前音量：\(Int(volume * 100))%")
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("应用到选中片段") {
                        if appState.selectedSegmentID != nil {
                            appState.showToast("已设置音量 \(Int(volume * 100))%", style: .success)
                        } else {
                            appState.showToast("请先选中片段", style: .warning)
                        }
                        dismiss()
                    }
                    .foregroundColor(Color.accentPink)
                }
            }
            .navigationTitle("音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

extension Notification.Name {
    static let timelineCollapseChanged = Notification.Name("timelineCollapseChanged")
}

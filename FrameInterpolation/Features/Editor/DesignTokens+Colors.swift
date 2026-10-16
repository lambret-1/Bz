import SwiftUI

/// 编辑器专用颜色扩展，支持浅色/深色模式适配
extension Color {
    // 顶部栏（跟随系统浅/深色）
    static let topBarBg = Color(uiColor: .systemBackground)
    static let topBarText = Color(uiColor: .label)

    // 底部工具栏
    static let toolbarBg = Color(uiColor: .secondarySystemBackground)
    static let toolbarText = Color(uiColor: .label)

    // 时间线
    static let timelineBg = Color(uiColor: .systemBackground)

    // 预览区（强制黑）
    static let videoBg = Color.black

    // 主题色（粉红）
    static let accentPink = Color(red: 1.0, green: 0.18, blue: 0.33)
}

import SwiftUI

/// 全局设计令牌：颜色、间距、圆角、尺寸常量
enum DesignTokens {
    // MARK: - 颜色
    enum Colors {
        /// 页面主背景（Assets 中定义，支持深色/浅色）
        static let bgPrimary = Color("BgPrimary")
        /// 卡片背景
        static let bgSecondary = Color(uiColor: .secondarySystemBackground)
        /// 输入框/分段控件背景
        static let bgTertiary = Color(uiColor: .tertiarySystemBackground)
        /// 主文字
        static let textPrimary = Color.primary
        /// 副文字
        static let textSecondary = Color.secondary
        /// 强调色
        static let accent = Color.accentColor
        /// 成功
        static let success = Color.green
        /// 警告
        static let warning = Color.orange
        /// 错误
        static let error = Color.red
        /// 视频预览区强制纯黑
        static let videoBackground = Color.black
    }

    // MARK: - 间距
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - 圆角
    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - 尺寸常量
    /// 主按钮高度
    static let buttonHeight: CGFloat = 52
    /// 最小点击区域（符合 HIG）
    static let minTapArea: CGFloat = 44
}

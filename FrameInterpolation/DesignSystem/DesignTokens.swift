import SwiftUI

/// 全局设计令牌：颜色、字体、间距、圆角、尺寸常量
/// 严格遵循 UI 细化规格，深色/浅色模式精确配色
enum DesignTokens {
    // MARK: - 动态颜色构建器
    /// 根据当前界面风格返回对应颜色（深色优先）
    private static func dynamic(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1.0) -> Color {
        Color(UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(rgb: dark, alpha: darkAlpha)
            } else {
                return UIColor(rgb: light)
            }
        })
    }

    // MARK: - 颜色
    enum Colors {
        /// 页面主背景：深色 #000000 / 浅色 #F2F2F7
        static let bgPrimary = dynamic(light: 0xF2F2F7, dark: 0x000000)
        /// 卡片背景：深色 #1C1C1E / 浅色 #FFFFFF
        static let bgSecondary = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// 输入框/分段控件背景：深色 #2C2C2E / 浅色 #E5E5EA
        static let bgTertiary = dynamic(light: 0xE5E5EA, dark: 0x2C2C2E)
        /// 主文字：深色 #FFFFFF / 浅色 #000000
        static let textPrimary = dynamic(light: 0x000000, dark: 0xFFFFFF)
        /// 副文字：深色 #8E8E93 / 浅色 #6C6C70
        static let textSecondary = dynamic(light: 0x6C6C70, dark: 0x8E8E93)
        /// 强调色：深色 #0A84FF / 浅色 #007AFF
        static let accent = dynamic(light: 0x007AFF, dark: 0x0A84FF)
        /// 成功：深色 #30D158 / 浅色 #34C759
        static let success = dynamic(light: 0x34C759, dark: 0x30D158)
        /// 警告：深色 #FF9F0A / 浅色 #FF9500
        static let warning = dynamic(light: 0xFF9500, dark: 0xFF9F0A)
        /// 错误：深色 #FF453A / 浅色 #FF3B30
        static let error = dynamic(light: 0xFF3B30, dark: 0xFF453A)
        /// 分割线：深色 #38383A / 浅色 #C6C6C8
        static let border = dynamic(light: 0xC6C6C8, dark: 0x38383A)
        /// 视频预览区强制纯黑（两种模式一致）
        static let videoBackground = Color.black
        /// 弹窗遮罩：深色 60% 黑 / 浅色 40% 黑
        static let overlayScrim = dynamic(light: 0x000000, dark: 0x000000, darkAlpha: 0.6)
    }

    // MARK: - 字体
    enum Fonts {
        /// 大标题 34pt Bold — 首页标题
        static let largeTitle = Font.system(size: 34, weight: .bold)
        /// 页面标题 22pt Semibold
        static let title2 = Font.system(size: 22, weight: .semibold)
        /// 卡片主标题 20pt Semibold
        static let title3 = Font.system(size: 20, weight: .semibold)
        /// 按钮/列表项 17pt Semibold
        static let headline = Font.system(size: 17, weight: .semibold)
        /// 正文 17pt Regular
        static let body = Font.system(size: 17, weight: .regular)
        /// 副文案 15pt Regular
        static let subheadline = Font.system(size: 15, weight: .regular)
        /// 时间/参数 12pt Regular
        static let caption = Font.system(size: 12, weight: .regular)
        /// 时间码/帧率 16pt Medium Mono
        static let mono = Font.system(size: 16, weight: .medium, design: .monospaced)
        /// 小时间码 12pt Mono
        static let monoCaption = Font.system(size: 12, weight: .regular, design: .monospaced)
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
    /// 片段卡片宽度
    static let segmentCardWidth: CGFloat = 100
    /// 片段卡片高度
    static let segmentCardHeight: CGFloat = 70
    /// 进度环外径
    static let ringDiameter: CGFloat = 160
    /// 进度环线宽
    static let ringLineWidth: CGFloat = 12
}

// MARK: - UIColor 十六进制便捷构造
private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

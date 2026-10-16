import SwiftUI

/// 编辑工具栏：分切、复制、删除、撤销
/// 高 56pt，bgSecondary 背景，圆角 radiusM
/// 每个按钮 80pt 宽，禁用态 textSecondary opacity 0.4
struct EditToolbar: View {
    /// 分切是否可用（播放头位于片段内部，距两端 > 0.05s）
    let canSplit: Bool
    /// 复制是否可用（已选中片段）
    let canCopy: Bool
    /// 删除是否可用（至少保留 1 个片段）
    let canDelete: Bool
    /// 撤销是否可用
    let canUndo: Bool

    var onSplit: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ToolbarActionButton(
                icon: "scissors",
                title: "分切",
                isDisabled: !canSplit,
                action: onSplit
            )
            ToolbarActionButton(
                icon: "doc.on.doc",
                title: "复制",
                isDisabled: !canCopy,
                action: onCopy
            )
            ToolbarActionButton(
                icon: "trash",
                title: "删除",
                isDisabled: !canDelete,
                action: onDelete
            )
            ToolbarActionButton(
                icon: "arrow.uturn.backward",
                title: "撤销",
                isDisabled: !canUndo,
                action: onUndo
            )
        }
        .background(DesignTokens.Colors.bgSecondary)
        .cornerRadius(DesignTokens.Radius.m)
    }
}

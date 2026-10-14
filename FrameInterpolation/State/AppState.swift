import SwiftUI

/// 全局应用状态，主线程隔离，负责 UI 状态与 Toast 管理
@MainActor
final class AppState: ObservableObject {
    // MARK: - Toast 状态
    @Published var toastMessage: String?
    @Published var toastStyle: ToastStyle = .success

    // MARK: - 方法
    /// 显示 Toast，2 秒后自动消失
    func showToast(_ message: String, style: ToastStyle = .success) {
        toastMessage = message
        toastStyle = style
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastMessage = nil }
        }
    }
}

/// Toast 样式枚举
enum ToastStyle {
    case success
    case error
    case warning
}

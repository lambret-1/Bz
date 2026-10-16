import SwiftUI

/// 存储空间不足 Alert 修饰器
struct StorageAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let requiredMB: Int
    let availableMB: Int
    let onCleanCache: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("存储空间不足", isPresented: $isPresented) {
                Button("清理缓存") { onCleanCache() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("需约 \(requiredMB) MB，当前剩余 \(availableMB) MB。请清理空间后重试。")
            }
    }
}

extension View {
    func storageAlert(
        isPresented: Binding<Bool>,
        requiredMB: Int,
        availableMB: Int,
        onCleanCache: @escaping () -> Void
    ) -> some View {
        modifier(StorageAlertModifier(
            isPresented: isPresented,
            requiredMB: requiredMB,
            availableMB: availableMB,
            onCleanCache: onCleanCache
        ))
    }
}

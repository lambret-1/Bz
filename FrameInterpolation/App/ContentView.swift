import SwiftUI
import UserNotifications

/// 根视图，持有全局 AppState，承载首页
struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var showDraftRestoreAlert = false

    var body: some View {
        HomeView()
            .environmentObject(appState)
            .preferredColorScheme(nil) // 跟随系统深色/浅色模式
            .onAppear {
                // 请求通知权限（用于切后台提醒）
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

                // 检测是否有可恢复的草稿
                if appState.hasDraft {
                    showDraftRestoreAlert = true
                }
            }
            // 监听应用进入后台
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                appState.applicationDidEnterBackground()
            }
            .alert("发现未完成的草稿", isPresented: $showDraftRestoreAlert) {
                Button("恢复编辑") {
                    if appState.restoreDraftIfPossible() {
                        appState.showToast("草稿已恢复")
                    } else {
                        appState.showToast("草稿对应的视频文件已不存在", style: .error)
                    }
                }
                Button("丢弃草稿", role: .destructive) {
                    DraftStore.shared.clearDraft()
                }
                Button("稍后再说", role: .cancel) {}
            } message: {
                Text("检测到上次未完成的编辑，是否恢复？")
            }
    }
}

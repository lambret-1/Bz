import SwiftUI
import UserNotifications

/// 根视图，持有全局 AppState，承载首页导航栈
struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationStack {
            HomeView()
                .environmentObject(appState)
        }
        .preferredColorScheme(nil) // 跟随系统深色/浅色模式
        .onAppear {
            // 请求通知权限（用于切后台提醒）
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        // 监听应用进入后台
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appState.applicationDidEnterBackground()
        }
        // 监听应用回到前台
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            appState.applicationWillEnterForeground()
        }
    }
}

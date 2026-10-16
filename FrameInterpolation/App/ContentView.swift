import SwiftUI
import UserNotifications

/// 根视图，持有全局 AppState，承载首页导航栈
/// 右上角悬浮性能监控 HUD（FPS / CPU / 内存），可在设置中开关
struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var performanceMonitor = PerformanceMonitor()

    var body: some View {
        NavigationStack {
            HomeView()
                .environmentObject(appState)
        }
        .preferredColorScheme(nil) // 跟随系统深色/浅色模式
        .onAppear {
            // 请求通知权限（用于切后台提醒）
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            performanceMonitor.start()
        }
        .onDisappear {
            performanceMonitor.stop()
        }
        // 监听应用进入后台
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appState.applicationDidEnterBackground()
        }
        // 性能监控悬浮窗（设置中可开关）
        .overlay(alignment: .topTrailing) {
            if appState.showPerformanceHUD {
                PerformanceHUD(monitor: performanceMonitor)
                    .padding(.top, 4)
            }
        }
    }
}

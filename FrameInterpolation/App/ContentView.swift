import SwiftUI
import UserNotifications

/// 根视图，持有全局 AppState，承载首页导航栈
/// Debug 模式下右上角悬浮性能监控 HUD（FPS / CPU / 内存）
struct ContentView: View {
    @StateObject private var appState = AppState()
    #if DEBUG
    @StateObject private var performanceMonitor = PerformanceMonitor()
    #endif

    var body: some View {
        NavigationStack {
            HomeView()
                .environmentObject(appState)
        }
        .preferredColorScheme(nil) // 跟随系统深色/浅色模式
        .onAppear {
            // 请求通知权限（用于切后台提醒）
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            #if DEBUG
            performanceMonitor.start()
            #endif
        }
        .onDisappear {
            #if DEBUG
            performanceMonitor.stop()
            #endif
        }
        // 监听应用进入后台
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appState.applicationDidEnterBackground()
        }
        // Debug 性能监控悬浮窗
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            PerformanceHUD(monitor: performanceMonitor)
                .padding(.top, 4)
        }
        #endif
    }
}

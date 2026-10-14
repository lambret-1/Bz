import SwiftUI

/// 根视图，持有全局 AppState，承载首页导航栈
struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationStack {
            HomeView()
                .environmentObject(appState)
        }
        .preferredColorScheme(nil) // 跟随系统深色/浅色模式
    }
}

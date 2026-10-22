import SwiftUI

/// App 入口，全局唯一
@main
struct FrameInterpolationApp: App {
    init() {
        // 安装崩溃日志捕获器（Signal + NSException）
        CrashLogger.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

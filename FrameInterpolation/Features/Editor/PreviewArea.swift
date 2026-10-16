import SwiftUI
import AVKit

/// 视频预览区，强制黑色背景，16:9 比例
/// 直接使用 PlayerManager 单例，避免双 player 状态不同步
/// 监听 currentProject 变化，确保异步导入后能正确加载
struct PreviewArea: View {
    @EnvironmentObject var appState: AppState
    @State private var refreshID = UUID()  // 用于触发视图刷新
    @State private var hasLoaded = false   // 标记是否已尝试加载

    private var player: AVPlayer? {
        PlayerManager.shared.player
    }

    private var currentURL: URL? {
        appState.currentProject?.videoInfo.url
    }

    var body: some View {
        ZStack {
            Color.videoBg

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .id(refreshID)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(Color(uiColor: .systemGray))
                    if !hasLoaded {
                        Text("加载中…")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onAppear {
            loadPlayerIfNeeded()
        }
        // 监听项目变化（包括异步导入完成后的变化）
        .onChange(of: appState.currentProject?.id) { _ in
            loadPlayerIfNeeded()
        }
        // 监听 url 变化（兜底，防止 id 相同但 url 不同的情况）
        .onChange(of: currentURL?.lastPathComponent) { _ in
            loadPlayerIfNeeded()
        }
    }

    private func loadPlayerIfNeeded() {
        guard let url = currentURL else {
            // 项目尚未就绪，标记未加载，等待后续变化
            hasLoaded = false
            return
        }

        hasLoaded = true
        PlayerManager.shared.load(url: url)
        refreshID = UUID()
    }
}

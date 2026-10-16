import SwiftUI
import AVKit

/// 视频预览区
/// 使用 @ObservedObject 监听 PlayerManager，player 变化自动刷新
/// 不强制 16:9，根据可用空间自适应，避免上下大片黑边
struct PreviewArea: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var playerManager = PlayerManager.shared
    @State private var hasLoaded = false

    private var currentURL: URL? {
        appState.currentProject?.videoInfo.url
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.videoBg

                if let player = playerManager.player {
                    VideoPlayer(player: player)
                        .frame(width: geometry.size.width, height: geometry.size.height)
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
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200, maxHeight: .infinity)
        .onAppear {
            loadPlayerIfNeeded()
        }
        // 监听项目变化（异步导入完成后加载）
        .onChange(of: appState.currentProject?.id) { _ in
            loadPlayerIfNeeded()
        }
        .onChange(of: currentURL?.lastPathComponent) { _ in
            loadPlayerIfNeeded()
        }
    }

    private func loadPlayerIfNeeded() {
        guard let url = currentURL else {
            hasLoaded = false
            return
        }
        hasLoaded = true
        PlayerManager.shared.load(url: url)
    }
}

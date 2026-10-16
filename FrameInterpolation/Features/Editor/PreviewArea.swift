import SwiftUI
import AVKit

/// 视频预览区，强制黑色背景，16:9 比例
/// 直接使用 PlayerManager 单例，避免双 player 状态不同步
struct PreviewArea: View {
    @EnvironmentObject var appState: AppState
    @State private var refreshID = UUID()  // 用于触发视图刷新

    private var player: AVPlayer? {
        PlayerManager.shared.player
    }

    var body: some View {
        ZStack {
            Color.videoBg

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .id(refreshID)  // player实例变化时刷新
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 48))
                    .foregroundColor(Color(uiColor: .systemGray))
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onAppear {
            if let url = appState.currentProject?.videoInfo.url {
                PlayerManager.shared.load(url: url)
                refreshID = UUID()
            }
        }
        .onChange(of: appState.currentProject?.id) { _ in
            if let url = appState.currentProject?.videoInfo.url {
                PlayerManager.shared.load(url: url)
                refreshID = UUID()
            } else {
                PlayerManager.shared.release()
                refreshID = UUID()
            }
        }
    }
}

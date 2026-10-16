import SwiftUI
import AVKit

/// 视频预览区，强制黑色背景，16:9 比例
struct PreviewArea: View {
    @EnvironmentObject var appState: AppState
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.videoBg

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
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
                player = PlayerManager.shared.player
            }
        }
        .onChange(of: appState.currentProject?.id) { _ in
            if let url = appState.currentProject?.videoInfo.url {
                PlayerManager.shared.load(url: url)
                player = PlayerManager.shared.player
            } else {
                PlayerManager.shared.release()
                player = nil
            }
        }
    }
}

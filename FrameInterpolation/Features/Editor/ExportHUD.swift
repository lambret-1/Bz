import SwiftUI

/// 导出处理 HUD：环形进度 + 阶段文字 + 取消按钮
struct ExportHUD: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 24) {
                // 环形进度
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                        .frame(width: 160, height: 160)

                    Circle()
                        .trim(from: 0, to: CGFloat(appState.progress))
                        .stroke(
                            LinearGradient(
                                colors: [Color.accentPink, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 160, height: 160)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: appState.progress)

                    VStack(spacing: 4) {
                        Text("\(Int(appState.progress * 100))%")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text(appState.stage.rawValue)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                // 预计剩余时间
                Text(appState.progress > 0.05
                     ? "预计剩余时间：约 \(Int(appState.estimatedRemaining)) 秒"
                     : "预计剩余时间：计算中…")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                // 取消按钮
                Button {
                    appState.cancelProcessing()
                } label: {
                    Text("取消")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 120, height: 44)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(22)
                }
            }
            .padding(32)
            .background(Color(uiColor: .systemBackground).opacity(0.9))
            .cornerRadius(24)
            .shadow(radius: 20)
        }
    }
}

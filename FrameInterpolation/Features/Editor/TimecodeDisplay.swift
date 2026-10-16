import SwiftUI

/// 时间码/帧号显示组件，点击切换显示模式
struct TimecodeDisplay: View {
    let currentFrame: Int
    let totalFrames: Int
    let currentTime: TimeInterval
    let totalTime: TimeInterval
    let isFrameMode: Bool
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            if isFrameMode {
                if totalFrames > 0 {
                    Text("f\(String(format: "%03d", currentFrame)) / f\(String(format: "%03d", totalFrames))")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.accentPink)
                } else {
                    Text("加载中…")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(uiColor: .systemGray))
                }

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                        .clipped()
                }
            } else {
                if totalTime > 0 {
                    Text(formatTime(currentTime) + " / " + formatTime(totalTime))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.topBarText)
                } else {
                    Text("00:00.000 / --:--.---")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(uiColor: .systemGray))
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let ms = Int((time - floor(time)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, seconds, ms)
    }
}

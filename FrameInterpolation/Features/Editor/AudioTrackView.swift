import SwiftUI
import AVFoundation

/// 音频波形视图
struct AudioWaveformView: View {
    let url: URL
    let duration: TimeInterval
    let color: Color

    @State private var samples: [Float] = []

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    let barHeight = max(2, CGFloat(sample) * geometry.size.height)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(0.7))
                        .frame(width: 2, height: barHeight)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .onAppear { loadWaveform() }
    }

    private func loadWaveform() {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let frameCount = UInt32(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        try? file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return }

        let samplesPerPixel = max(1, Int(frameCount) / 200)
        var result: [Float] = []

        for i in stride(from: 0, to: Int(frameCount), by: samplesPerPixel) {
            var maxValue: Float = 0
            for j in 0..<samplesPerPixel {
                if i + j < Int(frameCount) {
                    maxValue = max(maxValue, abs(channelData[0][i + j]))
                }
            }
            result.append(maxValue)
        }
        samples = result
    }
}

/// 音频片段数据结构
struct AudioSegment: Identifiable {
    let id = UUID()
    let url: URL
    var offset: TimeInterval
    var duration: TimeInterval
}

/// 音频轨视图
struct AudioTrackView: View {
    let audioSegment: AudioSegment
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(uiColor: .tertiarySystemBackground))
                .frame(height: 44)
                .overlay(
                    AudioWaveformView(
                        url: audioSegment.url,
                        duration: audioSegment.duration,
                        color: Color.accentPink
                    )
                    .padding(.horizontal, 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentPink : Color.clear, lineWidth: 2)
                )
                .padding(.horizontal, 4)
        }
    }
}

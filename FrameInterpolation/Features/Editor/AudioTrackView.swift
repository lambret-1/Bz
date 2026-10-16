import SwiftUI
import AVFoundation

/// 音频波形视图（后台线程解码，混合左右声道）
struct AudioWaveformView: View {
    let url: URL
    let duration: TimeInterval
    let color: Color

    @State private var samples: [Float] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
        }
        .onAppear { loadWaveform() }
    }

    private func loadWaveform() {
        // 后台线程解码音频，避免主线程卡顿
        DispatchQueue.global(qos: .userInitiated).async {
            guard let file = try? AVAudioFile(forReading: url) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            let format = file.processingFormat
            let frameCount = UInt32(file.length)
            let channelCount = Int(format.channelCount)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            try? file.read(into: buffer)
            guard let channelData = buffer.floatChannelData else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            let samplesPerPixel = max(1, Int(frameCount) / 200)
            var result: [Float] = []

            for i in stride(from: 0, to: Int(frameCount), by: samplesPerPixel) {
                var maxValue: Float = 0
                for j in 0..<samplesPerPixel {
                    if i + j < Int(frameCount) {
                        // 混合左右声道：取所有声道的最大值
                        for channel in 0..<channelCount {
                            maxValue = max(maxValue, abs(channelData[channel][i + j]))
                        }
                    }
                }
                result.append(maxValue)
            }

            DispatchQueue.main.async {
                samples = result
                isLoading = false
            }
        }
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

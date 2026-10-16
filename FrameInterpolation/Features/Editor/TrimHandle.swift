import SwiftUI

/// 片段裁剪把手
struct TrimHandle: View {
    let isDragging: Bool
    let isAtBoundary: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isAtBoundary ? Color.red : Color.accentPink)
            .frame(width: 12, height: 60)
            .scaleEffect(isDragging ? 1.2 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isDragging)
    }
}

/// 片段裁剪覆盖层（左右把手）
struct SegmentTrimOverlay: View {
    @State private var leftDragging = false
    @State private var rightDragging = false
    let segment: VideoSegment
    let onTrim: (TimeInterval, TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TrimHandle(isDragging: leftDragging, isAtBoundary: segment.duration < 0.05)
                .gesture(
                    DragGesture()
                        .onChanged { _ in leftDragging = true }
                        .onEnded { value in
                            leftDragging = false
                            let delta = value.translation.width / 20.0
                            let newStart = max(0, segment.startTime + delta)
                            onTrim(newStart, segment.endTime)
                        }
                )

            Spacer()

            TrimHandle(isDragging: rightDragging, isAtBoundary: segment.duration < 0.05)
                .gesture(
                    DragGesture()
                        .onChanged { _ in rightDragging = true }
                        .onEnded { value in
                            rightDragging = false
                            let delta = value.translation.width / 20.0
                            let newEnd = segment.endTime + delta
                            onTrim(segment.startTime, newEnd)
                        }
                )
        }
        .frame(height: 80)
    }
}

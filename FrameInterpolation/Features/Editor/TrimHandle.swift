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

/// 片段裁剪覆盖层（左右把手，实时反馈）
struct SegmentTrimOverlay: View {
    @State private var leftDragging = false
    @State private var rightDragging = false
    let segment: VideoSegment
    let frameWidth: CGFloat  // 当前缩放级别下每帧宽度（pt）
    let fps: Double
    let onTrimChanged: (TimeInterval, TimeInterval) -> Void  // 实时回调
    let onTrimEnded: (TimeInterval, TimeInterval) -> Void    // 结束回调

    var body: some View {
        HStack(spacing: 0) {
            TrimHandle(isDragging: leftDragging, isAtBoundary: segment.duration < 0.05)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            leftDragging = true
                            // 实时计算：translation.width / frameWidth = 帧数，帧数/fps = 秒
                            let deltaSeconds = Double(value.translation.width / frameWidth) / fps
                            let newStart = max(0, segment.startTime + deltaSeconds)
                            onTrimChanged(newStart, segment.endTime)
                        }
                        .onEnded { value in
                            leftDragging = false
                            let deltaSeconds = Double(value.translation.width / frameWidth) / fps
                            let newStart = max(0, segment.startTime + deltaSeconds)
                            onTrimEnded(newStart, segment.endTime)
                        }
                )

            Spacer()

            TrimHandle(isDragging: rightDragging, isAtBoundary: segment.duration < 0.05)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            rightDragging = true
                            let deltaSeconds = Double(value.translation.width / frameWidth) / fps
                            let newEnd = segment.endTime + deltaSeconds
                            onTrimChanged(segment.startTime, newEnd)
                        }
                        .onEnded { value in
                            rightDragging = false
                            let deltaSeconds = Double(value.translation.width / frameWidth) / fps
                            let newEnd = segment.endTime + deltaSeconds
                            onTrimEnded(segment.startTime, newEnd)
                        }
                )
        }
        .frame(height: 80)
    }
}

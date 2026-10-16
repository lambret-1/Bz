import SwiftUI

/// 时间线视图：播放头进度条 + 片段卡片横向滚动列表
struct TimelineView: View {
    let segments: [VideoSegment]
    let duration: TimeInterval
    @Binding var currentTime: TimeInterval
    @Binding var selectedSegmentID: UUID?
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            // 播放头 + 时间码
            playbackHeader
            // 片段卡片列表
            segmentScroller
        }
    }

    // MARK: - 播放头
    private var playbackHeader: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Text(TimeFormatter.format(currentTime))
                .font(DesignTokens.Fonts.monoCaption)
                .foregroundColor(DesignTokens.Colors.accent)
                .frame(width: 50, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景轨道
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DesignTokens.Colors.bgTertiary)
                        .frame(height: 2)

                    // 已播放进度
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DesignTokens.Colors.accent)
                        .frame(width: max(0, min(geometry.size.width, progressWidth(in: geometry.size.width))), height: 2)

                    // 播放头圆点
                    Circle()
                        .fill(DesignTokens.Colors.accent)
                        .frame(width: 12, height: 12)
                        .offset(x: max(-6, min(geometry.size.width - 6, progressWidth(in: geometry.size.width) - 6)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = max(0, min(1, value.location.x / geometry.size.width))
                            let time = ratio * duration
                            currentTime = time
                            onSeek?(time)
                        }
                )
            }
            .frame(height: 20)

            Text(TimeFormatter.format(duration))
                .font(DesignTokens.Fonts.monoCaption)
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 32)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(currentTime / duration) * totalWidth
    }

    // MARK: - 片段卡片列表
    private var segmentScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.s) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    SegmentCard(
                        segment: segment,
                        index: index,
                        isSelected: selectedSegmentID == segment.id
                    )
                    .onTapGesture {
                        selectedSegmentID = segment.id
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: DesignTokens.segmentCardHeight)
    }
}

// MARK: - 片段卡片
/// 宽 100pt 高 70pt，缩略图 16:9 圆角 8，时长标签右下角
/// 选中态 2pt accent 边框
struct SegmentCard: View {
    let segment: VideoSegment
    let index: Int
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 缩略图
            RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                .fill(DesignTokens.Colors.bgTertiary)

            if let thumbnail = segment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 20))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            // 序号 + 时长
            VStack {
                HStack {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(3)
                    Spacer()
                }
                Spacer()
                Text(TimeFormatter.format(segment.duration))
                    .font(DesignTokens.Fonts.monoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(3)
                    .padding(4)
            }
            .padding(4)
        }
        .frame(width: DesignTokens.segmentCardWidth, height: DesignTokens.segmentCardHeight)
        .cornerRadius(DesignTokens.Radius.s)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.s)
                .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("片段\(index + 1)，时长\(TimeFormatter.format(segment.duration))\(isSelected ? "，已选中" : "")")
    }
}

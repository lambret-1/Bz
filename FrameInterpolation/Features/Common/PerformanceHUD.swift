import SwiftUI

// MARK: - 性能监控悬浮 HUD

/// 开发期性能监控悬浮窗：实时显示 FPS、CPU、内存
/// 仅在 Debug 构建中显示，可拖动调整位置，点击展开/收起
struct PerformanceHUD: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var isExpanded = true
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（点击展开/收起）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.medium")
                        .font(.caption2)
                    Text("性能")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    Text("\(monitor.fps) FPS")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(fpsColor)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
            }
            .buttonStyle(.plain)

            // 展开区域：CPU + 内存
            if isExpanded {
                Divider()
                VStack(spacing: 4) {
                    metricRow(
                        icon: "cpu",
                        label: "CPU",
                        value: String(format: "%.1f%%", monitor.cpuUsage),
                        color: cpuColor
                    )
                    metricRow(
                        icon: "memorychip",
                        label: "内存",
                        value: String(format: "%.1f MB", monitor.memoryUsageMB),
                        color: memoryColor
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        .offset(x: dragOffset.width, y: dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(
                        width: lastDragOffset.width + value.translation.width,
                        height: lastDragOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    lastDragOffset = dragOffset
                }
        )
        .padding(.top, 60) // 避开状态栏/导航栏
        .padding(.trailing, 12)
    }

    // MARK: - 指标行

    private func metricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundColor(color)
        }
    }

    // MARK: - 颜色判断

    private var fpsColor: Color {
        if monitor.fps >= 55 { return .green }
        if monitor.fps >= 30 { return .yellow }
        return .red
    }

    private var cpuColor: Color {
        if monitor.cpuUsage < 50 { return .green }
        if monitor.cpuUsage < 80 { return .yellow }
        return .red
    }

    private var memoryColor: Color {
        if monitor.memoryUsageMB < 200 { return .green }
        if monitor.memoryUsageMB < 400 { return .yellow }
        return .red
    }
}

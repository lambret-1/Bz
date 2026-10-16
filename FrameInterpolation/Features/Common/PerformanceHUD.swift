import SwiftUI

// MARK: - 性能监控悬浮 HUD

/// 开发期性能监控悬浮窗：实时显示 FPS、CPU、内存
/// 深色半透明背景，高对比度文字，可拖动调整位置，点击展开/收起
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
                HStack(spacing: 8) {
                    Image(systemName: "gauge.medium")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("性能")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Spacer(minLength: 4)
                    Text("\(monitor.fps)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(fpsColor)
                    Text("FPS")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 160)
            }
            .buttonStyle(.plain)

            // 展开区域：CPU + 内存
            if isExpanded {
                Divider()
                    .background(Color.white.opacity(0.15))
                VStack(spacing: 6) {
                    metricRow(
                        icon: "cpu",
                        label: "CPU",
                        value: String(format: "%.0f%%", monitor.cpuUsage),
                        color: cpuColor
                    )
                    metricRow(
                        icon: "memorychip",
                        label: "内存",
                        value: String(format: "%.0f MB", monitor.memoryUsageMB),
                        color: memoryColor
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
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
        .padding(.top, 60)
        .padding(.trailing, 12)
    }

    // MARK: - 指标行

    private func metricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
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

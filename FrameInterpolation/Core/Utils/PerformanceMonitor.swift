import Foundation
import UIKit
import Combine

// MARK: - 性能监控器

/// 实时性能监控：CPU 使用率、内存占用、FPS
/// 仅在开发阶段启用，Release 构建不占用资源
@MainActor
final class PerformanceMonitor: ObservableObject {
    /// CPU 使用率（0~100，多核总和可能超过 100）
    @Published private(set) var cpuUsage: Double = 0
    /// 内存占用（MB）
    @Published private(set) var memoryUsageMB: Double = 0
    /// 当前 FPS
    @Published private(set) var fps: Int = 0
    /// 监控是否已启动
    private(set) var isRunning = false

    // MARK: - 统计数据

    /// CPU 采样总和（用于计算平均值）
    private var cpuSum: Double = 0
    /// CPU 采样次数
    private var cpuSampleCount: Int = 0
    /// CPU 峰值
    private(set) var cpuPeak: Double = 0
    /// 内存采样总和
    private var memorySum: Double = 0
    /// 内存采样次数
    private var memorySampleCount: Int = 0
    /// 内存峰值（MB）
    private(set) var memoryPeak: Double = 0

    /// CPU 平均使用率（%）
    var cpuAverage: Double {
        cpuSampleCount > 0 ? cpuSum / Double(cpuSampleCount) : 0
    }
    /// 内存平均占用（MB）
    var memoryAverage: Double {
        memorySampleCount > 0 ? memorySum / Double(memorySampleCount) : 0
    }

    /// 重置统计数据（开始新任务前调用）
    func resetStatistics() {
        cpuSum = 0
        cpuSampleCount = 0
        cpuPeak = 0
        memorySum = 0
        memorySampleCount = 0
        memoryPeak = 0
    }

    // MARK: - 私有属性

    private var displayLink: CADisplayLink?
    private var fpsCount: Int = 0
    private var fpsLastTime: CFTimeInterval = 0
    private var updateTimer: Timer?
    /// 上一次 CPU 统计信息，用于计算增量
    private var previousCPUInfo: (userTime: UInt64, systemTime: UInt64)?

    // MARK: - 启动与停止

    /// 启动性能监控
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // FPS 计数（使用弱引用代理避免循环引用）
        let displayLinkProxy = DisplayLinkProxy { [weak self] link in
            self?.handleDisplayLink(link)
        }
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.handle(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // 保持代理引用
        objc_setAssociatedObject(link, &DisplayLinkProxy.associatedKey, displayLinkProxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // 每秒更新一次 CPU 和内存
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMetrics()
            }
        }
    }

    /// 停止性能监控
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        updateTimer?.invalidate()
        updateTimer = nil
        isRunning = false
        fpsCount = 0
        fpsLastTime = 0
        previousCPUInfo = nil
    }

    // MARK: - FPS 计数

    private func handleDisplayLink(_ link: CADisplayLink) {
        fpsCount += 1
        let now = CACurrentMediaTime()
        if fpsLastTime == 0 {
            fpsLastTime = now
            return
        }
        let elapsed = now - fpsLastTime
        if elapsed >= 1.0 {
            fps = Int(Double(fpsCount) / elapsed)
            fpsCount = 0
            fpsLastTime = now
        }
    }

    // MARK: - 更新 CPU 和内存

    private func updateMetrics() {
        cpuUsage = currentCPUUsage()
        memoryUsageMB = currentMemoryUsage()

        // 更新统计数据
        cpuSum += cpuUsage
        cpuSampleCount += 1
        if cpuUsage > cpuPeak { cpuPeak = cpuUsage }
        memorySum += memoryUsageMB
        memorySampleCount += 1
        if memoryUsageMB > memoryPeak { memoryPeak = memoryUsageMB }
    }

    /// 读取当前进程 CPU 使用率（%）
    private func currentCPUUsage() -> Double {
        var taskInfo = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }

        // 遍历所有线程计算 CPU 时间
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList, threadCount > 0 else { return 0 }
        defer {
            // 正确计算释放大小，避免 UInt32 乘法溢出
            let deallocSize = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), deallocSize)
        }

        var totalUserTime: UInt64 = 0
        var totalSystemTime: UInt64 = 0

        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let tkr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            guard tkr == KERN_SUCCESS else { continue }
            totalUserTime += UInt64(threadInfo.user_time.seconds) * 1_000_000 + UInt64(threadInfo.user_time.microseconds)
            totalSystemTime += UInt64(threadInfo.system_time.seconds) * 1_000_000 + UInt64(threadInfo.system_time.microseconds)
        }

        // 与上一次采样的差值计算 CPU 占比
        // 使用 subtractingReportingOverflow 避免 UInt64 下溢导致 SIGTRAP
        if let prev = previousCPUInfo {
            let userSub = totalUserTime.subtractingReportingOverflow(prev.userTime)
            let systemSub = totalSystemTime.subtractingReportingOverflow(prev.systemTime)

            // 如果发生下溢（线程重建导致时间回退），重置基准并返回0
            guard !userSub.overflow, !systemSub.overflow else {
                previousCPUInfo = (totalUserTime, totalSystemTime)
                return 0
            }

            let userDiff = Double(userSub.partialValue) / 1_000_000.0
            let systemDiff = Double(systemSub.partialValue) / 1_000_000.0
            let elapsed = 1.0 // 每秒采样一次
            let cpuPercent = ((userDiff + systemDiff) / elapsed) * 100.0
            previousCPUInfo = (totalUserTime, totalSystemTime)
            return min(cpuPercent, 999.0) // 多核可能超过 100，上限 999 显示
        } else {
            previousCPUInfo = (totalUserTime, totalSystemTime)
            return 0
        }
    }

    /// 读取当前进程内存占用（MB）
    private func currentMemoryUsage() -> Double {
        var taskInfo = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(taskInfo.resident_size) / 1024.0 / 1024.0
    }
}

// MARK: - CADisplayLink 弱引用代理

/// 用于打破 CADisplayLink 对 target 的强引用循环
private final class DisplayLinkProxy: NSObject {
    static var associatedKey = 0
    private let handler: (CADisplayLink) -> Void

    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func handle(_ link: CADisplayLink) {
        handler(link)
    }
}

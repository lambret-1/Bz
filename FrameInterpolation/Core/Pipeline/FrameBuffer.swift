import CoreVideo
import CoreMedia
import Foundation
import os

// MARK: - 处理后的帧

/// 已处理的视频帧，包含像素缓冲区和显示时间戳
struct ProcessedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

// MARK: - 高性能有界帧缓冲队列（DispatchSemaphore + os_unfair_lock）

/// 线程安全的有界帧缓冲队列，用于异步流水线中连接解码/推理与编码
/// 基于 DispatchSemaphore（用户态）+ os_unfair_lock（无内核态切换），性能远超 NSCondition
/// 实现背压：入队时若队列已满则阻塞等待，出队时若队列为空则阻塞等待
final class FrameBuffer {
    private let capacity: Int
    private var frames: [ProcessedFrame] = []
    private var lock = os_unfair_lock_s()
    private let notEmpty: DispatchSemaphore  // 消费者等这个
    private let notFull: DispatchSemaphore   // 生产者等这个
    private(set) var isClosed = false

    /// 统计信息
    private(set) var totalEnqueued = 0
    private(set) var totalDequeued = 0

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
        self.notEmpty = DispatchSemaphore(value: 0)
        self.notFull = DispatchSemaphore(value: capacity)
    }

    /// 入队一帧，若队列已满则阻塞等待
    /// - Returns: true 表示成功入队，false 表示队列已关闭
    @discardableResult
    func enqueue(_ frame: ProcessedFrame) -> Bool {
        notFull.wait()  // 满了就阻塞，等待消费者消费

        os_unfair_lock_lock(&lock)
        if isClosed {
            os_unfair_lock_unlock(&lock)
            notFull.signal()  // 恢复信号量，避免泄漏
            return false
        }
        frames.append(frame)
        totalEnqueued += 1
        os_unfair_lock_unlock(&lock)

        notEmpty.signal()  // 唤醒消费者
        return true
    }

    /// 出队一帧，若队列为空则阻塞等待
    /// - Returns: 帧，或 nil 表示队列已关闭且为空
    func dequeue() -> ProcessedFrame? {
        notEmpty.wait()  // 空了就阻塞，等待生产者生产

        os_unfair_lock_lock(&lock)
        if isClosed && frames.isEmpty {
            os_unfair_lock_unlock(&lock)
            notEmpty.signal()  // 恢复信号量，唤醒其他等待者
            return nil
        }
        let frame = frames.removeFirst()
        totalDequeued += 1
        os_unfair_lock_unlock(&lock)

        notFull.signal()  // 唤醒生产者
        return frame
    }

    /// 关闭队列，唤醒所有等待的线程（正常结束时调用，不丢弃已入队的帧）
    func close() {
        os_unfair_lock_lock(&lock)
        isClosed = true
        os_unfair_lock_unlock(&lock)

        // 唤醒所有在等 notFull 的生产者：它们会看到 isClosed 后退出
        for _ in 0..<capacity { notFull.signal() }
        // 多唤醒一次 notEmpty，让消费者消费完剩余帧后醒来发现队列已空再退出
        for _ in 0..<(capacity + 1) { notEmpty.signal() }
    }

    /// 当前队列中的帧数
    var count: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.count
    }

    /// 队列是否为空
    var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.isEmpty
    }
}

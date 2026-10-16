import CoreVideo
import Foundation

// MARK: - 处理后的帧

/// 已处理的视频帧，包含像素缓冲区和显示时间戳
struct ProcessedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

// MARK: - 线程安全有界帧缓冲队列

/// 线程安全的有界帧缓冲队列，用于异步流水线中连接解码/推理与编码
/// 实现背压：入队时若队列已满则阻塞等待，出队时若队列为空则阻塞等待
final class FrameBuffer {
    private let capacity: Int
    private var frames: [ProcessedFrame] = []
    private let lock = NSLock()
    private let notEmpty = NSCondition()
    private let notFull = NSCondition()
    private(set) var isClosed = false

    /// 统计信息
    private(set) var totalEnqueued = 0
    private(set) var totalDequeued = 0

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// 入队一帧，若队列已满则阻塞等待
    /// - Returns: true 表示成功入队，false 表示队列已关闭
    @discardableResult
    func enqueue(_ frame: ProcessedFrame) -> Bool {
        notFull.lock()
        defer { notFull.unlock() }

        while frames.count >= capacity && !isClosed {
            notFull.wait()
        }

        guard !isClosed else { return false }

        lock.lock()
        frames.append(frame)
        totalEnqueued += 1
        lock.unlock()

        notEmpty.signal()
        return true
    }

    /// 出队一帧，若队列为空则阻塞等待
    /// - Returns: 帧，或 nil 表示队列已关闭且为空
    func dequeue() -> ProcessedFrame? {
        notEmpty.lock()
        defer { notEmpty.unlock() }

        while frames.isEmpty && !isClosed {
            notEmpty.wait()
        }

        if frames.isEmpty { return nil }

        lock.lock()
        let frame = frames.removeFirst()
        totalDequeued += 1
        lock.unlock()

        notFull.signal()
        return frame
    }

    /// 关闭队列，唤醒所有等待的线程
    func close() {
        notFull.lock()
        notEmpty.lock()
        isClosed = true
        notEmpty.broadcast()
        notFull.broadcast()
        notEmpty.unlock()
        notFull.unlock()
    }

    /// 当前队列中的帧数
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// 队列是否为空
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty
    }
}

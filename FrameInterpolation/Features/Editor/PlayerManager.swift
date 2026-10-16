import AVFoundation
import Combine

/// AVPlayer 单例管理，ObservableObject，编辑器全局共享
/// player 变化时自动通知所有订阅视图，解决时序错乱
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    /// 当前播放器实例（@Published 变化时自动刷新视图）
    @Published private(set) var player: AVPlayer?

    /// 播放状态（@Published 供视图直接绑定）
    @Published private(set) var isPlaying = false

    /// 当前播放时间（周期性更新）
    @Published private(set) var currentTime: TimeInterval = 0

    /// 总时长
    @Published private(set) var duration: TimeInterval = 0

    /// 已注册的时间观察者列表（load/release时自动清理）
    private var timeObservers: [Any] = []
    private var timeControlObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var periodicObserver: Any?

    private init() {}

    /// 加载视频到播放器（自动清理旧观察者，@Published 触发视图刷新）
    func load(url: URL) {
        cleanupAllObservers()
        player?.pause()
        isPlaying = false
        currentTime = 0
        duration = 0

        let newPlayer = AVPlayer(url: url)
        player = newPlayer

        // 观察播放状态
        timeControlObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                self?.isPlaying = change.newValue == .playing
            }
        }

        // 观察总时长
        if let item = newPlayer.currentItem {
            durationObserver = item.observe(\.duration, options: [.new]) { [weak self] _, change in
                if let newDuration = change.newValue, newDuration.seconds > 0 {
                    DispatchQueue.main.async {
                        self?.duration = newDuration.seconds
                    }
                }
            }
            // 已加载完成则直接读取
            if item.status == .readyToPlay && item.duration.seconds > 0 {
                duration = item.duration.seconds
            }
        }

        // 周期性时间观察者（20fps 刷新）
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        periodicObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    /// 释放播放器
    func release() {
        cleanupAllObservers()
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// 播放/暂停切换
    func togglePlayback() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// 播放
    func play() {
        player?.play()
    }

    /// 暂停
    func pause() {
        player?.pause()
    }

    /// 跳转到指定时间
    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 跳转到指定帧
    func seek(toFrame frame: Int, fps: Double) {
        seek(to: Double(frame) / fps)
    }

    // MARK: - 观察者管理

    /// 添加外部周期性时间观察者（纳入统一管理）
    func addPeriodicTimeObserver(interval: TimeInterval, queue: DispatchQueue = .main, handler: @escaping (TimeInterval) -> Void) -> Any {
        let cmInterval = CMTime(seconds: interval, preferredTimescale: 600)
        if let observer = player?.addPeriodicTimeObserver(forInterval: cmInterval, queue: queue, using: { time in
            handler(CMTimeGetSeconds(time))
        }) {
            timeObservers.append(observer)
            return observer
        }
        return NSObject()
    }

    /// 移除指定时间观察者
    func removeTimeObserver(_ observer: Any) {
        player?.removeTimeObserver(observer)
        timeObservers.removeAll { ($0 as AnyObject) === (observer as AnyObject) }
    }

    /// 清理所有观察者
    private func cleanupAllObservers() {
        for observer in timeObservers {
            player?.removeTimeObserver(observer)
        }
        timeObservers.removeAll()

        if let periodic = periodicObserver {
            player?.removeTimeObserver(periodic)
        }
        periodicObserver = nil

        timeControlObserver?.invalidate()
        timeControlObserver = nil
        durationObserver?.invalidate()
        durationObserver = nil
    }
}

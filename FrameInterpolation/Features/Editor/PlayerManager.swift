import AVFoundation

/// AVPlayer 单例管理，编辑器全局共享一个播放器实例
final class PlayerManager {
    static let shared = PlayerManager()
    private(set) var player: AVPlayer?

    /// 已注册的时间观察者列表（load/release时自动清理）
    private var timeObservers: [Any] = []

    private init() {}

    /// 加载视频到播放器（自动清理旧观察者）
    func load(url: URL) {
        // 清理旧播放器的所有观察者
        cleanupObservers()
        player?.pause()
        player = AVPlayer(url: url)
    }

    /// 释放播放器（自动清理观察者）
    func release() {
        cleanupObservers()
        player?.pause()
        player = nil
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

    /// 当前播放时间
    var currentTime: TimeInterval {
        guard let player = player else { return 0 }
        return CMTimeGetSeconds(player.currentTime())
    }

    /// 总时长
    var duration: TimeInterval {
        guard let item = player?.currentItem else { return 0 }
        return CMTimeGetSeconds(item.duration)
    }

    /// 跳转到指定时间
    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 添加周期性时间观察者（自动纳入管理，load/release时清理）
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

    /// 清理所有已注册的观察者
    private func cleanupObservers() {
        for observer in timeObservers {
            player?.removeTimeObserver(observer)
        }
        timeObservers.removeAll()
    }
}

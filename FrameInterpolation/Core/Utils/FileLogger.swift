import Foundation

class FileLogger {
    static let shared = FileLogger()
    private let logFileName = "ESRGAN_Debug_Log.txt"
    private var logFileURL: URL?
    private let queue = DispatchQueue(label: "com.filelogger.queue")
    
    private init() {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            logFileURL = dir.appendingPathComponent(logFileName)
            // 每次启动时清空旧日志，确保我们看到的都是最新一次运行的记录
            try? "=== 启动新日志 ===\n".write(to: logFileURL!, atomically: true, encoding: .utf8)
        }
    }
    
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let fullMessage = "[\(time)][\(fileName):\(line)] \(message)\n"
        
        // 确保在后台队列写入，不卡顿主线程
        queue.async {
            guard let url = self.logFileURL else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = fullMessage.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try? fullMessage.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

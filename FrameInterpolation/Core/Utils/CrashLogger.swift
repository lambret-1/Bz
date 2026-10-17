import Foundation
import UIKit

// MARK: - 崩溃日志模型

/// 单条崩溃日志记录
struct CrashLog: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let crashType: String
    let crashReason: String
    let deviceModel: String
    let systemVersion: String
    let deviceName: String
    let screenSize: String
    let screenScale: String
    let appName: String
    let appVersion: String
    let buildVersion: String
    let bundleID: String
    let callStack: [String]

    /// 格式化输出为文本报告
    var formattedReport: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timeStr = dateFormatter.string(from: timestamp)

        var report = ""
        report += "========================================\n"
        report += "崩溃日志\n"
        report += "========================================\n"
        report += "崩溃时间: \(timeStr)\n"
        report += "崩溃类型: \(crashType)\n"
        report += "崩溃原因: \(crashReason)\n"
        report += "\n"
        report += "----------------------------------------\n"
        report += "设备信息\n"
        report += "----------------------------------------\n"
        report += "设备型号: \(deviceModel)\n"
        report += "系统版本: \(systemVersion)\n"
        report += "设备名称: \(deviceName)\n"
        report += "屏幕尺寸: \(screenSize)\n"
        report += "屏幕缩放: \(screenScale)\n"
        report += "\n"
        report += "----------------------------------------\n"
        report += "应用信息\n"
        report += "----------------------------------------\n"
        report += "应用名称: \(appName)\n"
        report += "应用版本: \(appVersion)\n"
        report += "构建版本: \(buildVersion)\n"
        report += "Bundle ID: \(bundleID)\n"
        report += "\n"
        report += "----------------------------------------\n"
        report += "调用栈\n"
        report += "----------------------------------------\n"
        for (index, frame) in callStack.enumerated() {
            report += "\(index)\t\(frame)\n"
        }
        report += "\n"
        report += "========================================\n"
        report += "崩溃日志结束\n"
        report += "========================================\n"
        return report
    }
}

// MARK: - 崩溃日志管理器

/// 崩溃日志捕获与管理
/// 捕获 Signal 异常和 NSException，保存格式化日志到本地
final class CrashLogger {
    static let shared = CrashLogger()

    private let fileManager = FileManager.default
    private let logsDirectory: URL
    private let maxLogs = 20

    private init() {
        // 创建崩溃日志存储目录
        let docsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logsDirectory = docsPath.appendingPathComponent("CrashLogs", isDirectory: true)
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - 安装崩溃处理器

    /// 安装 Signal 和 NSException 处理器，应在 App 启动时调用
    func install() {
        installSignalHandlers()
        installNSExceptionHandler()
    }

    // MARK: - Signal 处理

    private func installSignalHandlers() {
        let signals: [Int32] = [
            SIGABRT, // 6  程序中止
            SIGBUS,  // 10 总线错误
            SIGFPE,  // 8  浮点异常
            SIGILL,  // 4  非法指令
            SIGSEGV, // 11 段错误
            SIGTRAP  // 5  陷阱（Swift 运行时崩溃）
        ]

        for signal in signals {
            signal(signal) { sig in
                CrashLogger.shared.handleSignal(sig)
            }
        }
    }

    private func handleSignal(_ signal: Int32) {
        let signalNames: [Int32: String] = [
            SIGABRT: "SIGABRT",
            SIGBUS: "SIGBUS",
            SIGFPE: "SIGFPE",
            SIGILL: "SIGILL",
            SIGSEGV: "SIGSEGV",
            SIGTRAP: "SIGTRAP"
        ]
        let signalName = signalNames[signal] ?? "Signal \(signal)"
        let reason = "Signal \(signal) (\(signalName))"

        saveCrashLog(type: "Signal", reason: reason)

        // 重新抛出信号，让系统生成标准崩溃报告
        signal(signal, SIG_DFL)
        raise(signal)
    }

    // MARK: - NSException 处理

    private func installNSExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            CrashLogger.shared.handleNSException(exception)
        }
    }

    private func handleNSException(_ exception: NSException) {
        let reason = exception.reason ?? "未知异常"
        let type = "NSException (\(exception.name.rawValue))"
        saveCrashLog(type: type, reason: reason, customStack: exception.callStackSymbols)

        // 重新抛出
        exception.raise()
    }

    // MARK: - 保存崩溃日志

    private func saveCrashLog(type: String, reason: String, customStack: [String]? = nil) {
        let callStack = customStack ?? getCurrentCallStack()

        let device = UIDevice.current
        let screen = UIScreen.main

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Unknown"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "Unknown"

        let log = CrashLog(
            id: UUID(),
            timestamp: Date(),
            crashType: type,
            crashReason: reason,
            deviceModel: device.model,
            systemVersion: "\(device.systemName) \(device.systemVersion)",
            deviceName: device.name,
            screenSize: "\(screen.bounds.width) x \(screen.bounds.height)",
            screenScale: "\(screen.scale)",
            appName: appName,
            appVersion: appVersion,
            buildVersion: buildVersion,
            bundleID: bundleID,
            callStack: callStack
        )

        // 编码并保存
        if let data = try? JSONEncoder().encode(log) {
            let fileName = "crash_\(Int(Date().timeIntervalSince1970)).json"
            let fileURL = logsDirectory.appendingPathComponent(fileName)
            try? data.write(to: fileURL)

            // 清理旧日志，保留最新的 maxLogs 条
            cleanupOldLogs()
        }
    }

    // MARK: - 获取调用栈

    private func getCurrentCallStack() -> [String] {
        // 使用 backtrace 符号化调用栈
        return Thread.callStackSymbols
    }

    // MARK: - 读取崩溃日志

    /// 读取所有已保存的崩溃日志，按时间倒序排列
    func loadAllLogs() -> [CrashLog] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        var logs: [CrashLog] = []

        for file in jsonFiles {
            if let data = try? Data(contentsOf: file),
               let log = try? JSONDecoder().decode(CrashLog.self, from: data) {
                logs.append(log)
            }
        }

        // 按时间倒序
        logs.sort { $0.timestamp > $1.timestamp }
        return logs
    }

    /// 崩溃日志数量
    var logCount: Int {
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "json" }.count
    }

    // MARK: - 导出崩溃日志

    /// 将所有崩溃日志导出为单个文本文件，返回文件 URL
    func exportAllLogs() -> URL? {
        let logs = loadAllLogs()
        guard !logs.isEmpty else { return nil }

        var combinedReport = ""
        for (index, log) in logs.enumerated() {
            if index > 0 {
                combinedReport += "\n\n"
            }
            combinedReport += log.formattedReport
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "crash_logs_\(dateFormatter.string(from: Date())).txt"
        let fileURL = logsDirectory.appendingPathComponent(fileName)

        do {
            try combinedReport.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - 清除崩溃日志

    /// 清除所有崩溃日志
    func clearAllLogs() {
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    /// 删除单条崩溃日志
    func deleteLog(_ log: CrashLog) {
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let decoded = try? JSONDecoder().decode(CrashLog.self, from: data),
               decoded.id == log.id {
                try? fileManager.removeItem(at: file)
                break
            }
        }
    }

    // MARK: - 清理旧日志

    private func cleanupOldLogs() {
        let logs = loadAllLogs()
        if logs.count > maxLogs {
            let toDelete = Array(logs[maxLogs...])
            for log in toDelete {
                deleteLog(log)
            }
        }
    }
}

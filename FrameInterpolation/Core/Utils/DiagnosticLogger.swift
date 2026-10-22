import Foundation
import OSLog

// MARK: - 诊断日志文件写入器

/// 管线诊断日志写入器，将耗时统计等诊断信息写入沙盒文件
/// 文件路径：Documents/Diagnostics/pipeline_时间戳.txt
/// 可通过「文件」App 或 App 内设置页查看
final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    private let logger = Logger(subsystem: "com.lambret.bz", category: "DiagnosticLogger")
    private var fileHandle: FileHandle?
    private var logFilePath: URL?

    /// 诊断目录路径
    var diagnosticsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private init() {
        createDiagnosticsDirectory()
    }

    // MARK: - 公开方法

    /// 开始一次新的诊断会话（创建新文件）
    func startSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "pipeline_\(formatter.string(from: Date())).txt"
        let filePath = diagnosticsDirectory.appendingPathComponent(fileName)

        FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)
        fileHandle = try? FileHandle(forWritingTo: filePath)
        logFilePath = filePath

        writeLine("========================================")
        writeLine("管线诊断日志")
        writeLine("开始时间: \(Date())")
        writeLine("========================================")
        logger.info("诊断日志已创建: \(fileName, privacy: .public)")
    }

    /// 写入一行日志
    func writeLine(_ line: String) {
        guard let handle = fileHandle else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            logger.error("写入诊断日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 结束会话
    func endSession() {
        writeLine("========================================")
        writeLine("结束时间: \(Date())")
        writeLine("========================================")
        try? fileHandle?.close()
        fileHandle = nil
        if let path = logFilePath {
            logger.info("诊断日志已保存: \(path.lastPathComponent, privacy: .public)")
        }
    }

    /// 获取所有诊断日志文件列表
    func listLogFiles() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.sorted { (url1, url2) -> Bool in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }
    }

    /// 读取指定日志文件内容
    func readLogFile(at url: URL) -> String {
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取文件"
    }

    /// 删除指定日志文件
    func deleteLogFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 清理所有诊断日志
    func clearAllLogs() {
        let files = listLogFiles()
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 私有方法

    private func createDiagnosticsDirectory() {
        if !FileManager.default.fileExists(atPath: diagnosticsDirectory.path) {
            try? FileManager.default.createDirectory(
                at: diagnosticsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}

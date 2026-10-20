import SwiftUI

/// 应用设置页（独立 NavigationStack，全屏展示）
/// 包含通用、性能、存储、崩溃日志、关于等设置项
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    // 通用设置（持久化到 UserDefaults）
    @AppStorage("darkMode") private var darkMode = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("backgroundProcessing") private var backgroundProcessing = false

    // 性能设置
    @AppStorage("defaultResolution") private var defaultResolution = "自动"
    @AppStorage("defaultMultiplier") private var defaultMultiplier = "2x"

    // 崩溃日志
    @State private var crashLogs: [CrashLog] = []
    @State private var cacheSize = "计算中..."
    @State private var showClearCacheConfirm = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                // MARK: 通用
                Section("通用") {
                    Toggle("深色模式", isOn: $darkMode)
                    Toggle("触觉反馈", isOn: $hapticsEnabled)
                    Toggle("后台处理", isOn: $backgroundProcessing)
                }

                // MARK: 性能
                Section("性能") {
                    Picker("默认分辨率", selection: $defaultResolution) {
                        Text("自动").tag("自动")
                        Text("720p").tag("720p")
                        Text("1080p").tag("1080p")
                    }
                    Picker("默认补帧倍数", selection: $defaultMultiplier) {
                        Text("2x").tag("2x")
                        Text("4x").tag("4x")
                    }
                }

                // MARK: 存储
                Section("存储") {
                    HStack {
                        Text("缓存大小")
                        Spacer()
                        Text(cacheSize)
                            .foregroundColor(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除缓存")
                        }
                    }
                }

                // MARK: 崩溃日志
                Section {
                    NavigationLink {
                        CrashLogListView(crashLogs: $crashLogs)
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("崩溃日志报告")
                            Spacer()
                            if crashLogs.count > 0 {
                                Text("\(crashLogs.count) 条")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("自动捕获应用崩溃时的调用栈与设备信息，便于问题定位")
                }

                // MARK: 关于
                Section("关于") {
                    HStack {
                        Text("应用名称")
                        Spacer()
                        Text(appName)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("构建版本")
                        Spacer()
                        Text(buildVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(bundleID)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadCrashLogs()
                calculateCacheSize()
            }
            .alert("清除缓存", isPresented: $showClearCacheConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    clearCache()
                    appState.showToast("缓存已清除")
                }
            } message: {
                Text("将清除临时缓存文件，不影响已处理的视频。")
            }
        }
    }

    // MARK: - 应用信息

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "AI 补帧"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    // MARK: - 崩溃日志

    private func loadCrashLogs() {
        crashLogs = CrashLogger.shared.loadAllLogs()
    }

    // MARK: - 缓存管理

    private func calculateCacheSize() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let cachePaths = [
                fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
                fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("CrashLogs")
            ]

            var totalSize: Int64 = 0
            for path in cachePaths.compactMap({ $0 }) {
                totalSize += directorySize(at: path)
            }

            let sizeMB = Double(totalSize) / (1024 * 1024)
            DispatchQueue.main.async {
                if sizeMB < 1 {
                    cacheSize = String(format: "%.0f KB", sizeMB * 1024)
                } else {
                    cacheSize = String(format: "%.1f MB", sizeMB)
                }
            }
        }
    }

    private func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func clearCache() {
        let fileManager = FileManager.default
        let cacheURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cacheURL = cacheURL {
            if let files = try? fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
        calculateCacheSize()
    }
}

// MARK: - 崩溃日志列表页

struct CrashLogListView: View {
    @Binding var crashLogs: [CrashLog]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            if crashLogs.isEmpty {
                Text("暂无崩溃日志")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ForEach(crashLogs) { log in
                    NavigationLink {
                        CrashLogDetailView(crashLog: log)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.crashType)
                                .font(.subheadline.weight(.medium))
                            Text(log.crashReason)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(dateFormatter.string(from: log.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: deleteCrashLog)
            }
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !crashLogs.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        clearAllLogs()
                    } label: {
                        Text("清除")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .onAppear {
            crashLogs = CrashLogger.shared.loadAllLogs()
        }
    }

    private func deleteCrashLog(at offsets: IndexSet) {
        for index in offsets {
            CrashLogger.shared.deleteLog(crashLogs[index])
        }
        crashLogs = CrashLogger.shared.loadAllLogs()
    }

    private func clearAllLogs() {
        CrashLogger.shared.clearAllLogs()
        crashLogs = []
    }
}

// MARK: - 崩溃日志详情页（纯文本展示）

struct CrashLogDetailView: View {
    let crashLog: CrashLog

    var body: some View {
        ScrollView {
            Text(crashLog.formattedReport)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("崩溃详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: crashLog.formattedReport) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}

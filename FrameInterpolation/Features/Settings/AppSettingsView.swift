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
    @State private var showingCrashDetail = false
    @State private var selectedCrashLog: CrashLog?
    @State private var showingExportSheet = false
    @State private var exportedFileURL: URL?
    @State private var cacheSize = "计算中..."

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
                        clearCache()
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
                        CrashLogListView(
                            crashLogs: $crashLogs,
                            showingCrashDetail: $showingCrashDetail,
                            selectedCrashLog: $selectedCrashLog
                        )
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
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportedFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(isPresented: $showingCrashDetail) {
                if let log = selectedCrashLog {
                    CrashLogDetailView(crashLog: log)
                }
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
    @Binding var showingCrashDetail: Bool
    @Binding var selectedCrashLog: CrashLog?
    @State private var showingExportSheet = false
    @State private var exportedFileURL: URL?

    var body: some View {
        List {
            if crashLogs.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("暂无崩溃日志")
                            .font(.headline)
                        Text("应用运行稳定，未捕获到崩溃")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                ForEach(crashLogs) { log in
                    Button {
                        selectedCrashLog = log
                        showingCrashDetail = true
                    } label: {
                        crashLogRow(log: log)
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
                    Menu {
                        Button {
                            exportAllLogs()
                        } label: {
                            Label("导出全部", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            clearAllLogs()
                        } label: {
                            Label("清除全部", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            if let url = exportedFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .onAppear {
            crashLogs = CrashLogger.shared.loadAllLogs()
        }
    }

    private func crashLogRow(log: CrashLog) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd HH:mm:ss"

        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)

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
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func deleteCrashLog(at offsets: IndexSet) {
        for index in offsets {
            let log = crashLogs[index]
            CrashLogger.shared.deleteLog(log)
        }
        crashLogs = CrashLogger.shared.loadAllLogs()
    }

    private func clearAllLogs() {
        CrashLogger.shared.clearAllLogs()
        crashLogs = []
    }

    private func exportAllLogs() {
        if let url = CrashLogger.shared.exportAllLogs() {
            exportedFileURL = url
            showingExportSheet = true
        }
    }
}

// MARK: - 崩溃日志详情页

struct CrashLogDetailView: View {
    let crashLog: CrashLog
    @Environment(\.dismiss) private var dismiss
    @State private var showingExportSheet = false
    @State private var exportedFileURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 摘要卡片
                    summaryCard

                    // 设备信息
                    infoSection(title: "设备信息", items: [
                        ("设备型号", crashLog.deviceModel),
                        ("系统版本", crashLog.systemVersion),
                        ("设备名称", crashLog.deviceName),
                        ("屏幕尺寸", crashLog.screenSize),
                        ("屏幕缩放", crashLog.screenScale)
                    ])

                    // 应用信息
                    infoSection(title: "应用信息", items: [
                        ("应用名称", crashLog.appName),
                        ("应用版本", crashLog.appVersion),
                        ("构建版本", crashLog.buildVersion),
                        ("Bundle ID", crashLog.bundleID)
                    ])

                    // 调用栈
                    callStackSection
                }
                .padding()
            }
            .navigationTitle("崩溃详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        exportLog()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportedFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }

    private var summaryCard: some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(crashLog.crashType)
                    .font(.headline)
            }
            Text(crashLog.crashReason)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("崩溃时间: \(dateFormatter.string(from: crashLog.timestamp))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func infoSection(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.0) { key, value in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(value)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var callStackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("调用栈")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(crashLog.callStack.enumerated()), id: \.offset) { index, frame in
                        Text("\(index)\t\(frame)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func exportLog() {
        let text = crashLog.formattedReport
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash_\(Int(crashLog.timestamp.timeIntervalSince1970)).txt")
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            exportedFileURL = tempURL
            showingExportSheet = true
        } catch {
            // 导出失败
        }
    }
}

// MARK: - 分享 Sheet 封装

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

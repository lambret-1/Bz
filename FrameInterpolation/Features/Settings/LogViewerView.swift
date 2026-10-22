import SwiftUI
import OSLog

// MARK: - 日志条目

struct LogItem: Identifiable {
    let id = UUID()
    let date: Date
    let category: String
    let level: String
    let message: String
}

// MARK: - 日志读取器

@MainActor
final class LogReader: ObservableObject {
    @Published var items: [LogItem] = []
    @Published var filter: String = ""
    @Published var lastError: String?

    func refresh() {
        lastError = nil
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let pos = store.position(timeIntervalSinceLatestBoot: 1)
            let raw = try store.getEntries(at: pos)

            var result: [LogItem] = []
            for entry in raw {
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem == "com.lambret.bz" else { continue }
                let msg = log.composedMessage
                if !filter.isEmpty,
                   !msg.localizedCaseInsensitiveContains(filter),
                   !log.category.localizedCaseInsensitiveContains(filter) {
                    continue
                }
                result.append(LogItem(
                    date: log.date,
                    category: log.category,
                    level: Self.name(of: log.level),
                    message: msg
                ))
            }
            items = result
        } catch {
            lastError = "\(error)"
        }
    }

    private static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .notice:  return "NOTICE"
        case .error:   return "ERROR"
        case .fault:   return "FAULT"
        default:       return "?"
        }
    }

    var allText: String {
        items.map {
            "[\($0.date.formatted(date: .omitted, time: .standard))] [\($0.level)] [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }
}

// MARK: - 日志查看页

struct LogViewerView: View {
    @StateObject private var reader = LogReader()
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("过滤关键字", text: $reader.filter)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .onSubmit { reader.refresh() }

                Button("刷新") { reader.refresh() }
                Button("复制全部") {
                    UIPasteboard.general.string = reader.allText
                    copied = true
                }
                .disabled(reader.items.isEmpty)
            }
            .padding(.horizontal)

            if let err = reader.lastError {
                Text("读取失败: \(err)")
                    .font(.caption).foregroundColor(.red)
                    .padding(.horizontal)
            }

            List(reader.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.category).font(.caption2).foregroundColor(.secondary)
                        Text(item.level)
                            .font(.caption2).bold()
                            .foregroundColor(item.level == "ERROR" || item.level == "FAULT" ? .red : .secondary)
                        Spacer()
                        Text(item.date, style: .time).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(item.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .refreshable { reader.refresh() }
        }
        .navigationTitle("日志 (\(reader.items.count))")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reader.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { reader.refresh() }
        .alert("已复制到剪贴板", isPresented: $copied) { Button("好", role: .cancel) {} }
    }
}

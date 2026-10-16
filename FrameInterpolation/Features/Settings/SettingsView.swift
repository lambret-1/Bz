import SwiftUI

/// 应用设置页（独立 NavigationStack，全屏展示）
/// 通用设置、默认导出设置、存储管理、关于
/// 左上角返回按钮 + 支持边缘左滑手势返回
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        NavigationStack {
            List {
                // 通用
                Section("通用") {
                    Toggle("触觉反馈", isOn: $appState.hapticFeedbackEnabled)
                    Toggle("处理时屏幕常亮", isOn: $appState.keepScreenAwake)
                }

                // 默认导出设置
                Section("默认导出设置") {
                    Picker("默认编码", selection: $appState.defaultCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("默认码率模式", selection: $appState.defaultBitrateMode) {
                        ForEach(BitrateMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("默认容器", selection: $appState.defaultContainer) {
                        ForEach(ContainerFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // 存储
                Section("存储") {
                    HStack {
                        Text("缓存大小")
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                        Spacer()
                        Text(String(format: "%.1f MB", appState.cacheSizeMB))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    Button {
                        appState.clearCache()
                    } label: {
                        HStack {
                            Text("清除缓存")
                                .foregroundColor(DesignTokens.Colors.error)
                            Spacer()
                            Image(systemName: "trash")
                                .foregroundColor(DesignTokens.Colors.error)
                        }
                    }
                }

                // 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                        Spacer()
                        Text("v\(appVersion)")
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }

                    Link(destination: URL(string: "https://github.com/lambret-1/Bz")!) {
                        HStack {
                            Text("GitHub 仓库")
                                .foregroundColor(DesignTokens.Colors.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                    }
                }
            }
            .background(DesignTokens.Colors.bgPrimary)
            .scrollContentBackground(.hidden)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
            // Toast
            .overlay(alignment: .top) {
                if let message = appState.toastMessage {
                    ToastView(message: message, style: appState.toastStyle)
                        .padding(.top, DesignTokens.Spacing.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

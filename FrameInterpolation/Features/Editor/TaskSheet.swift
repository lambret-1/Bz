import SwiftUI

/// 任务选择 Sheet：基础设置 + AI增强（补帧/超分互斥） + 轻量增强
struct TaskSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tempMode: EnhancementMode = .none
    @State private var tempMultiplier: FrameMultiplier = .x2
    @State private var tempSRModel: SuperResolutionModel = .piperSR
    @State private var tempSharpen: Bool = false
    @State private var tempSharpenStrength: Double = 0.4
    @State private var tempDenoise: Bool = false
    @State private var tempDenoiseStrength: Double = 0.3

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // 基础设置
                    VStack(alignment: .leading, spacing: 16) {
                        Text("基础设置").font(.headline)
                        settingRow("分辨率", value: .constant("原画"), options: ["原画", "720P", "1080P", "4K"])
                        settingRow("帧率", value: .constant("保持原样"), options: ["保持原样", "60fps", "120fps"])
                        settingRow("码率", value: .constant("自动"), options: ["自动", "高画质", "均衡", "小体积"])
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(12)

                    // AI 增强（单选组，补帧与超分互斥）
                    VStack(alignment: .leading, spacing: 16) {
                        Text("AI 画质增强").font(.headline)

                        Picker("增强模式", selection: $tempMode) {
                            Text("不增强").tag(EnhancementMode.none)
                            Text("智能补帧").tag(EnhancementMode.frameInterpolation)
                            Text("超清修复").tag(EnhancementMode.superResolution)
                        }
                        .pickerStyle(.segmented)

                        if tempMode == .frameInterpolation {
                            Picker("补帧倍数", selection: $tempMultiplier) {
                                Text("2x").tag(FrameMultiplier.x2)
                                Text("4x").tag(FrameMultiplier.x4)
                            }
                            .pickerStyle(.segmented)
                        }

                        if tempMode == .superResolution {
                            Picker("超分引擎", selection: $tempSRModel) {
                                Text("PiperSR 2x").tag(SuperResolutionModel.piperSR)
                                Text("Real-ESRGAN 4x").tag(SuperResolutionModel.esrgan)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(12)

                    // 轻量增强
                    VStack(alignment: .leading, spacing: 16) {
                        Text("轻量增强").font(.headline)
                        Toggle("画质锐化", isOn: $tempSharpen)
                        if tempSharpen {
                            Slider(value: $tempSharpenStrength, in: 0...1)
                        }
                        Toggle("智能降噪", isOn: $tempDenoise)
                        if tempDenoise {
                            Slider(value: $tempDenoiseStrength, in: 0...1)
                        }
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(12)

                    // 重置按钮
                    Button("重置任务") {
                        tempMode = .none
                        tempMultiplier = .x2
                        tempSRModel = .piperSR
                        tempSharpen = false
                        tempDenoise = false
                    }
                    .foregroundColor(.red)
                }
                .padding()
            }
            .navigationTitle("选择处理任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用设置") {
                        applyConfig()
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.accentPink)
                }
            }
        }
        .onAppear { loadCurrentConfig() }
    }

    private func loadCurrentConfig() {
        guard let project = appState.currentProject else { return }
        tempMode = project.enhancement.mode
        tempMultiplier = project.enhancement.frameMultiplier
        tempSRModel = project.enhancement.srModel
        tempSharpen = project.enhancement.clarity.sharpenEnabled
        tempSharpenStrength = project.enhancement.clarity.sharpenIntensity
        tempDenoise = project.enhancement.clarity.denoiseEnabled
        tempDenoiseStrength = project.enhancement.clarity.denoiseIntensity
    }

    private func applyConfig() {
        appState.setEnhancementMode(tempMode)
        if tempMode == .frameInterpolation {
            appState.setFrameMultiplier(tempMultiplier)
        }
        if tempMode == .superResolution {
            appState.setSuperResolutionModel(tempSRModel)
        }
        appState.updateClarity { config in
            config.sharpenEnabled = tempSharpen
            config.sharpenIntensity = tempSharpenStrength
            config.denoiseEnabled = tempDenoise
            config.denoiseIntensity = tempDenoiseStrength
        }
    }

    private func settingRow(_ title: String, value: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Picker(title, selection: value) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

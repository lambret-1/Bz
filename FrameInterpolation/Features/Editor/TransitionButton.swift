import SwiftUI

/// 转场类型
enum TransitionType: String, CaseIterable {
    case none = "无"
    case fade = "淡入淡出"
    case dissolve = "交叉溶解"
}

/// 转场按钮（片段连接处）
struct TransitionButton: View {
    @Binding var transition: TransitionType
    @Binding var duration: TimeInterval
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(width: 24, height: 24)
                Image(systemName: "square.on.square")
                    .font(.system(size: 12))
                    .foregroundColor(transition == .none ? .gray : Color.accentPink)
            }
        }
        .sheet(isPresented: $showSheet) {
            NavigationView {
                Form {
                    Picker("转场类型", selection: $transition) {
                        ForEach(TransitionType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    if transition != .none {
                        VStack(alignment: .leading) {
                            Text("时长：\(String(format: "%.1f", duration))s")
                            Slider(value: $duration, in: 0.1...1.0, step: 0.1)
                        }
                    }
                }
                .navigationTitle("转场设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showSheet = false }
                    }
                }
            }
        }
    }
}

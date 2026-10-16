import SwiftUI

/// 草稿保存指示器（视图模型）
@MainActor
final class DraftSaveIndicator: ObservableObject {
    @Published var showSaved = false

    func triggerSave() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showSaved = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                showSaved = false
            }
        }
    }
}

/// 草稿已保存 Toast
struct DraftSavedToast: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
            Text("草稿已保存")
                .font(.caption)
                .foregroundColor(.topBarText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(16)
        .shadow(radius: 4)
    }
}

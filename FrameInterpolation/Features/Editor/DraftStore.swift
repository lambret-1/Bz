import Foundation

/// 草稿持久化存储
final class DraftStore {
    static let shared = DraftStore()
    private let segmentsKey = "editor_draft_segments"
    private let configKey = "editor_draft_config"

    private init() {}

    /// 保存草稿
    func saveDraft(appState: AppState) {
        if let project = appState.currentProject {
            if let data = try? JSONEncoder().encode(project.segments) {
                UserDefaults.standard.set(data, forKey: segmentsKey)
            }
        }
    }

    /// 是否存在草稿
    func hasDraft() -> Bool {
        return UserDefaults.standard.data(forKey: segmentsKey) != nil
    }

    /// 清除草稿
    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: segmentsKey)
        UserDefaults.standard.removeObject(forKey: configKey)
    }

    /// 加载草稿片段
    func loadSegments() -> [VideoSegment]? {
        guard let data = UserDefaults.standard.data(forKey: segmentsKey) else { return nil }
        return try? JSONDecoder().decode([VideoSegment].self, from: data)
    }
}

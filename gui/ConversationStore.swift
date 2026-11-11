import Foundation

// 会話ごとに ~/Library/Application Support/mighty/conversations/<id>.json を1ファイルとして
// サイドバー一覧とディスク保存を管理する。各ファイルは {id, title, updatedAt, history} のJSON。
@MainActor
final class ConversationStore: ObservableObject {
    struct Summary: Identifiable, Equatable {
        let id: String
        var title: String
        var updatedAt: Date
    }

    @Published var summaries: [Summary] = []
    @Published var selectedID: String?

    init() {
        migrateLegacyHistoryIfNeeded()
        reloadSummaries()
        selectedID = summaries.first?.id ?? newConversation(reuseEmpty: nil)
    }

    private func fileURL(_ id: String) -> URL {
        Config.conversationsDir.appendingPathComponent("\(id).json")
    }

    func reloadSummaries() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Config.conversationsDir, includingPropertiesForKeys: nil)) ?? []
        var result: [Summary] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let id = obj["id"] as? String ?? f.deletingPathExtension().lastPathComponent
            let title = obj["title"] as? String ?? "新しい会話"
            let ts = obj["updatedAt"] as? Double ?? 0
            result.append(Summary(id: id, title: title, updatedAt: Date(timeIntervalSince1970: ts)))
        }
        summaries = result.sorted { $0.updatedAt > $1.updatedAt }
    }

    // 選択中の会話がまだ空ならそれを使い回す(空の会話がサイドバーに溜まらないように)。
    func newConversation(reuseEmpty currentID: String?) -> String {
        if let currentID, load(id: currentID).history.isEmpty {
            return currentID
        }
        let id = UUID().uuidString
        save(id: id, title: "新しい会話", history: [])
        return id
    }

    func load(id: String) -> (title: String, history: [[String: Any]]) {
        guard let data = try? Data(contentsOf: fileURL(id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("新しい会話", []) }
        let title = obj["title"] as? String ?? "新しい会話"
        let history = obj["history"] as? [[String: Any]] ?? []
        return (title, history)
    }

    func save(id: String, title: String? = nil, history: [[String: Any]]) {
        var obj: [String: Any] = [:]
        if let existing = try? Data(contentsOf: fileURL(id)),
           let existingObj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            obj = existingObj
        }
        obj["id"] = id
        if let title { obj["title"] = title }
        if obj["title"] == nil { obj["title"] = "新しい会話" }
        obj["updatedAt"] = Date().timeIntervalSince1970
        obj["history"] = history
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: fileURL(id))
        reloadSummaries()
    }

    // タイトルが自動生成前(デフォルト名)のままなら、最初のユーザー発言から付け直す。
    func setAutoTitle(id: String, from firstUserText: String) {
        let (current, history) = load(id: id)
        guard current == "新しい会話" else { return }
        save(id: id, title: String(firstUserText.prefix(24)), history: history)
    }

    func rename(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (_, history) = load(id: id)
        save(id: id, title: trimmed, history: history)
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        reloadSummaries()
        if selectedID == id {
            selectedID = summaries.first?.id ?? newConversation(reuseEmpty: nil)
        }
    }

    // 旧バージョン(単一ファイルhistory.json)からの一回限りの移行。
    private func migrateLegacyHistoryIfNeeded() {
        guard FileManager.default.fileExists(atPath: Config.legacyHistoryURL.path) else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(at: Config.conversationsDir, includingPropertiesForKeys: nil)) ?? []
        guard existing.isEmpty else {
            try? FileManager.default.removeItem(at: Config.legacyHistoryURL)
            return
        }
        guard let data = try? Data(contentsOf: Config.legacyHistoryURL),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !history.isEmpty
        else {
            try? FileManager.default.removeItem(at: Config.legacyHistoryURL)
            return
        }
        let firstUserText = history.first { $0["role"] as? String == "user" }
            .flatMap { $0["content"] as? String } ?? "以前の会話"
        save(id: UUID().uuidString, title: String(firstUserText.prefix(24)), history: history)
        try? FileManager.default.removeItem(at: Config.legacyHistoryURL)
    }
}

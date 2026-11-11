import AppKit
import Foundation

enum Config {
    static let proxyBase = "http://127.0.0.1:8082"
    private static let backendDirDefaultsKey = "backendDir"

    // mightyCode リポジトリ(backend-start.sh がある場所)への絶対パス。
    // UserDefaultsに記憶済みならそれを使い、なければよくある場所を探し、
    // それも無ければユーザーにフォルダを選んでもらう。
    static var backendDir: String? {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: backendDirDefaultsKey), isValidBackendDir(saved) {
            return saved
        }
        if let found = candidateDirs().first(where: isValidBackendDir) {
            defaults.set(found, forKey: backendDirDefaultsKey)
            return found
        }
        return nil
    }

    static func isValidBackendDir(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/backend-start.sh")
    }

    private static func candidateDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["mightyCode", "Projects/mightyCode", "Developer/mightyCode", "Documents/mightyCode", "Desktop/mightyCode"]
            .map { "\(home)/\($0)" }
    }

    // メインスレッドから呼ぶこと。選ばれたパスはUserDefaultsに保存して次回以降は聞かない。
    @MainActor
    static func promptForBackendDir() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "mightyCode のフォルダを選んでください(backend-start.sh がある場所)"
        guard panel.runModal() == .OK, let url = panel.url, isValidBackendDir(url.path) else { return nil }
        UserDefaults.standard.set(url.path, forKey: backendDirDefaultsKey)
        return url.path
    }

    static let appSupportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mighty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let conversationsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("conversations")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let legacyHistoryURL = appSupportDir.appendingPathComponent("history.json")
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // "user" / "assistant" / "search"(検索ログ表示用)
    var text: String
}

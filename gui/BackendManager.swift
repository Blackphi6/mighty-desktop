import Foundation

// mlx_lm.server + anthropic_proxy をアプリ全体で一度だけ起動・監視する。
@MainActor
final class BackendManager: ObservableObject {
    @Published var ready = false
    @Published var statusText = "バックエンドを起動しています…"

    func start() {
        guard !ready else { return }
        guard let dir = Config.backendDir ?? Config.promptForBackendDir() else {
            statusText = "mightyCodeのフォルダが見つかりません(setup.sh済みのフォルダを選んでください)"
            return
        }
        statusText = "バックエンドを起動しています…"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["\(dir)/backend-start.sh"]
            let pipe = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                await MainActor.run {
                    if ok {
                        self.ready = true
                        self.statusText = "準備完了"
                    } else {
                        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                        let errText = String(data: errData, encoding: .utf8) ?? ""
                        self.statusText = "バックエンド起動に失敗しました: \(errText)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusText = "起動エラー: \(error.localizedDescription)"
                }
            }
        }
    }
}

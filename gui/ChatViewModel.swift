import Foundation

// 1つの会話に対するチャットロジック: モデル呼び出し、WebSearchツールのループ、ディスク保存。
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isLoading = false

    let conversationID: String
    private let store: ConversationStore
    private var apiHistory: [[String: Any]] = []

    init(conversationID: String, store: ConversationStore) {
        self.conversationID = conversationID
        self.store = store
        let loaded = store.load(id: conversationID)
        apiHistory = loaded.history
        rebuildDisplayMessages()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        let isFirstMessage = apiHistory.isEmpty
        messages.append(ChatMessage(role: "user", text: text))
        apiHistory.append(["role": "user", "content": text])
        input = ""
        isLoading = true
        persist()
        if isFirstMessage {
            store.setAutoTitle(id: conversationID, from: text)
        }
        Task {
            await runTurn()
            isLoading = false
            persist()
        }
    }

    private func rebuildDisplayMessages() {
        for m in apiHistory {
            let role = m["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { continue }
            if let s = m["content"] as? String {
                messages.append(ChatMessage(role: role, text: s))
            } else if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks where b["type"] as? String == "text" {
                    if let t = b["text"] as? String, !t.isEmpty {
                        messages.append(ChatMessage(role: role, text: t))
                    }
                }
            }
        }
    }

    private func persist() {
        store.save(id: conversationID, history: apiHistory)
    }

    // モデルがテキストで答えるまで、必要ならWebSearchツール呼び出しを挟んで何往復か続ける。
    private func runTurn() async {
        let tools: [[String: Any]] = [[
            "name": "WebSearch",
            "description": "最新情報や事実確認のためにウェブ検索を行い、上位の検索結果(タイトル・URL・抜粋)を返す。",
            "input_schema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "検索クエリ"]],
                "required": ["query"],
            ],
        ]]
        for _ in 0..<4 { // ponytail: ツール呼び出しの無限ループ防止に上限4往復
            do {
                let content = try await callModel(history: apiHistory, tools: tools)
                apiHistory.append(["role": "assistant", "content": content])
                var toolUses: [(id: String, query: String)] = []
                for block in content {
                    if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty {
                        messages.append(ChatMessage(role: "assistant", text: t))
                    } else if block["type"] as? String == "tool_use", block["name"] as? String == "WebSearch" {
                        let id = block["id"] as? String ?? "toolu_\(UUID().uuidString)"
                        let input = block["input"] as? [String: Any] ?? [:]
                        toolUses.append((id, input["query"] as? String ?? ""))
                    }
                }
                if toolUses.isEmpty { return }
                var resultBlocks: [[String: Any]] = []
                for use in toolUses {
                    messages.append(ChatMessage(role: "search", text: "🔍 「\(use.query)」を検索中…"))
                    let result = await webSearch(query: use.query)
                    resultBlocks.append(["type": "tool_result", "tool_use_id": use.id, "content": result])
                }
                apiHistory.append(["role": "user", "content": resultBlocks])
            } catch {
                messages.append(ChatMessage(role: "assistant", text: "エラー: \(error.localizedDescription)"))
                return
            }
        }
    }

    private func callModel(history: [[String: Any]], tools: [[String: Any]]) async throws -> [[String: Any]] {
        var req = URLRequest(url: URL(string: "\(Config.proxyBase)/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let body: [String: Any] = [
            "model": "heretic-9b-local",
            "max_tokens": 2048,
            "stream": false,
            "messages": history,
            "tools": tools,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "mighty", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["content"] as? [[String: Any]] ?? []
    }

    // ponytail: DuckDuckGoのHTML結果を正規表現で抜くナイーブな実装。マークアップが変わったら壊れる。
    // 壊れたら公式Instant Answer APIかSearXNGインスタンスに切り替える。
    private func webSearch(query: String) async -> String {
        guard var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return "検索URLの構築に失敗しました"
        }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return "検索URLの構築に失敗しました" }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) mighty/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let html = String(data: data, encoding: .utf8) ?? ""
            return Self.parseDuckDuckGoResults(html: html)
        } catch {
            return "検索に失敗しました: \(error.localizedDescription)"
        }
    }

    static func parseDuckDuckGoResults(html: String, limit: Int = 5) -> String {
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            let titleRegex = try? NSRegularExpression(
                pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
                options: [.dotMatchesLineSeparators]),
            let snippetRegex = try? NSRegularExpression(
                pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
                options: [.dotMatchesLineSeparators])
        else { return "検索結果のパースに失敗しました" }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let titles = titleRegex.matches(in: html, range: full).map { m in
            (strip(ns.substring(with: m.range(at: 1))), strip(ns.substring(with: m.range(at: 2))))
        }
        let snippets = snippetRegex.matches(in: html, range: full).map { strip(ns.substring(with: $0.range(at: 1))) }
        if titles.isEmpty { return "検索結果が見つかりませんでした" }
        var lines: [String] = []
        for (i, pair) in titles.prefix(limit).enumerated() {
            let (url, title) = pair
            let snippet = i < snippets.count ? snippets[i] : ""
            lines.append("\(i + 1). \(title)\nURL: \(url)\n\(snippet)")
        }
        return lines.joined(separator: "\n\n")
    }
}

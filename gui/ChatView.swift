import SwiftUI

struct ChatView: View {
    @StateObject private var vm: ChatViewModel
    @ObservedObject var backend: BackendManager

    init(conversationID: String, store: ConversationStore, backend: BackendManager) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversationID: conversationID, store: store))
        self.backend = backend
    }

    // アプリ自体のロゴ(mighty.app/Contents/Resources/mark.png)をChatGPT風に単色表示する。
    // 見つからない場合だけ汎用アイコンにフォールバックする。
    private static let appMark: Image = {
        if let url = Bundle.main.url(forResource: "mark", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "app.fill")
    }()

    var body: some View {
        if vm.messages.isEmpty {
            // Ollama風: メッセージがまだない会話は、画面中央にロゴと入力欄だけを出す。
            VStack(spacing: 24) {
                Spacer()
                Self.appMark
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.tertiary)
                inputBar
                    .frame(maxWidth: 560)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.messages) { msg in
                                bubble(msg).id(msg.id)
                            }
                            if vm.isLoading {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("考え中…").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.messages.count) {
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
    }

    // Ollama風: 角丸1枚のパネルの中にテキストフィールドと、下段に状態表示・送信ボタンをまとめる。
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("メッセージを送信…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { vm.send() }
            HStack(spacing: 8) {
                if !backend.ready {
                    ProgressView().controlSize(.small)
                    Text(backend.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: vm.send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoading || !backend.ready)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == "search" {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text(msg.text)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack {
                if msg.role == "user" { Spacer(minLength: 40) }
                Text(msg.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(msg.role == "user" ? Color.accentColor.opacity(0.85) : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 420, alignment: msg.role == "user" ? .trailing : .leading)
                if msg.role != "user" { Spacer(minLength: 40) }
            }
        }
    }
}

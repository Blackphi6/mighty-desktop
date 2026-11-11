import SwiftUI

// Ollama風: 左サイドバーに会話一覧、右に選択中の会話のチャット。
struct RootView: View {
    @StateObject private var store = ConversationStore()
    @StateObject private var backend = BackendManager()
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Text("会話")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                List(selection: $store.selectedID) {
                    Section("最近") {
                        ForEach(store.summaries) { s in
                            Text(s.title)
                                .tag(s.id)
                                .lineLimit(1)
                                .contextMenu {
                                    Button("名前を変更", systemImage: "pencil") {
                                        renameText = s.title
                                        renamingID = s.id
                                    }
                                    Button("削除", systemImage: "trash", role: .destructive) {
                                        store.delete(id: s.id)
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("mighty")
            .alert("名前を変更", isPresented: Binding(
                get: { renamingID != nil },
                set: { if !$0 { renamingID = nil } }
            )) {
                TextField("会話名", text: $renameText)
                Button("保存") {
                    if let id = renamingID { store.rename(id: id, to: renameText) }
                    renamingID = nil
                }
                Button("キャンセル", role: .cancel) { renamingID = nil }
            }
        } detail: {
            Group {
                if let id = store.selectedID {
                    ChatView(conversationID: id, store: store, backend: backend)
                        .id(id)
                        .navigationTitle(store.summaries.first(where: { $0.id == id })?.title ?? "mighty")
                } else {
                    Text("左の「新しい会話」から始めてください")
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { store.selectedID = store.newConversation(reuseEmpty: store.selectedID) }) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("新しい会話")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { backend.start() }
    }
}

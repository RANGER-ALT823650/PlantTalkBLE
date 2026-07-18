import SwiftUI

@MainActor
struct ConversationListView: View {
    let database: PlantDatabase

    @State private var conversations: [AIConversation] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var conversationPendingDeletion: AIConversation?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取会话…")
            } else if conversations.isEmpty {
                ContentUnavailableView(
                    "还没有文字对话记录",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(errorMessage ?? "在主页面展开植物状态后，通过顶部输入框开始对话。")
                )
            } else {
                List {
                    ForEach(conversations) { conversation in
                        NavigationLink {
                            TextConversationTranscriptView(
                                database: database,
                                conversation: conversation
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .lineLimit(2)
                                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                conversationPendingDeletion = conversation
                            }
                        }
                    }
                    .onDelete(perform: deleteConversations)
                }
                .refreshable {
                    await loadConversations()
                }
            }
        }
        .task {
            await loadConversations()
        }
        .confirmationDialog(
            "删除这条文字会话？",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let conversationPendingDeletion {
                    deleteConversation(conversationPendingDeletion)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会话及其中的全部消息都会被永久删除。")
        }
    }

    private func loadConversations() async {
        do {
            conversations = try await database.allConversations(kind: .text)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteConversations(at offsets: IndexSet) {
        let ids = offsets.map { conversations[$0].id }
        conversations.remove(atOffsets: offsets)
        Task {
            do {
                for id in ids {
                    try await database.deleteConversation(id: id)
                }
            } catch {
                errorMessage = error.localizedDescription
                await loadConversations()
            }
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { conversationPendingDeletion != nil },
            set: { if !$0 { conversationPendingDeletion = nil } }
        )
    }

    private func deleteConversation(_ conversation: AIConversation) {
        conversationPendingDeletion = nil
        conversations.removeAll { $0.id == conversation.id }
        Task {
            do {
                try await database.deleteConversation(id: conversation.id)
            } catch {
                errorMessage = error.localizedDescription
                await loadConversations()
            }
        }
    }
}

@MainActor
private struct TextConversationTranscriptView: View {
    let database: PlantDatabase
    let conversation: AIConversation

    @State private var messages: [ChatMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取对话…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法读取对话",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if messages.isEmpty {
                ContentUnavailableView("暂无消息", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMessages()
        }
    }

    private func loadMessages() async {
        do {
            messages = try await database.chatMessages(conversationID: conversation.id)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

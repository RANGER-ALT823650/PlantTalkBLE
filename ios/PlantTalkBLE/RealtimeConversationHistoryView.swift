import SwiftUI

@MainActor
struct RealtimeConversationHistoryView: View {
    let database: PlantDatabase
    let onContinueConversation: (AIConversation, [ChatMessage]) -> Void

    @State private var conversations: [AIConversation] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var conversationPendingDeletion: AIConversation?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取实时语音记录…")
            } else if conversations.isEmpty {
                ContentUnavailableView(
                    "暂无实时语音记录",
                    systemImage: "waveform",
                    description: Text(errorMessage ?? "从主页面点按圆形按钮开始实时语音对话。")
                )
            } else {
                List {
                    ForEach(conversations) { conversation in
                        NavigationLink {
                            RealtimeTranscriptHistoryView(
                                database: database,
                                conversation: conversation,
                                onContinueConversation: onContinueConversation
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
            "删除这条实时语音会话？",
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
            Text("会话及其中的全部转录都会被永久删除。")
        }
    }

    private func loadConversations() async {
        do {
            conversations = try await database.allConversations(kind: .realtime)
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
private struct RealtimeTranscriptHistoryView: View {
    let database: PlantDatabase
    let conversation: AIConversation
    let onContinueConversation: (AIConversation, [ChatMessage]) -> Void

    @State private var messages: [ChatMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取转录…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法读取转录",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if messages.isEmpty {
                ContentUnavailableView("暂无转录", systemImage: "waveform")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    onContinueConversation(conversation, messages)
                } label: {
                    Label("继续语音对话", systemImage: "waveform.badge.mic")
                }
                .disabled(isLoading || messages.isEmpty)
            }
        }
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

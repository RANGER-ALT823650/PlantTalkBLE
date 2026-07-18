import SwiftUI

@MainActor
struct RealtimeConversationSheet: View {
    private let conversation: QwenRealtimeConversation?
    private let previewState: RealtimeConversationSheetState

    @State private var selectedDetent: PresentationDetent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        conversation: QwenRealtimeConversation,
        initialDetent: PresentationDetent = .medium
    ) {
        self.conversation = conversation
        self.previewState = .empty
        _selectedDetent = State(initialValue: initialDetent)
    }

    init(
        previewEntries: [RealtimeTranscriptEntry],
        initialDetent: PresentationDetent = .medium
    ) {
        self.conversation = nil
        self.previewState = RealtimeConversationSheetState(
            conversationState: .connected,
            entries: previewEntries
        )
        _selectedDetent = State(initialValue: initialDetent)
    }

    private var state: RealtimeConversationSheetState {
        guard let conversation else { return previewState }
        return RealtimeConversationSheetState(conversation: conversation)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader

            transcript
                .plantTalkBottomBar {
                    endConversationControl
                }
        }
        .background {
            ChatConversationBackdrop()
                .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationCornerRadius(32)
    }

    private var statusHeader: some View {
        statusSurface
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusSurface: some View {
        if #available(iOS 26, *) {
            statusContent
                .glassEffect(.regular, in: .capsule)
        } else {
            statusContent
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
                }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            RealtimeVoiceStatusSymbol(
                color: statusColor,
                isSpeaking: state.isUserSpeaking
            )

                Text(state.conversationState.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            

            if state.conversationState == .connected {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.isUserSpeaking ? .orange : .green)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: true
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: state.isUserSpeaking)
        .accessibilityElement(children: .combine)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if state.entries.isEmpty,
                       state.currentUserText.isEmpty,
                       state.currentAssistantText.isEmpty {
                        emptyConversationState
                    }

                    ForEach(state.entries) { entry in
                        ChatMessageBubble(message: entry.chatMessage)
                            .id(entry.id)
                            .transition(messageTransition(for: entry.role))
                    }

                    if let currentUserMessage {
                        ChatMessageBubble(message: currentUserMessage)
                            .id(currentUserMessage.id)
                            .transition(messageTransition(for: .user))
                    }

                    if let currentAssistantMessage {
                        ChatMessageBubble(message: currentAssistantMessage)
                            .id(currentAssistantMessage.id)
                            .transition(messageTransition(for: .assistant))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                if state.isWaitingForAssistantText {
                    ModelThinkingIndicator()
                        .padding(.vertical, 8)
                        .transition(thinkingTransition)
                }
            }
            .onChange(of: state.entries.count) { _, _ in
                scrollToLatest(using: proxy, animated: true)
            }
            .onChange(of: state.currentUserText) { _, _ in
                scrollToLatest(using: proxy, animated: false)
            }
            .onChange(of: state.currentAssistantText) { _, _ in
                scrollToLatest(using: proxy, animated: false)
            }
        }
    }

    private var emptyConversationState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: state.conversationState == .connected
                )

            VStack(spacing: 4) {
                Text(emptyStateTitle)
                    .font(.headline)

                Text(emptyStateDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }

    private var endConversationControl: some View {
        endConversationButton
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var endConversationButton: some View {
        if #available(iOS 26, *) {
            Button(role: .destructive, action: endConversation) {
                Label("结束聊天", systemImage: "phone.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Color(uiColor: .systemRed))
            .accessibilityHint("停止麦克风和模型连接，并保存当前聊天记录")
        } else {
            Button(role: .destructive, action: endConversation) {
                Label("结束聊天", systemImage: "phone.down.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Color(uiColor: .systemRed))
            .accessibilityHint("停止麦克风和模型连接，并保存当前聊天记录")
        }
    }

    private var emptyStateTitle: String {
        switch state.conversationState {
        case .idle:
            "对话已结束"
        case .requestingPermission:
            "正在等待麦克风权限"
        case .preparingAudio:
            "正在准备麦克风"
        case .connecting:
            "正在连接植物"
        case .connected:
            "直接开始说话"
        case .error:
            "实时语音暂不可用"
        }
    }

    private var emptyStateDescription: String {
        switch state.conversationState {
        case .error(let message):
            message
        case .idle:
            "返回主页面可以重新开始一次对话。"
        case .requestingPermission, .preparingAudio, .connecting:
            "连接完成后即可自然说话，无需再次点按。"
        case .connected:
            "模型会边听边回答，转录内容会实时出现在这里。"
        }
    }

    private var currentUserMessage: ChatMessage? {
        liveMessage(
            id: state.currentUserEntryID,
            role: .user,
            text: state.currentUserText,
            createdAt: state.currentUserStartedAt
        )
    }

    private var currentAssistantMessage: ChatMessage? {
        liveMessage(
            id: state.currentAssistantEntryID,
            role: .assistant,
            text: state.currentAssistantText,
            createdAt: state.currentAssistantStartedAt
        )
    }

    private func liveMessage(
        id: UUID?,
        role: ChatRole,
        text: String,
        createdAt: Date?
    ) -> ChatMessage? {
        guard let id,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ChatMessage(
            id: id,
            conversationID: RealtimeTranscriptEntry.presentationConversationID,
            role: role,
            content: text,
            createdAt: createdAt ?? Date()
        )
    }

    private var thinkingTransition: AnyTransition {
        reduceMotion ? .opacity : .scale.combined(with: .opacity)
    }

    private func messageTransition(for role: ChatRole) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: role == .user ? .trailing : .leading)
            .combined(with: .opacity)
    }

    private var statusColor: Color {
        switch state.conversationState {
        case .connected:
            state.isUserSpeaking ? .orange : .green
        case .requestingPermission, .preparingAudio, .connecting:
            .yellow
        case .error:
            .red
        case .idle:
            .secondary
        }
    }

    private func scrollToLatest(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let target: AnyHashable?
        if let currentAssistantMessage {
            target = currentAssistantMessage.id
        } else if let currentUserMessage {
            target = currentUserMessage.id
        } else {
            target = state.entries.last?.id
        }
        guard let target else { return }

        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private func endConversation() {
        conversation?.stop()
        dismiss()
    }
}

@MainActor
private struct RealtimeConversationSheetState {
    let conversationState: RealtimeConversationState
    let entries: [RealtimeTranscriptEntry]
    let currentUserText: String
    let currentAssistantText: String
    let currentUserEntryID: UUID?
    let currentAssistantEntryID: UUID?
    let currentUserStartedAt: Date?
    let currentAssistantStartedAt: Date?
    let isUserSpeaking: Bool
    let isWaitingForAssistantText: Bool

    static let empty = RealtimeConversationSheetState(
        conversationState: .idle,
        entries: [],
        currentUserText: "",
        currentAssistantText: "",
        currentUserEntryID: nil,
        currentAssistantEntryID: nil,
        currentUserStartedAt: nil,
        currentAssistantStartedAt: nil,
        isUserSpeaking: false,
        isWaitingForAssistantText: false
    )

    init(conversation: QwenRealtimeConversation) {
        conversationState = conversation.state
        entries = conversation.entries
        currentUserText = conversation.currentUserText
        currentAssistantText = conversation.currentAssistantText
        currentUserEntryID = conversation.currentUserEntryID
        currentAssistantEntryID = conversation.currentAssistantEntryID
        currentUserStartedAt = conversation.currentUserStartedAt
        currentAssistantStartedAt = conversation.currentAssistantStartedAt
        isUserSpeaking = conversation.isUserSpeaking
        isWaitingForAssistantText = conversation.isWaitingForAssistantText
    }

    init(
        conversationState: RealtimeConversationState,
        entries: [RealtimeTranscriptEntry],
        currentUserText: String = "",
        currentAssistantText: String = "",
        currentUserEntryID: UUID? = nil,
        currentAssistantEntryID: UUID? = nil,
        currentUserStartedAt: Date? = nil,
        currentAssistantStartedAt: Date? = nil,
        isUserSpeaking: Bool = false,
        isWaitingForAssistantText: Bool = false
    ) {
        self.conversationState = conversationState
        self.entries = entries
        self.currentUserText = currentUserText
        self.currentAssistantText = currentAssistantText
        self.currentUserEntryID = currentUserEntryID
        self.currentAssistantEntryID = currentAssistantEntryID
        self.currentUserStartedAt = currentUserStartedAt
        self.currentAssistantStartedAt = currentAssistantStartedAt
        self.isUserSpeaking = isUserSpeaking
        self.isWaitingForAssistantText = isWaitingForAssistantText
    }
}

private struct RealtimeVoiceStatusSymbol: View {
    let color: Color
    let isSpeaking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 26, height: 26)
                .scaleEffect(isSpeaking && !reduceMotion ? 1.18 : 1)

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
            value: isSpeaking
        )
        .accessibilityHidden(true)
    }
}

private extension RealtimeTranscriptEntry {
    static let presentationConversationID = UUID()

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            conversationID: Self.presentationConversationID,
            role: role,
            content: text,
            createdAt: createdAt,
            toolInvocations: toolInvocations
        )
    }
}

#Preview(
    "实时语音对话记录 · 展开",
    traits: .fixedLayout(width: 393, height: 852)
) {
    RealtimeConversationSheetPreviewHost(initialDetent: .large)
}

#Preview(
    "实时语音对话记录 · 半屏",
    traits: .fixedLayout(width: 393, height: 852)
) {
    RealtimeConversationSheetPreviewHost(initialDetent: .medium)
}

@MainActor
private struct RealtimeConversationSheetPreviewHost: View {
    let initialDetent: PresentationDetent

    @State private var isPresented = true

    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                RealtimeConversationSheet(
                    previewEntries: realtimeConversationPreviewEntries,
                    initialDetent: initialDetent
                )
            }
    }
}

private let realtimeConversationPreviewEntries: [RealtimeTranscriptEntry] = {
    let baseDate = Date().addingTimeInterval(-6 * 60)
    let messages: [(ChatRole, String)] = [
        (.user, "早上好，今天这盆植物的状态怎么样？"),
        (.assistant, "早上好！温度和空气湿度都比较舒适，叶片状态也很稳定。土壤水分还在合适范围内。"),
        (.user, "土壤摸起来有一点干，现在需要浇水吗？"),
        (.assistant, "暂时不用急着浇。可以等表层再干一点后少量补水，避免盆土长期过湿。"),
        (.user, "它上午会晒到两个小时的太阳，这样合适吗？"),
        (.assistant, "两小时柔和的晨光很合适。中午光线变强时，稍微拉开和玻璃的距离就可以了。")
    ]

    return messages.enumerated().map { index, message in
        RealtimeTranscriptEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            role: message.0,
            text: message.1,
            createdAt: baseDate.addingTimeInterval(Double(index) * 60),
            toolInvocations: []
        )
    }
}()

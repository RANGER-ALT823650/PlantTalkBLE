import SwiftUI

@MainActor
struct RealtimeConversationSheet: View {
    private let conversation: QwenRealtimeConversation?
    private let previewState: RealtimeConversationSheetState

    @State private var selectedDetent: PresentationDetent
    @State private var mediaSource: ConversationMediaSource?
    @State private var isSharingCamera = false
    @State private var isSendingCameraFrame = false
    @State private var visualStatusText = ""
    @State private var visualAlert: RealtimeVisualAlert?
    @State private var visualSendTask: Task<Void, Never>?
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
            if isSharingCamera {
                realtimeCamera
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            transcript
                .plantTalkBottomBar {
                    conversationControls
                }
        }
        .overlay(alignment: .top) {
            statusHeader
                .allowsHitTesting(false)
                .zIndex(1)
        }
        .background {
            ChatConversationBackdrop()
                .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationCornerRadius(32)
        .fullScreenCover(item: $mediaSource) { source in
            ConversationMediaPanel(
                source: source,
                onDismiss: { mediaSource = nil },
                onAttachments: handleAttachments
            )
            .ignoresSafeArea()
        }
        .alert(item: $visualAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .animation(.snappy(duration: 0.28), value: isSharingCamera)
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
                .padding(.top, isSharingCamera ? 8 : 82)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                if state.isWaitingForAssistantText {
                    ModelThinkingIndicator()
                        .padding(.top, isSharingCamera ? 8 : 74)
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

    private var conversationControls: some View {
        VStack(spacing: 8) {
            if !visualStatusText.isEmpty {
                Label(visualStatusText, systemImage: "viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                visualAttachmentMenu
                cameraSharingButton
                endConversationButton
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var realtimeCamera: some View {
        RealtimeCameraStreamView(
            onFrame: sendCameraFrame,
            onClose: stopCameraSharing
        )
        .frame(height: selectedDetent == .large ? 190 : 128)
        .accessibilityHint("相机画面按每秒一帧发送给实时模型")
    }

    private var visualAttachmentMenu: some View {
        Menu {
            Button {
                openMediaSource(.camera)
            } label: {
                Label("拍一张照片", systemImage: "camera")
            }

            Button {
                openMediaSource(.photoLibrary)
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.headline)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(state.conversationState != .connected)
        .accessibilityLabel("添加图片")
        .accessibilityHint("拍照或从相册选择图片，在下一段语音中一起发送")
    }

    private var cameraSharingButton: some View {
        Button(action: toggleCameraSharing) {
            Image(systemName: isSharingCamera ? "video.slash.fill" : "video.fill")
                .font(.headline)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(isSharingCamera ? .red : .accentColor)
        .disabled(state.conversationState != .connected)
        .accessibilityLabel(isSharingCamera ? "停止共享摄像头" : "共享摄像头")
        .accessibilityHint("持续预览并按每秒一帧发送给实时模型")
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
        visualSendTask?.cancel()
        visualSendTask = nil
        isSharingCamera = false
        conversation?.stop()
        dismiss()
    }

    private func openMediaSource(_ source: ConversationMediaSource) {
        isSharingCamera = false
        visualStatusText = ""
        mediaSource = source
    }

    private func handleAttachments(_ attachments: [ConversationImageAttachment]) {
        mediaSource = nil
        guard let conversation, !attachments.isEmpty else { return }

        visualSendTask?.cancel()
        visualStatusText = "正在处理并发送图片…"
        visualSendTask = Task { @MainActor in
            do {
                for (index, attachment) in attachments.enumerated() {
                    try Task.checkCancellation()
                    let data = try attachment.encodedRealtimeImage()
                    try await conversation.sendVisualFrame(data)
                    conversation.recordSentImage(data)
                    if index < attachments.count - 1 {
                        // The provider recommends no more than one visual frame
                        // per second for both still-image batches and video.
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                visualStatusText = attachments.count == 1
                    ? "图片已就绪，请直接针对画面提问"
                    : "\(attachments.count) 张图片已就绪，请直接针对画面提问"
            } catch is CancellationError {
                return
            } catch {
                visualStatusText = ""
                visualAlert = RealtimeVisualAlert(
                    title: "无法发送图片",
                    message: visualErrorMessage(error, conversation: conversation)
                )
            }
        }
    }

    private func toggleCameraSharing() {
        if isSharingCamera {
            stopCameraSharing()
        } else {
            visualSendTask?.cancel()
            visualSendTask = nil
            conversation?.clearPinnedStillImage()
            visualStatusText = "摄像头已共享，画面会和你的语音一起理解"
            isSharingCamera = true
        }
    }

    private func stopCameraSharing() {
        isSharingCamera = false
        isSendingCameraFrame = false
        visualStatusText = "摄像头共享已停止，仍可继续语音对话"
    }

    private func sendCameraFrame(_ data: Data) {
        guard let conversation, !isSendingCameraFrame else { return }
        guard conversation.state == .connected else {
            stopCameraSharing()
            if case .error(let message) = conversation.state {
                visualAlert = RealtimeVisualAlert(
                    title: "摄像头共享已停止",
                    message: message
                )
            }
            return
        }
        isSendingCameraFrame = true
        Task { @MainActor in
            defer { isSendingCameraFrame = false }
            do {
                try await conversation.sendVisualFrame(data)
            } catch is CancellationError {
                return
            } catch {
                stopCameraSharing()
                visualAlert = RealtimeVisualAlert(
                    title: "摄像头共享已停止",
                    message: visualErrorMessage(error, conversation: conversation)
                )
            }
        }
    }

    private func visualErrorMessage(
        _ error: Error,
        conversation: QwenRealtimeConversation
    ) -> String {
        if case .error(let message) = conversation.state {
            return message
        }
        return error.localizedDescription
    }
}

private struct RealtimeVisualAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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

extension RealtimeTranscriptEntry {
    static let presentationConversationID = UUID()

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            conversationID: Self.presentationConversationID,
            role: role,
            content: text,
            createdAt: createdAt,
            imageAttachments: imageAttachments,
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

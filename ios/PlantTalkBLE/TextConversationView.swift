import SwiftUI
import Observation

private let conversationScrollCoordinateSpace = "plant-talk-text-conversation-scroll"

private enum ConversationMediaLayout {
    static let horizontalInset: CGFloat = 12
    static let bottomInset: CGFloat = 12
    static let fallbackCornerSize = CGSize(width: 40, height: 40)
}

private struct ConversationMediaMorphShape: Shape {
    var cornerWidth: CGFloat
    var cornerHeight: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerWidth, cornerHeight) }
        set {
            cornerWidth = newValue.first
            cornerHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect,
            cornerSize: CGSize(
                width: min(max(cornerWidth, 0), rect.width / 2),
                height: min(max(cornerHeight, 0), rect.height / 2)
            ),
            style: .continuous
        )
    }
}

private struct ConversationMediaMorphModifier: AnimatableModifier {
    var progress: CGFloat
    let sourceFrame: CGRect
    let destinationFrame: CGRect
    let destinationCornerSize: CGSize
    let baseColor: Color
    let sourceSystemName: String

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(max(progress, 0), 1)
        let widthProgress = phase(progress, from: 0, to: 0.78)
        let heightProgress = phase(progress, from: 0.06, to: 1)
        let positionProgress = phase(progress, from: 0, to: 0.82)
        let contentProgress = phase(progress, from: 0.18, to: 0.56)
        let surfaceProgress = phase(progress, from: 0.06, to: 0.34)
        let iconProgress = phase(progress, from: 0, to: 0.18)
        let shadowProgress = phase(progress, from: 0.12, to: 0.72)
        let cornerProgress = phase(progress, from: 0.14, to: 1)

        let initialScaleX = max(
            0.01,
            sourceFrame.width / max(destinationFrame.width, 1)
        )
        let initialScaleY = max(
            0.01,
            sourceFrame.height / max(destinationFrame.height, 1)
        )
        let scaleX = interpolate(initialScaleX, 1, widthProgress)
        let scaleY = interpolate(initialScaleY, 1, heightProgress)
        let sourceCornerRadius = min(sourceFrame.width, sourceFrame.height) / 2
        let visibleCornerWidth = interpolate(
            sourceCornerRadius,
            destinationCornerSize.width,
            cornerProgress
        )
        let visibleCornerHeight = interpolate(
            sourceCornerRadius,
            destinationCornerSize.height,
            cornerProgress
        )
        let panelShape = ConversationMediaMorphShape(
            cornerWidth: visibleCornerWidth / max(scaleX, 0.01),
            cornerHeight: visibleCornerHeight / max(scaleY, 0.01)
        )

        content
            .opacity(contentProgress)
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    baseColor
                        .opacity(surfaceProgress)
                }
            }
            .clipShape(panelShape)
            .overlay {
                panelShape
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: sourceSystemName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .scaleEffect(
                        x: 1 / max(scaleX, 0.01),
                        y: 1 / max(scaleY, 0.01)
                    )
                    .opacity(1 - iconProgress)
            }
            .shadow(
                color: .black.opacity(0.22 * shadowProgress),
                radius: 24 * shadowProgress,
                y: 12 * shadowProgress
            )
            .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
            .offset(
                x: (sourceFrame.midX - destinationFrame.midX)
                    * (1 - positionProgress),
                y: (sourceFrame.midY - destinationFrame.midY)
                    * (1 - positionProgress)
            )
    }

    private func phase(
        _ value: CGFloat,
        from start: CGFloat,
        to end: CGFloat
    ) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        let normalized = min(max((value - start) / (end - start), 0), 1)
        return normalized * normalized * (3 - (2 * normalized))
    }

    private func interpolate(
        _ start: CGFloat,
        _ end: CGFloat,
        _ progress: CGFloat
    ) -> CGFloat {
        start + ((end - start) * progress)
    }
}

private enum ConversationAttachmentLayout {
    static let itemSide: CGFloat = 88
    static let itemSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 17
}

private struct ConversationAttachmentStrip: View {
    let attachments: [ConversationImageAttachment]
    let isInteractive: Bool
    let onRemove: (String) -> Void

    var body: some View {
        Group {
            if attachments.count > 1 {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: ConversationAttachmentLayout.itemSpacing) {
                        attachmentCells
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: ConversationAttachmentLayout.itemSide)
            } else if let attachment = attachments.first {
                attachmentCell(attachment, index: 0)
            }
        }
        .frame(height: ConversationAttachmentLayout.itemSide)
        .accessibilityHidden(!isInteractive)
    }

    @ViewBuilder
    private var attachmentCells: some View {
        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
            attachmentCell(attachment, index: index)
        }
    }

    private func attachmentCell(
        _ attachment: ConversationImageAttachment,
        index: Int
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: attachment.image)
                .resizable()
                .scaledToFill()
                .frame(
                    width: ConversationAttachmentLayout.itemSide,
                    height: ConversationAttachmentLayout.itemSide
                )
                .clipShape(RoundedRectangle(
                    cornerRadius: ConversationAttachmentLayout.cornerRadius,
                    style: .continuous
                ))

            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .frame(width: 25, height: 25)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .allowsHitTesting(isInteractive)
            .accessibilityLabel("移除第\(index + 1)张照片")
        }
        .frame(
            width: ConversationAttachmentLayout.itemSide,
            height: ConversationAttachmentLayout.itemSide
        )
    }
}

private struct ConversationAttachmentTransferModifier: AnimatableModifier {
    var progress: CGFloat
    let isActive: Bool
    let panelFrame: CGRect
    let targetFrame: CGRect
    let attachments: [ConversationImageAttachment]
    let panelCornerSize: CGSize
    let baseColor: Color

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(max(progress, 0), 1)
        let widthProgress = phase(progress, from: 0.04, to: 0.94)
        let heightProgress = phase(progress, from: 0, to: 0.84)
        let positionProgress = phase(progress, from: 0.02, to: 0.96)
        let panelContentFade = phase(progress, from: 0.1, to: 0.52)
        let panelShellFade = phase(progress, from: 0.54, to: 0.88)
        let attachmentFade = phase(progress, from: 0.4, to: 0.73)
        let cornerProgress = phase(progress, from: 0.12, to: 0.84)
        let shadowFade = phase(progress, from: 0.22, to: 0.84)
        let activeOpacity: CGFloat = isActive ? 1 : 0

        let finalScaleX = max(
            0.01,
            targetFrame.width / max(panelFrame.width, 1)
        )
        let finalScaleY = max(
            0.01,
            targetFrame.height / max(panelFrame.height, 1)
        )
        let scaleX = interpolate(1, finalScaleX, widthProgress)
        let scaleY = interpolate(1, finalScaleY, heightProgress)
        let visibleCornerWidth = interpolate(
            panelCornerSize.width,
            ConversationAttachmentLayout.cornerRadius,
            cornerProgress
        )
        let visibleCornerHeight = interpolate(
            panelCornerSize.height,
            ConversationAttachmentLayout.cornerRadius,
            cornerProgress
        )
        let panelShape = ConversationMediaMorphShape(
            cornerWidth: visibleCornerWidth / max(scaleX, 0.01),
            cornerHeight: visibleCornerHeight / max(scaleY, 0.01)
        )

        content
            .opacity(1 - (activeOpacity * panelContentFade))
            .background {
                // Keep the transfer shell inside the panel's exact bounds.
                // A sibling shape would accept the full-screen overlay proposal.
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    baseColor
                }
                .clipShape(panelShape)
                .overlay {
                    panelShape
                        .stroke(
                            .white.opacity(0.16 * panelContentFade),
                            lineWidth: 0.5
                        )
                }
                .opacity(activeOpacity * (1 - panelShellFade))
            }
            .overlay {
                ConversationAttachmentStrip(
                    attachments: attachments,
                    isInteractive: false,
                    onRemove: { _ in }
                )
                .frame(width: targetFrame.width, height: targetFrame.height)
                .scaleEffect(
                    x: 1 / max(scaleX, 0.01),
                    y: 1 / max(scaleY, 0.01)
                )
                .opacity(attachmentFade * activeOpacity)
            }
            .shadow(
                color: .black.opacity(
                    0.22
                        * activeOpacity
                        * panelContentFade
                        * (1 - shadowFade)
                ),
                radius: 24 * (1 - shadowFade),
                y: 12 * (1 - shadowFade)
            )
            .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
            .offset(
                x: (targetFrame.midX - panelFrame.midX) * positionProgress,
                y: (targetFrame.midY - panelFrame.midY) * positionProgress
            )
    }

    private func phase(
        _ value: CGFloat,
        from start: CGFloat,
        to end: CGFloat
    ) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        let normalized = min(max((value - start) / (end - start), 0), 1)
        return normalized * normalized * (3 - (2 * normalized))
    }

    private func interpolate(
        _ start: CGFloat,
        _ end: CGFloat,
        _ progress: CGFloat
    ) -> CGFloat {
        start + ((end - start) * progress)
    }
}

@MainActor
struct TextConversationView: View {
    let database: PlantDatabase
    let client: OpenAICompatibleClient
    let toolExecutor: PlantDataToolExecutor
    let plantBinding: PlantConversationBinding
    let initialMessage: String
    let initialMessageID: UUID
    let initialMessageDate: Date
    let isInitialTransitionComplete: Bool
    let completedMessageFlightID: UUID?
    let startedMessageFlightID: UUID?
    let onMessageFlightRequested: (MessageFlightRequest) -> Void
    let onMessageFlightCancelled: (UUID) -> Void
    let onHome: () -> Void

    @State private var conversation: AIConversation?
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var composerFrame = CGRect.zero
    @State private var outgoingTransition: OutgoingMessageTransition?
    @State private var flightDestinationReadyID: UUID?
    @State private var pendingCatchUpMessageID: UUID?
    @State private var isScrolledToBottom = true
    @State private var isInitialMessageDiscarded = false
    @State private var streamingAssistantState = StreamingAssistantState()
    @State private var isStreaming = false
    @State private var isDiscardingTurn = false
    @State private var isWaitingForFirstToken = false
    @State private var isComposerVisible = false
    @State private var isAccessoryMenuExpanded = false
    @State private var activeMediaPanel: ConversationMediaSource?
    @State private var mediaButtonFrames: [String: CGRect] = [:]
    @State private var mediaPanelPresentedFrame = CGRect.zero
    @State private var mediaPanelExpansionProgress: CGFloat = 0
    @State private var mediaPanelAnimationTask: Task<Void, Never>?
    @State private var pendingImageAttachments: [ConversationImageAttachment] = []
    @State private var attachmentStripFrame = CGRect.zero
    @State private var composerTextFieldFrame = CGRect.zero
    @State private var composerMenuButtonFrame = CGRect.zero
    @State private var attachmentTransferTargetFrame = CGRect.zero
    @State private var attachmentTransferPanelFrame = CGRect.zero
    @State private var attachmentTransferAttachments: [ConversationImageAttachment] = []
    @State private var attachmentTransferProgress: CGFloat = 0
    @State private var isAttachmentTransferInProgress = false
    @State private var attachmentTransferTask: Task<Void, Never>?
    @State private var hasStartedInitialMessage = false
    @State private var errorMessage: String?
    @State private var isShowingError = false
    @State private var streamingTask: Task<Void, Never>?
    @State private var activeTurn: ActiveTextTurn?
    @State private var assistantPresentation = AssistantPresentationState()
    @Namespace private var accessoryMenuNamespace
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        database: PlantDatabase,
        client: OpenAICompatibleClient,
        toolExecutor: PlantDataToolExecutor,
        plantBinding: PlantConversationBinding,
        initialMessage: String,
        initialMessageID: UUID,
        initialMessageDate: Date,
        isInitialTransitionComplete: Bool,
        completedMessageFlightID: UUID?,
        startedMessageFlightID: UUID?,
        onMessageFlightRequested: @escaping (MessageFlightRequest) -> Void,
        onMessageFlightCancelled: @escaping (UUID) -> Void,
        onHome: @escaping () -> Void
    ) {
        self.database = database
        self.client = client
        self.toolExecutor = toolExecutor
        self.plantBinding = plantBinding
        self.initialMessage = initialMessage
        self.initialMessageID = initialMessageID
        self.initialMessageDate = initialMessageDate
        self.isInitialTransitionComplete = isInitialTransitionComplete
        self.completedMessageFlightID = completedMessageFlightID
        self.startedMessageFlightID = startedMessageFlightID
        self.onMessageFlightRequested = onMessageFlightRequested
        self.onMessageFlightCancelled = onMessageFlightCancelled
        self.onHome = onHome
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !isInitialMessageDiscarded {
                        InitialTextMessageBubble(
                            text: initialMessage,
                            createdAt: initialMessageDate,
                            transitionID: initialMessageID,
                            isTransitionComplete: isInitialTransitionComplete
                        )
                        .id(initialMessageID)
                    }

                    ForEach(messages) { message in
                        if message.id != initialMessageID {
                            ChatMessageBubble(
                                message: message,
                                flightDestinationID: outgoingTransition?.id == message.id
                                    && outgoingTransition?.presentation == .messageFlight
                                    ? message.id
                                    : nil,
                                reportsFlightDestination: flightDestinationReadyID == message.id,
                                isFlightComplete: outgoingTransition?.presentation != .messageFlight
                                    || outgoingTransition?.id != message.id
                                    || completedMessageFlightID == message.id
                            )
                            .id(message.id)
                        }
                    }

                    StreamingAssistantMessageRow(
                        state: streamingAssistantState,
                        isPresentationEnabled: assistantPresentation.isOpen
                    )
                    .id(StreamingAssistantMessageRow.anchorID)

                    ConversationBottomMarker()
                }
                .padding()
                .padding(.top)
            }
            .trackConversationBottom($isScrolledToBottom)
            .plantTalkBottomBar {
                if isComposerVisible {
                    inputBar
                }
            }
            .overlay(alignment: .top) {
                if isWaitingForFirstToken, assistantPresentation.isOpen {
                    ModelThinkingIndicator()
                        .padding(.vertical, 8)
                        .transition(thinkingTransition)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                // Assistant growth and completion must never pull a reader away
                // from the part of the transcript they chose to inspect.
                if messages.last?.role == .assistant {
                    return
                }

                if !isInitialTransitionComplete,
                   messages.last?.id == initialMessageID {
                    return
                }

                if let pendingCatchUpMessageID,
                   messages.last?.id == pendingCatchUpMessageID {
                    self.pendingCatchUpMessageID = nil
                    scrollToLatest(
                        using: proxy,
                        animation: reduceMotion
                            ? nil
                            : .easeOut(duration: ConversationMotion.catchUpDuration)
                    )
                    completeAssistantPresentationAfterCatchUp(
                        id: pendingCatchUpMessageID
                    )
                    return
                }

                if let outgoing = outgoingTransition,
                   outgoing.presentation == .messageFlight,
                   messages.last?.id == outgoing.id {
                    scrollToLatest(using: proxy, animation: nil)
                    prepareMessageFlightDestination(
                        id: outgoing.id
                    )
                    return
                }

                scrollToLatest(
                    using: proxy,
                    animation: outgoingTransition?.presentation == .messageFlight
                        ? nil
                        : .easeOut(duration: 0.2)
                )
            }
        }
        .background {
            ChatConversationBackdrop()
                .ignoresSafeArea()
        }
        .overlay {
            mediaPanelOverlay
        }
        .task {
            startInitialMessage()
        }
        .task(id: isInitialTransitionComplete) {
            guard isInitialTransitionComplete else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isComposerVisible = true
            }
            completeAssistantPresentation(id: initialMessageID)
        }
        .onChange(of: completedMessageFlightID) { _, completedID in
            if let completedID {
                completeAssistantPresentation(id: completedID)
                if flightDestinationReadyID == completedID {
                    flightDestinationReadyID = nil
                }
            }
            guard let completedID,
                  var outgoing = outgoingTransition,
                  outgoing.id == completedID else { return }
            outgoing.hasCompletedFlight = true
            outgoingTransition = outgoing.isPersisted ? nil : outgoing
        }
        .onChange(of: startedMessageFlightID) { _, startedID in
            guard let startedID,
                  let outgoing = outgoingTransition,
                  outgoing.id == startedID,
                  outgoing.presentation == .messageFlight else { return }
            if trimmedDraft == outgoing.text {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    draft = ""
                }
            }
            clearRecommittedDraftIfNeeded(afterSubmitting: outgoing.text)
        }
        .onDisappear {
            streamingTask?.cancel()
            mediaPanelAnimationTask?.cancel()
            attachmentTransferTask?.cancel()
        }
        .alert("对话失败", isPresented: $isShowingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private var inputBar: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 10) {
                    inputBarContent
                }
            } else {
                inputBarContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var inputBarContent: some View {
        HStack(alignment: .bottom, spacing: 10) {
            accessoryButton(
                systemName: isAccessoryMenuExpanded ? "xmark" : "ellipsis",
                accessibilityLabel: isAccessoryMenuExpanded ? "收起菜单" : "打开菜单",
                glassID: "conversation-menu-toggle",
                action: toggleAccessoryMenu
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateComposerMenuButtonFrame(proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                            updateComposerMenuButtonFrame(newFrame)
                        }
                }
            }

            ZStack(alignment: .bottomLeading) {
                composerControls

                if isAccessoryMenuExpanded {
                    accessoryActionButtons
                        .transition(horizontalMenuTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                isAttachmentTransferInProgress ? nil : accessoryMenuAnimation,
                value: isAccessoryMenuExpanded
            )
        }
    }

    private var composerControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            composerTextEntry
                .messageFlightSource()
                .onPreferenceChange(MessageFlightSourcePreferenceKey.self) {
                    composerFrame = $0
                }

            sendButton
                .offset(
                    x: isAccessoryMenuExpanded
                        ? ConversationMotion.hiddenComposerOffset
                        : 0
                )
                .allowsHitTesting(!isAccessoryMenuExpanded)
        }
    }

    private var accessoryActionButtons: some View {
        HStack(spacing: 10) {
            accessoryButton(
                systemName: "rectangle.portrait.and.arrow.right",
                accessibilityLabel: "退出对话",
                glassID: "conversation-exit",
                tint: Color(uiColor: .systemRed),
                action: onHome
            )
            mediaAccessoryButton(
                source: .camera,
                systemName: "camera.fill",
                accessibilityLabel: "拍摄",
                glassID: "conversation-camera"
            )
            mediaAccessoryButton(
                source: .photoLibrary,
                systemName: "photo.on.rectangle",
                accessibilityLabel: "相册",
                glassID: "conversation-library"
            )
        }
    }

    @ViewBuilder
    private func mediaAccessoryButton(
        source: ConversationMediaSource,
        systemName: String,
        accessibilityLabel: String,
        glassID: String
    ) -> some View {
        Group {
            if activeMediaPanel == source {
                accessoryButton(
                    systemName: systemName,
                    accessibilityLabel: accessibilityLabel,
                    glassID: glassID,
                    action: { presentMediaPanel(source) }
                )
                .hidden()
                .accessibilityHidden(true)
            } else {
                accessoryButton(
                    systemName: systemName,
                    accessibilityLabel: accessibilityLabel,
                    glassID: glassID,
                    action: { presentMediaPanel(source) }
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateMediaButtonFrame(
                            proxy.frame(in: .global),
                            for: source
                        )
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                        updateMediaButtonFrame(newFrame, for: source)
                    }
            }
        }
    }

    private var baseComposerTextEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingImageAttachments.isEmpty {
                composerAttachmentStrip
            }

            ZStack(alignment: .leading) {
                TextField(
                    "输入消息",
                    text: $draft,
                    prompt: Text(""),
                    axis: .vertical
                )
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .foregroundStyle(
                        isAccessoryMenuExpanded ? Color.clear : Color.primary
                    )
                    .tint(
                        isAccessoryMenuExpanded ? Color.clear : Color.accentColor
                    )
                    .submitLabel(.send)
                    .onSubmit {
                        guard !isStreaming else { return }
                        startSending(draft)
                    }
                    .onChange(of: draft) { _, newValue in
                        handleComposerDraftChange(newValue)
                    }

                if draft.isEmpty {
                    Text("输入消息…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, isInputFocused ? 5 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateComposerTextFieldFrame(proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                            updateComposerTextFieldFrame(newFrame)
                        }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .opacity(isAccessoryMenuExpanded ? 0 : 1)
    }

    @ViewBuilder
    private var composerAttachmentStrip: some View {
        let strip = ConversationAttachmentStrip(
            attachments: pendingImageAttachments,
            isInteractive: true,
            onRemove: removePendingImageAttachment
        )

        if pendingImageAttachments.count == 1 {
            strip
                .opacity(isAttachmentTransferInProgress ? 0 : 1)
                .fixedSize(horizontal: true, vertical: true)
                .background(attachmentStripFrameReader)
        } else {
            strip
                .opacity(isAttachmentTransferInProgress ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(attachmentStripFrameReader)
        }
    }

    private var attachmentStripFrameReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateAttachmentStripFrame(proxy.frame(in: .global))
                }
                .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                    updateAttachmentStripFrame(newFrame)
                }
        }
    }

    private var mediaPanelOverlay: some View {
        GeometryReader { proxy in
            let panelWidth = max(
                0,
                proxy.size.width - (ConversationMediaLayout.horizontalInset * 2)
            )
            let panelHeight = mediaPanelHeight(for: proxy.size.height)
            let overlayFrame = proxy.frame(in: .global)
            let panelCornerSize = mediaPanelCornerSize(for: proxy)

            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(
                        0.18
                            * mediaPanelExpansionProgress
                            * (1 - attachmentTransferProgress)
                    )
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissMediaPanel)

                if let activeMediaPanel {
                    let destinationFrame = CGRect(
                        x: overlayFrame.minX + ConversationMediaLayout.horizontalInset,
                        y: overlayFrame.maxY
                            - ConversationMediaLayout.bottomInset
                            - panelHeight,
                        width: panelWidth,
                        height: panelHeight
                    )
                    let sourceFrame = mediaButtonFrames[activeMediaPanel.rawValue]
                        ?? destinationFrame

                    ConversationMediaPanel(
                        source: activeMediaPanel,
                        onDismiss: dismissMediaPanel,
                        onAttachments: attachImagesToComposer
                    )
                    .frame(width: panelWidth, height: panelHeight)
                    .background {
                        // safeAreaBar changes the overlay's default child placement.
                        // Track the rendered panel itself so the closing path lands exactly.
                        GeometryReader { panelProxy in
                            Color.clear
                                .onAppear {
                                    updateMediaPanelPresentedFrame(
                                        panelProxy.frame(in: .global)
                                    )
                                }
                                .onChange(of: panelProxy.frame(in: .global)) { _, newFrame in
                                    updateMediaPanelPresentedFrame(newFrame)
                                }
                        }
                    }
                    .modifier(
                        ConversationMediaMorphModifier(
                            progress: mediaPanelExpansionProgress,
                            sourceFrame: sourceFrame,
                            destinationFrame: destinationFrame,
                            destinationCornerSize: panelCornerSize,
                            baseColor: activeMediaPanel == .camera
                                ? .black
                                : Color(uiColor: .secondarySystemBackground),
                            sourceSystemName: activeMediaPanel == .camera
                                ? "camera.fill"
                                : "photo.on.rectangle"
                        )
                    )
                    .modifier(
                        ConversationAttachmentTransferModifier(
                            progress: attachmentTransferProgress,
                            isActive: isAttachmentTransferInProgress
                                && !attachmentTransferAttachments.isEmpty
                                && !attachmentTransferTargetFrame.isEmpty
                                && !attachmentTransferPanelFrame.isEmpty,
                            panelFrame: attachmentTransferPanelFrame.isEmpty
                                ? destinationFrame
                                : attachmentTransferPanelFrame,
                            targetFrame: attachmentTransferTargetFrame,
                            attachments: attachmentTransferAttachments,
                            panelCornerSize: panelCornerSize,
                            baseColor: activeMediaPanel == .camera
                                ? .black
                                : Color(uiColor: .secondarySystemBackground)
                        )
                    )
                    // Resolve the 12pt inset from the physical bottom edge,
                    // not from the bottom-bar-adjusted implicit alignment.
                    .position(
                        x: destinationFrame.midX - overlayFrame.minX,
                        y: destinationFrame.midY - overlayFrame.minY
                    )
                    .transition(.identity)
                }
            }
        }
        .allowsHitTesting(activeMediaPanel != nil)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var composerTextEntry: some View {
        if #available(iOS 26, *) {
            baseComposerTextEntry
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 24)
                )
                .glassEffectID(
                    "conversation-composer",
                    in: accessoryMenuNamespace
                )
                .offset(
                    x: isAccessoryMenuExpanded
                        ? ConversationMotion.hiddenComposerOffset
                        : 0
                )
        } else {
            baseComposerTextEntry
                .background {
                    composerSurface
                }
        }
    }

    @ViewBuilder
    private var composerSurface: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.4))
            }
            .offset(
                x: isAccessoryMenuExpanded
                    ? ConversationMotion.hiddenComposerOffset
                    : 0
            )
    }

    @ViewBuilder
    private func accessoryButton(
        systemName: String,
        accessibilityLabel: String,
        glassID: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26, *) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(tint)
            .glassEffectID(glassID, in: accessoryMenuNamespace)
            .glassEffectTransition(.matchedGeometry)
            .accessibilityLabel(accessibilityLabel)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(tint)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if #available(iOS 26, *) {
            Button(action: handleSendButton) {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(isStreaming ? Color(uiColor: .systemRed) : Color.accentColor)
            .glassEffectID("conversation-send", in: accessoryMenuNamespace)
            .glassEffectTransition(.matchedGeometry)
            .disabled(trimmedDraft.isEmpty && !isStreaming)
            .accessibilityLabel(isStreaming ? "停止生成" : "发送")
        } else {
            Button(action: handleSendButton) {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(isStreaming ? Color(uiColor: .systemRed) : Color.accentColor)
            .disabled(trimmedDraft.isEmpty && !isStreaming)
            .accessibilityLabel(isStreaming ? "停止生成" : "发送")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var thinkingTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .top)
            .combined(with: .scale(scale: 0.9, anchor: .top))
            .combined(with: .opacity)
    }

    private var horizontalMenuTransition: AnyTransition {
        reduceMotion ? .identity : .move(edge: .leading)
    }

    private var accessoryMenuAnimation: Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.42, dampingFraction: 0.82)
    }

    private var mediaPanelAnimation: Animation? {
        reduceMotion
            ? nil
            : .linear(duration: 0.4)
    }

    private var attachmentTransferAnimation: Animation? {
        reduceMotion
            ? nil
            : .timingCurve(0.22, 0.72, 0.22, 1, duration: 0.48)
    }

    private func toggleAccessoryMenu() {
        withAnimation(accessoryMenuAnimation) {
            isAccessoryMenuExpanded.toggle()
        }
    }

    private func presentMediaPanel(_ source: ConversationMediaSource) {
        isInputFocused = false
        mediaPanelAnimationTask?.cancel()
        attachmentTransferTask?.cancel()

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMediaPanel = source
            mediaPanelPresentedFrame = .zero
            mediaPanelExpansionProgress = reduceMotion ? 1 : 0
            attachmentTransferProgress = 0
            attachmentTransferTargetFrame = .zero
            attachmentTransferPanelFrame = .zero
            attachmentTransferAttachments = []
            isAttachmentTransferInProgress = false
        }

        guard !reduceMotion else { return }
        mediaPanelAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, activeMediaPanel == source else { return }
            withAnimation(mediaPanelAnimation) {
                mediaPanelExpansionProgress = 1
            }
        }
    }

    private func dismissMediaPanel() {
        mediaPanelAnimationTask?.cancel()

        guard !reduceMotion else {
            activeMediaPanel = nil
            mediaPanelExpansionProgress = 0
            isAccessoryMenuExpanded = true
            return
        }

        withAnimation(mediaPanelAnimation) {
            mediaPanelExpansionProgress = 0
        }
        mediaPanelAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(440))
            guard !Task.isCancelled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                activeMediaPanel = nil
                isAccessoryMenuExpanded = true
            }
        }
    }

    private func attachImagesToComposer(
        _ attachments: [ConversationImageAttachment]
    ) {
        guard !attachments.isEmpty else { return }
        mediaPanelAnimationTask?.cancel()
        attachmentTransferTask?.cancel()

        var knownIDs = Set(pendingImageAttachments.map(\.id))
        var mergedAttachments = pendingImageAttachments
        for attachment in attachments where knownIDs.insert(attachment.id).inserted {
            mergedAttachments.append(attachment)
        }

        guard !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pendingImageAttachments = mergedAttachments
                activeMediaPanel = nil
                mediaPanelExpansionProgress = 0
                attachmentTransferProgress = 0
                attachmentTransferTargetFrame = .zero
                attachmentTransferPanelFrame = .zero
                attachmentTransferAttachments = []
                isAttachmentTransferInProgress = false
                isAccessoryMenuExpanded = false
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            attachmentStripFrame = .zero
            attachmentTransferTargetFrame = .zero
            attachmentTransferPanelFrame = .zero
            pendingImageAttachments = mergedAttachments
            attachmentTransferAttachments = mergedAttachments
            attachmentTransferProgress = 0
            isAttachmentTransferInProgress = true
            isAccessoryMenuExpanded = false
        }

        attachmentTransferTask = Task { @MainActor in
            var previousFrame = CGRect.zero
            var stableFrameCount = 0

            // Wait only for the new composer geometry to be committed. Two
            // matching frames are sufficient; the old fixed waits added at
            // least 120ms after every completed camera capture.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let currentFrame = attachmentStripFrame
                guard !currentFrame.isEmpty else { continue }

                if framesAreNearlyEqual(currentFrame, previousFrame) {
                    stableFrameCount += 1
                } else {
                    stableFrameCount = 0
                }
                previousFrame = currentFrame

                if stableFrameCount >= 1 {
                    break
                }
            }

            guard !Task.isCancelled else { return }
            guard !attachmentStripFrame.isEmpty,
                  !composerTextFieldFrame.isEmpty,
                  !composerMenuButtonFrame.isEmpty,
                  !mediaPanelPresentedFrame.isEmpty else {
                completeAttachmentTransfer()
                return
            }

            // The menu control shares the composer's bottom alignment and stays
            // visible during transfer, making it a stable destination anchor.
            let transferTarget = CGRect(
                x: attachmentStripFrame.minX,
                y: composerMenuButtonFrame.maxY
                    - 12
                    - composerTextFieldFrame.height
                    - 10
                    - ConversationAttachmentLayout.itemSide,
                width: attachmentStripFrame.width,
                height: ConversationAttachmentLayout.itemSide
            )

            var targetTransaction = Transaction(animation: nil)
            targetTransaction.disablesAnimations = true
            withTransaction(targetTransaction) {
                attachmentTransferTargetFrame = transferTarget
                attachmentTransferPanelFrame = mediaPanelPresentedFrame
            }
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }

            withAnimation(attachmentTransferAnimation) {
                attachmentTransferProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            completeAttachmentTransfer()
        }
    }

    private func updateMediaButtonFrame(
        _ frame: CGRect,
        for source: ConversationMediaSource
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        if mediaButtonFrames[source.rawValue] != frame {
            mediaButtonFrames[source.rawValue] = frame
        }
    }

    private func updateMediaPanelPresentedFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard !isAttachmentTransferInProgress else { return }
        if mediaPanelPresentedFrame != frame {
            mediaPanelPresentedFrame = frame
        }
    }

    private func updateAttachmentStripFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if attachmentStripFrame != frame {
            attachmentStripFrame = frame
        }
    }

    private func updateComposerTextFieldFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if composerTextFieldFrame != frame {
            composerTextFieldFrame = frame
        }
    }

    private func updateComposerMenuButtonFrame(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if composerMenuButtonFrame != frame {
            composerMenuButtonFrame = frame
        }
    }

    private func completeAttachmentTransfer() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMediaPanel = nil
            mediaPanelExpansionProgress = 0
            attachmentTransferProgress = 0
            attachmentTransferTargetFrame = .zero
            attachmentTransferPanelFrame = .zero
            attachmentTransferAttachments = []
            isAttachmentTransferInProgress = false
        }
        attachmentTransferTask = nil
    }

    private func framesAreNearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func removePendingImageAttachment(id: String) {
        withAnimation(mediaPanelAnimation) {
            pendingImageAttachments.removeAll { $0.id == id }
        }
    }

    private func mediaPanelHeight(for availableHeight: CGFloat) -> CGFloat {
        let desiredHeight = max(availableHeight * 0.6, 480)
        return min(min(desiredHeight, max(availableHeight - 24, 0)), 560)
    }

    private func mediaPanelCornerSize(for proxy: GeometryProxy) -> CGSize {
        if #available(iOS 26, *) {
            let cornerInsets = proxy.containerCornerInsets
            let screenCornerSize = CGSize(
                width: max(
                    cornerInsets.bottomLeading.width,
                    cornerInsets.bottomTrailing.width
                ),
                height: max(
                    cornerInsets.bottomLeading.height,
                    cornerInsets.bottomTrailing.height
                )
            )
            let concentricCornerSize = CGSize(
                width: screenCornerSize.width - ConversationMediaLayout.horizontalInset,
                height: screenCornerSize.height - ConversationMediaLayout.bottomInset
            )

            if concentricCornerSize.width > 0,
               concentricCornerSize.height > 0 {
                return concentricCornerSize
            }
        }

        return ConversationMediaLayout.fallbackCornerSize
    }

    private func startInitialMessage() {
        guard !hasStartedInitialMessage else { return }
        hasStartedInitialMessage = true
        startSending(initialMessage, replacesPendingMessage: true)
    }

    private func startSending(
        _ rawText: String,
        replacesPendingMessage: Bool = false
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !isStreaming,
              !isDiscardingTurn,
              replacesPendingMessage || !composerFrame.isEmpty else { return }

        do {
            let configuration = try AISettingsStore.configuration()
            let outgoing: OutgoingMessageTransition?
            if replacesPendingMessage {
                if !isInitialTransitionComplete {
                    assistantPresentation.block(id: initialMessageID)
                }
                outgoing = nil
            } else {
                let staged = OutgoingMessageTransition(
                    id: UUID(),
                    text: text,
                    createdAt: Date(),
                    presentation: isScrolledToBottom
                        ? .messageFlight
                        : .scrollToBottom
                )
                outgoingTransition = staged
                flightDestinationReadyID = nil
                assistantPresentation.block(id: staged.id)
                outgoing = staged

                let provisionalMessage = ChatMessage(
                    id: staged.id,
                    conversationID: conversation?.id ?? UUID(),
                    role: .user,
                    content: staged.text,
                    createdAt: staged.createdAt
                )
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if staged.presentation == .scrollToBottom {
                        draft = ""
                        pendingCatchUpMessageID = staged.id
                    }
                    messages.append(provisionalMessage)
                }
                if staged.presentation == .scrollToBottom {
                    clearRecommittedDraftIfNeeded(afterSubmitting: text)
                }

                if staged.presentation == .messageFlight {
                    onMessageFlightRequested(MessageFlightRequest(
                        id: staged.id,
                        text: staged.text,
                        createdAt: staged.createdAt,
                        sourceFrame: composerFrame,
                        showsOverlayWhilePreparing: false
                    ))
                }
            }
            let turn = ActiveTextTurn(
                userMessageID: replacesPendingMessage ? initialMessageID : outgoing?.id ?? UUID(),
                assistantMessageID: UUID(),
                isInitialMessage: replacesPendingMessage
            )
            activeTurn = turn
            isStreaming = true
            withAnimation(.easeOut(duration: 0.16)) {
                isWaitingForFirstToken = true
            }
            streamingTask = Task {
                if Task.isCancelled {
                    if let outgoing {
                        restoreComposer(afterFailed: outgoing)
                    }
                    isStreaming = false
                    isWaitingForFirstToken = false
                    streamingTask = nil
                    return
                }
                await performSend(
                    text,
                    configuration: configuration,
                    turn: turn,
                    outgoing: outgoing
                )
                if activeTurn == turn {
                    activeTurn = nil
                }
            }
        } catch {
            showError(error)
        }
    }

    private func handleSendButton() {
        if isStreaming {
            stopAndDiscardActiveTurn()
        } else {
            startSending(draft)
        }
    }

    private func performSend(
        _ text: String,
        configuration: AIConfiguration,
        turn: ActiveTextTurn,
        outgoing: OutgoingMessageTransition?
    ) async {
        defer {
            isStreaming = false
            streamingTask = nil
            withAnimation(.easeOut(duration: 0.16)) {
                isWaitingForFirstToken = false
            }
        }

        do {
            let activeConversation: AIConversation
            if let conversation {
                activeConversation = conversation
            } else {
                let created = try await database.createConversation(
                    title: conversationTitle(from: text)
                )
                conversation = created
                activeConversation = created
            }

            let userMessage = ChatMessage(
                id: turn.userMessageID,
                conversationID: activeConversation.id,
                role: .user,
                content: text,
                createdAt: turn.isInitialMessage
                    ? initialMessageDate
                    : outgoing?.createdAt ?? Date()
            )
            try await database.saveChatMessage(userMessage)
            presentUserMessage(
                userMessage,
                replacesPendingMessage: turn.isInitialMessage,
                outgoing: outgoing
            )

            try Task.checkCancellation()

            var requestMessages: [AIRequestMessage] = []
            let prompt = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolInstructions = """
                \(PlantDataToolCatalog.usageInstructions)

                当前本地时间：\(Date().formatted(date: .abbreviated, time: .standard))（\(TimeZone.current.identifier)）。
                """
            requestMessages.append(AIRequestMessage(
                role: .system,
                content: [prompt, plantBinding.modelInstructions, toolInstructions]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            ))
            requestMessages.append(contentsOf: messages.map {
                AIRequestMessage(role: $0.role, content: $0.content)
            })

            streamingAssistantState.begin(ChatMessage(
                id: turn.assistantMessageID,
                conversationID: activeConversation.id,
                role: .assistant,
                content: "",
                createdAt: Date()
            ))

            do {
                let adapter = TextModelAdapter(client: client)
                let invocations = try await adapter.respond(
                    configuration: configuration,
                    initialMessages: requestMessages,
                    executor: toolExecutor,
                    onTextDelta: { delta in
                        streamingAssistantState.append(delta)
                        if assistantPresentation.isOpen,
                           isWaitingForFirstToken,
                           streamingAssistantState.hasVisibleContent {
                            withAnimation(.easeOut(duration: 0.16)) {
                                isWaitingForFirstToken = false
                            }
                        }
                    },
                    onToolCallRound: {
                        // Reset any protocol-only text before the model receives
                        // tool results and starts its final natural-language turn.
                        streamingAssistantState.begin(ChatMessage(
                            id: turn.assistantMessageID,
                            conversationID: activeConversation.id,
                            role: .assistant,
                            content: "",
                            createdAt: Date()
                        ))
                    }
                )
                streamingAssistantState.attachToolInvocations(invocations)

                guard let assistant = streamingAssistantState.message,
                      streamingAssistantState.hasVisibleContent else {
                    streamingAssistantState.clear()
                    throw AIClientError.emptyResponse
                }
                try await database.saveChatMessage(assistant)
                try await waitForAssistantPresentationCompletion(
                    id: presentationID(
                        replacesPendingMessage: turn.isInitialMessage,
                        outgoing: outgoing
                    )
                )
                commitStreamingAssistant(assistant)
            } catch {
                if let assistant = streamingAssistantState.message,
                   streamingAssistantState.hasVisibleContent {
                    try? await database.saveChatMessage(assistant)
                    if !Task.isCancelled {
                        do {
                            try await waitForAssistantPresentationCompletion(
                                id: presentationID(
                                    replacesPendingMessage: turn.isInitialMessage,
                                    outgoing: outgoing
                                )
                            )
                            commitStreamingAssistant(assistant)
                        } catch {
                            streamingAssistantState.clear()
                        }
                    } else {
                        streamingAssistantState.clear()
                    }
                } else {
                    streamingAssistantState.clear()
                }
                if !Task.isCancelled {
                    throw error
                }
            }
        } catch {
            if let outgoing {
                restoreComposer(afterFailed: outgoing)
            }
            if !Task.isCancelled {
                try? await waitForAssistantPresentationCompletion(
                    id: presentationID(
                        replacesPendingMessage: turn.isInitialMessage,
                        outgoing: outgoing
                    )
                )
                showError(error)
            }
        }
    }

    private func presentUserMessage(
        _ message: ChatMessage,
        replacesPendingMessage: Bool,
        outgoing: OutgoingMessageTransition?
    ) {
        if replacesPendingMessage {
            messages.append(message)
            return
        }

        guard let outgoing else {
            messages.append(message)
            draft = ""
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let index = messages.firstIndex(where: { $0.id == outgoing.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            if var active = outgoingTransition, active.id == outgoing.id {
                active.isPersisted = true
                outgoingTransition = active.hasCompletedFlight ? nil : active
            }
        }
    }

    private func restoreComposer(afterFailed outgoing: OutgoingMessageTransition) {
        guard let active = outgoingTransition,
              active.id == outgoing.id,
              !active.isPersisted else { return }
        onMessageFlightCancelled(outgoing.id)
        assistantPresentation.complete(id: outgoing.id)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            messages.removeAll { $0.id == outgoing.id }
            draft = outgoing.text
            if pendingCatchUpMessageID == outgoing.id {
                pendingCatchUpMessageID = nil
            }
            if flightDestinationReadyID == outgoing.id {
                flightDestinationReadyID = nil
            }
            outgoingTransition = nil
        }
    }

    private func stopAndDiscardActiveTurn() {
        guard !isDiscardingTurn,
              let turn = activeTurn else {
            streamingTask?.cancel()
            return
        }

        isDiscardingTurn = true
        let task = streamingTask
        task?.cancel()
        discardTurnFromPresentation(turn)

        Task { @MainActor in
            await task?.value
            defer {
                if activeTurn == turn {
                    activeTurn = nil
                }
                isDiscardingTurn = false
            }

            guard let activeConversation = conversation else { return }
            do {
                let deletedConversation = try await database.deleteChatTurn(
                    conversationID: activeConversation.id,
                    messageIDs: [turn.userMessageID, turn.assistantMessageID]
                )
                if deletedConversation, conversation?.id == activeConversation.id {
                    conversation = nil
                }
            } catch {
                showError(error)
            }
        }
    }

    private func discardTurnFromPresentation(_ turn: ActiveTextTurn) {
        onMessageFlightCancelled(turn.userMessageID)
        assistantPresentation.complete(id: turn.userMessageID)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if turn.isInitialMessage {
                isInitialMessageDiscarded = true
            }
            messages.removeAll {
                $0.id == turn.userMessageID || $0.id == turn.assistantMessageID
            }
            streamingAssistantState.clear()
            if pendingCatchUpMessageID == turn.userMessageID {
                pendingCatchUpMessageID = nil
            }
            if flightDestinationReadyID == turn.userMessageID {
                flightDestinationReadyID = nil
            }
            if outgoingTransition?.id == turn.userMessageID {
                outgoingTransition = nil
            }
            draft = ""
        }
    }

    private func handleComposerDraftChange(_ newValue: String) {
        guard newValue.last?.isNewline == true else { return }

        var submittedText = newValue
        while submittedText.last?.isNewline == true {
            submittedText.removeLast()
        }
        draft = submittedText

        guard !isStreaming else { return }
        startSending(submittedText)
    }

    private func clearRecommittedDraftIfNeeded(afterSubmitting text: String) {
        Task { @MainActor in
            await Task.yield()
            let currentDraft = trimmedDraft
            if currentDraft.isEmpty || currentDraft == text {
                draft = ""
            }
        }
    }

    private func prepareMessageFlightDestination(id: UUID) {
        Task { @MainActor in
            await Task.yield()
            guard outgoingTransition?.id == id,
                  outgoingTransition?.presentation == .messageFlight else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                flightDestinationReadyID = id
            }
        }
    }

    private func completeAssistantPresentationAfterCatchUp(id: UUID) {
        Task { @MainActor in
            if !reduceMotion {
                do {
                    try await Task.sleep(
                        for: .milliseconds(ConversationMotion.catchUpDurationMilliseconds)
                    )
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
            completeAssistantPresentation(id: id)
        }
    }

    private func completeAssistantPresentation(id: UUID) {
        assistantPresentation.complete(id: id)
        guard assistantPresentation.isOpen else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            isWaitingForFirstToken = isStreaming
                && !streamingAssistantState.hasVisibleContent
        }
    }

    private func presentationID(
        replacesPendingMessage: Bool,
        outgoing: OutgoingMessageTransition?
    ) -> UUID? {
        if replacesPendingMessage {
            return initialMessageID
        }
        return outgoing?.id
    }

    private func waitForAssistantPresentationCompletion(id: UUID?) async throws {
        guard let id else { return }
        while assistantPresentation.isBlocked(by: id) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func commitStreamingAssistant(_ assistant: ChatMessage) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            messages.append(assistant)
            streamingAssistantState.clear()
        }
    }

    private func scrollToLatest(
        using proxy: ScrollViewProxy,
        animation: Animation?
    ) {
        guard !messages.isEmpty else { return }
        withAnimation(animation) {
            proxy.scrollTo(ConversationBottomMarker.anchorID, anchor: .bottom)
        }
    }

    private func conversationTitle(from text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(28))
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private struct OutgoingMessageTransition: Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let presentation: OutgoingMessagePresentation
    var hasCompletedFlight: Bool
    var isPersisted = false

    init(
        id: UUID,
        text: String,
        createdAt: Date,
        presentation: OutgoingMessagePresentation
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.presentation = presentation
        hasCompletedFlight = presentation != .messageFlight
    }
}

private struct ActiveTextTurn: Equatable {
    let userMessageID: UUID
    let assistantMessageID: UUID
    let isInitialMessage: Bool
}

private enum OutgoingMessagePresentation: Equatable {
    case messageFlight
    case scrollToBottom
}

private enum ConversationMotion {
    static let bottomTolerance: CGFloat = 32
    static let catchUpDuration = 0.24
    static let catchUpDurationMilliseconds = 240
    static let hiddenComposerOffset: CGFloat = -1_000
}

private struct ConversationBottomMarker: View {
    static let anchorID = "text-conversation-bottom"

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Color.clear
            } else {
                Color.clear
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ConversationContentBottomPreferenceKey.self,
                                value: proxy.frame(
                                    in: .named(conversationScrollCoordinateSpace)
                                ).maxY
                            )
                        }
                    }
            }
        }
        .frame(height: 1)
        .id(Self.anchorID)
        .accessibilityHidden(true)
    }
}

private struct ConversationBottomTrackingModifier: ViewModifier {
    @Binding var isAtBottom: Bool
    @State private var legacyContentBottom: CGFloat = 0
    @State private var legacyViewportHeight: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY
                        >= geometry.contentSize.height - ConversationMotion.bottomTolerance
                } action: { _, newValue in
                    isAtBottom = newValue
                }
        } else {
            content
                .coordinateSpace(name: conversationScrollCoordinateSpace)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConversationViewportHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onPreferenceChange(ConversationContentBottomPreferenceKey.self) {
                    legacyContentBottom = $0
                    updateLegacyBottomState()
                }
                .onPreferenceChange(ConversationViewportHeightPreferenceKey.self) {
                    legacyViewportHeight = $0
                    updateLegacyBottomState()
                }
        }
    }

    private func updateLegacyBottomState() {
        guard legacyContentBottom > 0,
              legacyViewportHeight > 0 else { return }
        isAtBottom = legacyContentBottom
            <= legacyViewportHeight + ConversationMotion.bottomTolerance
    }
}

private struct ConversationContentBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func trackConversationBottom(_ isAtBottom: Binding<Bool>) -> some View {
        modifier(ConversationBottomTrackingModifier(isAtBottom: isAtBottom))
    }
}

@MainActor
@Observable
private final class AssistantPresentationState {
    private(set) var blockingID: UUID?

    var isOpen: Bool {
        blockingID == nil
    }

    func block(id: UUID) {
        blockingID = id
    }

    func complete(id: UUID) {
        guard blockingID == id else { return }
        blockingID = nil
    }

    func isBlocked(by id: UUID) -> Bool {
        blockingID == id
    }
}

@MainActor
@Observable
private final class StreamingAssistantState {
    private(set) var message: ChatMessage?

    var hasVisibleContent: Bool {
        guard let message else { return false }
        return !message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var visibleMessage: ChatMessage? {
        hasVisibleContent ? message : nil
    }

    func begin(_ message: ChatMessage) {
        self.message = message
    }

    func append(_ delta: String) {
        guard var message else { return }
        message.content += delta
        self.message = message
    }

    func clear() {
        message = nil
    }

    func attachToolInvocations(_ invocations: [ToolInvocation]) {
        guard var message else { return }
        message.toolInvocations = invocations
        self.message = message
    }
}

@MainActor
private struct StreamingAssistantMessageRow: View {
    static let anchorID = "streaming-assistant-message"

    let state: StreamingAssistantState
    let isPresentationEnabled: Bool

    var body: some View {
        Group {
            if isPresentationEnabled,
               let message = state.visibleMessage {
                ChatMessageBubble(message: message)
                    .transition(.opacity)
            }
        }
    }
}

private struct InitialTextMessageBubble: View {
    let text: String
    let createdAt: Date
    let transitionID: UUID
    let isTransitionComplete: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            if isTransitionComplete {
                ChatBubbleSurface(role: .user) {
                    ChatBubblePayload(
                        text: text,
                        createdAt: createdAt
                    )
                }
            } else {
                UserBubbleFlightPlaceholder(
                    text: text,
                    createdAt: createdAt,
                    destinationID: transitionID
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("我的消息")
    }
}

struct ChatMessageBubble: View {
    let message: ChatMessage
    let flightDestinationID: UUID?
    let reportsFlightDestination: Bool
    let isFlightComplete: Bool

    init(
        message: ChatMessage,
        flightDestinationID: UUID? = nil,
        reportsFlightDestination: Bool = true,
        isFlightComplete: Bool = true
    ) {
        self.message = message
        self.flightDestinationID = flightDestinationID
        self.reportsFlightDestination = reportsFlightDestination
        self.isFlightComplete = isFlightComplete
    }

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            if let flightDestinationID, !isFlightComplete {
                UserBubbleFlightPlaceholder(
                    text: message.content,
                    createdAt: message.createdAt,
                    destinationID: reportsFlightDestination
                        ? flightDestinationID
                        : nil
                )
            } else {
                ChatBubbleSurface(role: message.role) {
                    ChatBubblePayload(
                        text: message.content,
                        createdAt: message.createdAt,
                        toolInvocations: message.role == .assistant
                            ? message.toolInvocations
                            : []
                    )
                }
            }

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "我的消息" : "植物回复")
    }
}

private struct UserBubbleFlightPlaceholder: View {
    let text: String
    let createdAt: Date
    let destinationID: UUID?

    var body: some View {
        ChatBubblePayload(
            text: text,
            createdAt: createdAt
        )
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .padding(.vertical, 11)
        .hidden()
        .messageFlightDestination(id: destinationID)
        .accessibilityHidden(true)
    }
}

private struct ChatBubblePayload: View {
    let text: String
    let createdAt: Date
    let toolInvocations: [ToolInvocation]

    init(
        text: String,
        createdAt: Date,
        toolInvocations: [ToolInvocation] = []
    ) {
        self.text = text
        self.createdAt = createdAt
        self.toolInvocations = toolInvocations
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !toolInvocations.isEmpty {
                ToolInvocationDisclosure(invocations: toolInvocations)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            Text(createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolInvocationDisclosure: View {
    let invocations: [ToolInvocation]

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var countTitle: String {
        "已查询 \(invocations.count) 项数据"
    }

    private var compactSummary: String {
        let summaries = invocations
            .map(\.summary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !summaries.isEmpty else {
            return invocations.map { $0.displayMetadata.title }.joined(separator: " · ")
        }

        let visible = summaries.prefix(2).joined(separator: " · ")
        return summaries.count > 2 ? "\(visible) 等" : visible
    }

    var body: some View {
        disclosureSurface
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var disclosureSurface: some View {
        let content = disclosureContent
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

        if #available(iOS 26, *) {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.09)),
                    in: .rect(cornerRadius: 13)
                )
        } else {
            content
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 0.5)
                }
        }
    }

    private var disclosureContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggleExpanded) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.weight(.semibold))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(countTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        if !compactSummary.isEmpty {
                            Text(compactSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(countTitle)。\(compactSummary)")
            .accessibilityHint(isExpanded ? "收起工具调用详情" : "展开工具调用详情")

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(invocations) { invocation in
                        ToolInvocationRow(invocation: invocation)
                    }
                }
                .transition(detailsTransition)
            }
        }
    }

    private var detailsTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct ToolInvocationRow: View {
    let invocation: ToolInvocation

    @State private var isRawDataExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: invocation.displayMetadata.iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(invocation.displayMetadata.tint)
                    .frame(width: 17, height: 17)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(invocation.displayMetadata.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !invocation.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(invocation.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button(action: toggleRawData) {
                HStack(spacing: 5) {
                    Image(systemName: "curlybraces")
                    Text("原始数据")
                    Spacer(minLength: 0)
                    Image(systemName: isRawDataExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 25)
            .accessibilityLabel("\(invocation.displayMetadata.title)的原始数据")
            .accessibilityHint(isRawDataExpanded ? "收起原始数据" : "展开原始数据")

            if isRawDataExpanded {
                ToolInvocationRawData(invocation: invocation)
                    .padding(.leading, 25)
                    .transition(rawDataTransition)
            }
        }
        .padding(8)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var rawDataTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private func toggleRawData() {
        if reduceMotion {
            isRawDataExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                isRawDataExpanded.toggle()
            }
        }
    }
}

private struct ToolInvocationRawData: View {
    let invocation: ToolInvocation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JSONValueBlock(
                title: "调用参数",
                value: invocation.argumentsJSON,
                emptyPlaceholder: "此工具不需要参数"
            )

            JSONValueBlock(
                title: "工具结果",
                value: invocation.resultJSON,
                emptyPlaceholder: "没有返回数据"
            )
        }
    }
}

private struct JSONValueBlock: View {
    let title: String
    let value: String
    let emptyPlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(prettyPrintedJSON)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
    }

    private var prettyPrintedJSON: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyPlaceholder }
        guard let sourceData = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: sourceData),
              JSONSerialization.isValidJSONObject(object),
              let formattedData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let formatted = String(data: formattedData, encoding: .utf8) else {
            return trimmed
        }
        return formatted
    }
}

private extension ToolInvocation {
    struct DisplayMetadata {
        let title: String
        let iconName: String
        let tint: Color
    }

    var displayMetadata: DisplayMetadata {
        switch toolName {
        case "get_current_sensor_reading":
            DisplayMetadata(
                title: "当前实时读数",
                iconName: "dot.radiowaves.left.and.right",
                tint: .green
            )
        case "refresh_current_sensor_reading":
            DisplayMetadata(
                title: "立即采样",
                iconName: "sensor.tag.radiowaves.forward",
                tint: .teal
            )
        case "get_latest_historical_reading":
            DisplayMetadata(
                title: "最近历史记录",
                iconName: "clock.arrow.circlepath",
                tint: .orange
            )
        case "get_sensor_summary":
            DisplayMetadata(
                title: "传感器汇总",
                iconName: "chart.bar.xaxis",
                tint: .blue
            )
        case "get_sensor_series":
            DisplayMetadata(
                title: "传感器趋势",
                iconName: "chart.xyaxis.line",
                tint: .purple
            )
        default:
            DisplayMetadata(
                title: "植物数据查询",
                iconName: "leaf.circle",
                tint: .teal
            )
        }
    }
}

struct ModelThinkingIndicator: View {
    @State private var activeDot = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        indicatorSurface
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(180))
                    } catch {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeDot = (activeDot + 1) % 3
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("模型正在思考")
    }

    @ViewBuilder
    private var indicatorSurface: some View {
        let dots = HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .scaleEffect(reduceMotion || activeDot == index ? 1 : 0.65)
                    .offset(y: reduceMotion || activeDot == index ? -2 : 1)
                    .opacity(reduceMotion || activeDot == index ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if #available(iOS 26, *) {
            dots.glassEffect(.regular, in: .capsule)
        } else {
            dots.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct ChatBubbleSurface<Content: View>: View {
    let role: ChatRole
    private let content: Content

    init(role: ChatRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    var body: some View {
        let shape = ChatBubbleShape(
            tailSide: role == .user ? .trailing : .leading
        )

        if #available(iOS 26, *) {
            if role == .user {
                paddedContent
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.22)),
                        in: shape
                    )
            } else {
                paddedContent
                    .glassEffect(.regular, in: shape)
            }
        } else {
            paddedContent
                .background {
                    shape.fill(.ultraThinMaterial)
                    if role == .user {
                        shape.fill(Color.accentColor.opacity(0.14))
                    }
                }
                .overlay {
                    shape.stroke(
                        Color(uiColor: .separator).opacity(0.35),
                        lineWidth: 0.5
                    )
                }
        }
    }

    private var paddedContent: some View {
        content
            .padding(.leading, role == .user ? 14 : 20)
            .padding(.trailing, role == .user ? 20 : 14)
            .padding(.vertical, 11)
    }
}

/// A single, continuous outline keeps the glass surface and its border from
/// rendering a seam where the bubble body meets its tail.
struct ChatBubbleShape: Shape {
    enum TailSide {
        case leading
        case trailing
    }

    let tailSide: TailSide

    func path(in rect: CGRect) -> Path {
        let tailWidth = min(10, rect.width * 0.08)
        let tailHeight = min(12, rect.height * 0.3)
        let cornerRadius = min(18, max(10, rect.height * 0.28))
        let bodyRect: CGRect

        switch tailSide {
        case .leading:
            bodyRect = CGRect(
                x: rect.minX + tailWidth,
                y: rect.minY,
                width: rect.width - tailWidth,
                height: rect.height
            )
        case .trailing:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width - tailWidth,
                height: rect.height
            )
        }

        switch tailSide {
        case .leading:
            return leadingTailPath(
                in: bodyRect,
                bounds: rect,
                cornerRadius: cornerRadius,
                tailHeight: tailHeight
            )
        case .trailing:
            return trailingTailPath(
                in: bodyRect,
                bounds: rect,
                cornerRadius: cornerRadius,
                tailHeight: tailHeight
            )
        }
    }

    private func trailingTailPath(
        in body: CGRect,
        bounds: CGRect,
        cornerRadius: CGFloat,
        tailHeight: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: body.minX + cornerRadius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - cornerRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + cornerRadius),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - tailHeight))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX, y: body.maxY),
            control: CGPoint(x: body.maxX + (bounds.maxX - body.maxX) * 0.2, y: body.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - cornerRadius * 0.8, y: body.maxY),
            control: CGPoint(x: body.maxX - (bounds.maxX - body.maxX) * 0.05, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX + cornerRadius, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - cornerRadius),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + cornerRadius, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }

    private func leadingTailPath(
        in body: CGRect,
        bounds: CGRect,
        cornerRadius: CGFloat,
        tailHeight: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: body.minX + cornerRadius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - cornerRadius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + cornerRadius),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - cornerRadius, y: body.maxY),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX + cornerRadius * 0.8, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: body.maxY),
            control: CGPoint(x: body.minX + (bounds.minX - body.minX) * 0.05, y: body.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - tailHeight),
            control: CGPoint(x: body.minX + (bounds.minX - body.minX) * 0.2, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + cornerRadius, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct ChatConversationBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color(uiColor: .systemGreen).opacity(0.1), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 380
            )
        }
    }
}

@MainActor
private struct TextConversationBottomBarPreview: View {
    @State private var draft = "测试液态玻璃透明度"
    @State private var isAccessoryMenuExpanded = false
    @Namespace private var accessoryMenuNamespace
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            ChatConversationBackdrop()
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sampleMessages) { message in
                        ChatMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
                .padding(.top)
            }
            .plantTalkBottomBar {
                bottomBar
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 10) {
                    bottomBarContent
                }
            } else {
                bottomBarContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var bottomBarContent: some View {
        HStack(alignment: .bottom, spacing: 10) {
            previewAccessoryButton(
                systemName: isAccessoryMenuExpanded ? "xmark" : "ellipsis",
                glassID: "preview-menu-toggle"
            ) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    isAccessoryMenuExpanded.toggle()
                }
            }

            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 10) {
                    composerTextEntry

                    sendButton
                        .offset(
                            x: isAccessoryMenuExpanded
                                ? ConversationMotion.hiddenComposerOffset
                                : 0
                        )
                        .allowsHitTesting(!isAccessoryMenuExpanded)
                }

                if isAccessoryMenuExpanded {
                    previewAccessoryActionButtons
                        .transition(.move(edge: .leading))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(
                .spring(response: 0.42, dampingFraction: 0.82),
                value: isAccessoryMenuExpanded
            )
        }
    }

    private var previewAccessoryActionButtons: some View {
        HStack(spacing: 10) {
            previewAccessoryButton(
                systemName: "rectangle.portrait.and.arrow.right",
                glassID: "preview-exit",
                tint: Color(uiColor: .systemRed)
            ) {}
            previewAccessoryButton(systemName: "camera.fill", glassID: "preview-camera") {}
            previewAccessoryButton(systemName: "photo.on.rectangle", glassID: "preview-library") {}
        }
    }

    private var sampleMessages: [ChatMessage] {
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let baseDate = Date(timeIntervalSince1970: 1_788_800_000)
        let samples: [(ChatRole, String)] = [
            (.user, "早上好，今天植物的状态怎么样？"),
            (.assistant, "早上好！目前温度和湿度都比较舒适，土壤水分也处于正常范围，叶片状态很稳定。"),
            (.user, "需要现在浇水吗？"),
            (.assistant, "暂时不需要。建议等土壤湿度继续下降后再少量补水，避免根部长期处于过湿环境。"),
            (.user, "窗边上午会有两小时阳光，这样够吗？"),
            (.assistant, "两小时柔和的晨光很合适。如果中午光线变强，可以稍微拉开与玻璃的距离，避免叶片被灼伤。"),
            (.user, "请帮我整理一个今天的养护计划。"),
            (.assistant, "今天保持正常通风即可；上午接受柔和散射光，中午观察叶片温度，傍晚再次检查土壤湿度。没有明显干燥时不需要浇水。"),
            (.user, "如果叶尖出现小水珠，需要处理吗？"),
            (.assistant, "少量水珠通常是植物的吐水现象，不必特别处理。保持空气流通，并避免叶片长期潮湿即可。")
        ]

        return samples.enumerated().map { index, sample in
            ChatMessage(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 10))!,
                conversationID: conversationID,
                role: sample.0,
                content: sample.1,
                createdAt: baseDate.addingTimeInterval(Double(index) * 75)
            )
        }
    }

    private var baseComposerTextEntry: some View {
        ZStack(alignment: .leading) {
            TextField(
                "输入消息",
                text: $draft,
                prompt: Text(""),
                axis: .vertical
            )
                .lineLimit(1...5)
                .focused($isInputFocused)
                .foregroundStyle(
                    isAccessoryMenuExpanded ? Color.clear : Color.primary
                )
                .tint(
                    isAccessoryMenuExpanded ? Color.clear : Color.accentColor
                )

            if draft.isEmpty {
                Text("输入消息…")
                    .foregroundStyle(.secondary)
                    .padding(.leading, isInputFocused ? 5 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var composerTextEntry: some View {
        if #available(iOS 26, *) {
            baseComposerTextEntry
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 24)
                )
                .glassEffectID("preview-composer", in: accessoryMenuNamespace)
                .offset(
                    x: isAccessoryMenuExpanded
                        ? ConversationMotion.hiddenComposerOffset
                        : 0
                )
        } else {
            baseComposerTextEntry
                .background {
                    composerSurface
                }
        }
    }

    @ViewBuilder
    private var composerSurface: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.4))
            }
            .offset(
                x: isAccessoryMenuExpanded
                    ? ConversationMotion.hiddenComposerOffset
                    : 0
            )
    }

    @ViewBuilder
    private func previewAccessoryButton(
        systemName: String,
        glassID: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 26, *) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(tint)
            .glassEffectID(glassID, in: accessoryMenuNamespace)
            .glassEffectTransition(.matchedGeometry)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(tint)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if #available(iOS 26, *) {
            Button(action: {}) {
                Image(systemName: "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(Color.accentColor)
            .glassEffectID("preview-send", in: accessoryMenuNamespace)
            .glassEffectTransition(.matchedGeometry)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            Button(action: {}) {
                Image(systemName: "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(Color.accentColor)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

#Preview("Text Conversation · 底部输入栏") {
    TextConversationBottomBarPreview()
}

extension View {
    @ViewBuilder
    func plantTalkBottomBar<Bar: View>(
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }
}

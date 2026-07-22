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

typealias ConversationImagePreviewAction = (
    _ image: UIImage,
    _ sourceID: String,
    _ sourceFrame: CGRect
) -> Void

private struct ConversationAttachmentStrip: View {
    let attachments: [ConversationImageAttachment]
    let isInteractive: Bool
    let activePreviewSourceID: String?
    let onPreview: ConversationImagePreviewAction?
    let onRemove: (String) -> Void

    init(
        attachments: [ConversationImageAttachment],
        isInteractive: Bool,
        activePreviewSourceID: String? = nil,
        onPreview: ConversationImagePreviewAction? = nil,
        onRemove: @escaping (String) -> Void
    ) {
        self.attachments = attachments
        self.isInteractive = isInteractive
        self.activePreviewSourceID = activePreviewSourceID
        self.onPreview = onPreview
        self.onRemove = onRemove
    }

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
        let sourceID = "composer:\(attachment.id)"

        return ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                Button {
                    onPreview?(
                        attachment.image,
                        sourceID,
                        proxy.frame(in: .global)
                    )
                } label: {
                    attachmentThumbnail(attachment.image, sourceID: sourceID)
                        .frame(
                            width: ConversationAttachmentLayout.itemSide,
                            height: ConversationAttachmentLayout.itemSide
                        )
                        .clipShape(RoundedRectangle(
                            cornerRadius: ConversationAttachmentLayout.cornerRadius,
                            style: .continuous
                        ))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isInteractive && onPreview != nil)
                .accessibilityLabel("预览第\(index + 1)张照片")
            }

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
            .opacity(activePreviewSourceID == sourceID ? 0 : 1)
            .accessibilityLabel("移除第\(index + 1)张照片")
        }
        .frame(
            width: ConversationAttachmentLayout.itemSide,
            height: ConversationAttachmentLayout.itemSide
        )
    }

    @ViewBuilder
    private func attachmentThumbnail(
        _ image: UIImage,
        sourceID: String
    ) -> some View {
        if activePreviewSourceID == sourceID {
            Color.clear
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

private struct ConversationImagePreviewItem: Identifiable {
    let id: String
    let image: UIImage
    let sourceFrame: CGRect
}

private struct ConversationImagePreviewOverlay: View {
    let item: ConversationImagePreviewItem
    let progress: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let overlayFrame = proxy.frame(in: .global)
            let sourceFrame = item.sourceFrame.offsetBy(
                dx: -overlayFrame.minX,
                dy: -overlayFrame.minY
            )
            let destinationFrame = previewFrame(in: proxy)
            let currentFrame = interpolatedFrame(
                from: sourceFrame,
                to: destinationFrame,
                progress: progress
            )
            let destinationCorner = previewCornerSize(
                previewFrame: destinationFrame,
                proxy: proxy
            )
            let currentCorner = CGSize(
                width: interpolate(
                    ConversationAttachmentLayout.cornerRadius,
                    destinationCorner.width,
                    progress
                ),
                height: interpolate(
                    ConversationAttachmentLayout.cornerRadius,
                    destinationCorner.height,
                    progress
                )
            )

            ZStack {
                Color.clear

                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: max(currentFrame.width, 1),
                        height: max(currentFrame.height, 1)
                    )
                    .clipShape(ConversationMediaMorphShape(
                        cornerWidth: currentCorner.width,
                        cornerHeight: currentCorner.height
                    ))
                    .position(x: currentFrame.midX, y: currentFrame.midY)
                    .accessibilityLabel("图片预览")
                    .accessibilityHint("轻点关闭预览")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
        }
        .ignoresSafeArea()
    }

    private func previewFrame(in proxy: GeometryProxy) -> CGRect {
        let horizontalInset = proxy.size.width * 0.06
            + max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
        let verticalInset = proxy.size.height * 0.06
            + max(proxy.safeAreaInsets.top, proxy.safeAreaInsets.bottom)
        let availableSize = CGSize(
            width: max(proxy.size.width - horizontalInset * 2, 0),
            height: max(proxy.size.height - verticalInset * 2, 0)
        )
        let imageSize = aspectFitSize(item.image.size, inside: availableSize)
        return CGRect(
            x: (proxy.size.width - imageSize.width) / 2,
            y: (proxy.size.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private func aspectFitSize(_ source: CGSize, inside bounds: CGSize) -> CGSize {
        guard source.width > 0,
              source.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private func previewCornerSize(
        previewFrame: CGRect,
        proxy: GeometryProxy
    ) -> CGSize {
        guard proxy.size.width > 0, proxy.size.height > 0 else { return .zero }
        let screenCorner = screenCornerSize(in: proxy)
        return CGSize(
            width: (screenCorner.width / proxy.size.width) * previewFrame.width,
            height: (screenCorner.height / proxy.size.height) * previewFrame.height
        )
    }

    private func screenCornerSize(in proxy: GeometryProxy) -> CGSize {
        if #available(iOS 26, *) {
            let insets = proxy.containerCornerInsets
            let cornerSize = CGSize(
                width: [
                    insets.topLeading.width,
                    insets.topTrailing.width,
                    insets.bottomLeading.width,
                    insets.bottomTrailing.width
                ].max() ?? 0,
                height: [
                    insets.topLeading.height,
                    insets.topTrailing.height,
                    insets.bottomLeading.height,
                    insets.bottomTrailing.height
                ].max() ?? 0
            )
            if cornerSize.width > 0, cornerSize.height > 0 {
                return cornerSize
            }
        }

        let screenMinimum = min(proxy.size.width, proxy.size.height)
        let radius = min(
            max(proxy.safeAreaInsets.top * 0.72, screenMinimum * 0.06),
            screenMinimum * 0.14
        )
        return CGSize(width: radius, height: radius)
    }

    private func interpolatedFrame(
        from source: CGRect,
        to destination: CGRect,
        progress: CGFloat
    ) -> CGRect {
        CGRect(
            x: interpolate(source.minX, destination.minX, progress),
            y: interpolate(source.minY, destination.minY, progress),
            width: interpolate(source.width, destination.width, progress),
            height: interpolate(source.height, destination.height, progress)
        )
    }

    private func interpolate(
        _ start: CGFloat,
        _ end: CGFloat,
        _ progress: CGFloat
    ) -> CGFloat {
        start + ((end - start) * min(max(progress, 0), 1))
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
    let memoryStore: PlantMemoryStore
    let toolExecutor: PlantDataToolExecutor
    let plantBinding: PlantConversationBinding
    let initialMessage: String
    let initialMessageID: UUID
    let initialMessageDate: Date
    let isResumedConversation: Bool
    let isPagePresented: Bool
    let isPageTransitioning: Bool
    let isInitialTransitionComplete: Bool
    let completedMessageFlightID: UUID?
    let startedMessageFlightID: UUID?
    let configurationProvider: () throws -> AIConfiguration
    let onMessageFlightRequested: (MessageFlightRequest) -> Void
    let onMessageFlightCancelled: (UUID) -> Void
    let onHome: () -> Void

    @State private var conversation: AIConversation?
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var composerFrame = CGRect.zero
    @State private var outgoingTransition: OutgoingMessageTransition?
    @State private var messageFlightComposerReservation: MessageFlightComposerReservation?
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
    @State private var imagePreviewItem: ConversationImagePreviewItem?
    @State private var imagePreviewProgress: CGFloat = 0
    @State private var hasStartedInitialMessage = false
    @State private var errorTitle = "对话失败"
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
        memoryStore: PlantMemoryStore,
        toolExecutor: PlantDataToolExecutor,
        plantBinding: PlantConversationBinding,
        initialMessage: String,
        initialMessageID: UUID,
        initialMessageDate: Date,
        resumedConversation: AIConversation? = nil,
        resumedMessages: [ChatMessage] = [],
        isPagePresented: Bool = true,
        isPageTransitioning: Bool = false,
        isInitialTransitionComplete: Bool,
        completedMessageFlightID: UUID?,
        startedMessageFlightID: UUID?,
        initialPendingImageAttachments: [ConversationImageAttachment] = [],
        configurationProvider: @escaping () throws -> AIConfiguration = {
            try AISettingsStore.configuration()
        },
        onMessageFlightRequested: @escaping (MessageFlightRequest) -> Void,
        onMessageFlightCancelled: @escaping (UUID) -> Void,
        onHome: @escaping () -> Void
    ) {
        self.database = database
        self.client = client
        self.memoryStore = memoryStore
        self.toolExecutor = toolExecutor
        self.plantBinding = plantBinding
        self.initialMessage = initialMessage
        self.initialMessageID = initialMessageID
        self.initialMessageDate = initialMessageDate
        self.isResumedConversation = resumedConversation != nil
        self.isPagePresented = isPagePresented
        self.isPageTransitioning = isPageTransitioning
        self.isInitialTransitionComplete = isInitialTransitionComplete
        self.completedMessageFlightID = completedMessageFlightID
        self.startedMessageFlightID = startedMessageFlightID
        self.configurationProvider = configurationProvider
        self.onMessageFlightRequested = onMessageFlightRequested
        self.onMessageFlightCancelled = onMessageFlightCancelled
        self.onHome = onHome
        _conversation = State(initialValue: resumedConversation)
        _messages = State(initialValue: resumedMessages)
        _isInitialMessageDiscarded = State(initialValue: resumedConversation != nil)
        _isComposerVisible = State(initialValue: resumedConversation != nil)
        _hasStartedInitialMessage = State(initialValue: resumedConversation != nil)
        _pendingImageAttachments = State(initialValue: initialPendingImageAttachments)
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
                                activeImagePreviewSourceID: imagePreviewItem?.id,
                                onImagePreview: presentImagePreview,
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
            .task {
                startInitialMessage()
                guard isResumedConversation,
                      let lastMessageID = messages.last?.id else { return }
                await Task.yield()
                proxy.scrollTo(lastMessageID, anchor: .bottom)
            }
        }
        .background {
            ChatConversationBackdrop()
                .ignoresSafeArea()
        }
        .overlay {
            mediaPanelOverlay
        }
        .overlay {
            if let imagePreviewItem {
                ConversationImagePreviewOverlay(
                    item: imagePreviewItem,
                    progress: imagePreviewProgress,
                    onDismiss: dismissImagePreview
                )
                .transition(.identity)
            }
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
                releaseMessageFlightComposerReservation(for: completedID)
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
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if trimmedDraft == outgoing.composerText {
                    draft = ""
                }
                if pendingImageAttachments.map(\.id)
                    == outgoing.composerAttachments.map(\.id) {
                    pendingImageAttachments = []
                }
            }
            clearRecommittedDraftIfNeeded(afterSubmitting: outgoing.composerText)
        }
        .onChange(of: isPagePresented) { _, isPresented in
            guard !isPresented else { return }
            prepareForPageExit()
        }
        .onDisappear {
            streamingTask?.cancel()
            mediaPanelAnimationTask?.cancel()
            attachmentTransferTask?.cancel()
        }
        .alert(errorTitle, isPresented: $isShowingError) {
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
                // Clearing an image composer makes safeAreaBar shorter. Keep
                // its previous height until the flight reaches the bubble.
                .frame(
                    height: messageFlightComposerReservation?.height,
                    alignment: .bottom
                )
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
            activePreviewSourceID: imagePreviewItem?.id,
            onPreview: presentImagePreview,
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
            .disabled(!canSendComposerContent && !isStreaming)
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
            .disabled(!canSendComposerContent && !isStreaming)
            .accessibilityLabel(isStreaming ? "停止生成" : "发送")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSendComposerContent: Bool {
        !trimmedDraft.isEmpty || !pendingImageAttachments.isEmpty
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

    private func prepareForPageExit() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInputFocused = false
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

    private func presentImagePreview(
        _ image: UIImage,
        sourceID: String,
        sourceFrame: CGRect
    ) {
        guard imagePreviewItem == nil, !sourceFrame.isEmpty else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            imagePreviewProgress = 0
            imagePreviewItem = ConversationImagePreviewItem(
                id: sourceID,
                image: image,
                sourceFrame: sourceFrame
            )
        }

        Task { @MainActor in
            await Task.yield()
            guard imagePreviewItem?.id == sourceID else { return }
            withAnimation(imagePreviewAnimation) {
                imagePreviewProgress = 1
            }
        }
    }

    private func dismissImagePreview() {
        guard let sourceID = imagePreviewItem?.id else { return }
        // `.smooth` has a visual spring tail. Keep the overlay alive until that
        // tail is fully removed so its last rendered frame matches the source.
        withAnimation(
            imagePreviewAnimation,
            completionCriteria: .removed
        ) {
            imagePreviewProgress = 0
        } completion: {
            guard imagePreviewItem?.id == sourceID,
                  imagePreviewProgress <= 0.001 else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                imagePreviewItem = nil
            }
        }
    }

    private var imagePreviewAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .smooth(duration: 0.42)
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
        let attachments = replacesPendingMessage ? [] : pendingImageAttachments
        guard !text.isEmpty || !attachments.isEmpty,
              !isStreaming,
              !isDiscardingTurn,
              replacesPendingMessage || !composerFrame.isEmpty else { return }

        do {
            let configuration = try configurationProvider()
            let imageAttachments = try attachments.map {
                try $0.encodedChatAttachment()
            }
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
                    imageAttachments: imageAttachments,
                    composerText: text,
                    composerAttachments: attachments,
                    createdAt: Date(),
                    presentation: isScrolledToBottom
                        ? .messageFlight
                        : .scrollToBottom
                )
                var stagingTransaction = Transaction(animation: nil)
                stagingTransaction.disablesAnimations = true
                withTransaction(stagingTransaction) {
                    outgoingTransition = staged
                    flightDestinationReadyID = nil
                    messageFlightComposerReservation = staged.presentation == .messageFlight
                        ? MessageFlightComposerReservation(
                            id: staged.id,
                            height: composerFrame.height
                        )
                        : nil
                }
                assistantPresentation.block(id: staged.id)
                outgoing = staged

                let provisionalMessage = ChatMessage(
                    id: staged.id,
                    conversationID: conversation?.id ?? UUID(),
                    role: .user,
                    content: staged.text,
                    createdAt: staged.createdAt,
                    imageAttachments: staged.imageAttachments
                )
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if staged.presentation == .scrollToBottom {
                        draft = ""
                        pendingImageAttachments = []
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
                        imageAttachments: staged.imageAttachments,
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
                    imageAttachments: imageAttachments,
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
        imageAttachments: [ChatImageAttachment],
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
                    title: text.isEmpty ? "图片对话" : conversationTitle(from: text)
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
                    : outgoing?.createdAt ?? Date(),
                imageAttachments: imageAttachments
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
            let memoryInstructions = (try? await memoryStore.promptContext()) ?? ""
            let toolInstructions = """
                \(PlantDataToolCatalog.usageInstructions)

                当前本地时间：\(Date().formatted(date: .abbreviated, time: .standard))（\(TimeZone.current.identifier)）。
                """
            requestMessages.append(AIRequestMessage(
                role: .system,
                content: [
                    prompt,
                    plantBinding.modelInstructions,
                    memoryInstructions,
                    toolInstructions
                ]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            ))
            requestMessages.append(contentsOf: messages.map { message in
                AIRequestMessage(
                    role: message.role,
                    content: message.id == userMessage.id ? text : message.content,
                    imageDataURLs: message.imageAttachments.map(\.dataURL)
                )
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

                guard let assistant = streamingAssistantState.finalizedMessage(),
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
                if let assistant = streamingAssistantState.finalizedMessage(),
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
            if trimmedDraft.isEmpty {
                draft = outgoing.composerText
            }
            let pendingIDs = Set(pendingImageAttachments.map(\.id))
            pendingImageAttachments = outgoing.composerAttachments.filter {
                !pendingIDs.contains($0.id)
            } + pendingImageAttachments
            if pendingCatchUpMessageID == outgoing.id {
                pendingCatchUpMessageID = nil
            }
            if flightDestinationReadyID == outgoing.id {
                flightDestinationReadyID = nil
            }
            if messageFlightComposerReservation?.id == outgoing.id {
                messageFlightComposerReservation = nil
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
            if messageFlightComposerReservation?.id == turn.userMessageID {
                messageFlightComposerReservation = nil
            }
            draft = ""
            pendingImageAttachments = []
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

    private func releaseMessageFlightComposerReservation(for id: UUID) {
        Task { @MainActor in
            // First let ContentView remove the overlay and reveal the real
            // bubble. The compact empty composer can take over next frame.
            await Task.yield()
            guard messageFlightComposerReservation?.id == id else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                messageFlightComposerReservation = nil
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
        if let clientError = error as? AIClientError,
           case .unsupportedImageInput = clientError {
            errorTitle = "无法发送图片"
        } else {
            errorTitle = "对话失败"
        }
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private struct OutgoingMessageTransition: Equatable {
    let id: UUID
    let text: String
    let imageAttachments: [ChatImageAttachment]
    let composerText: String
    let composerAttachments: [ConversationImageAttachment]
    let createdAt: Date
    let presentation: OutgoingMessagePresentation
    var hasCompletedFlight: Bool
    var isPersisted = false

    init(
        id: UUID,
        text: String,
        imageAttachments: [ChatImageAttachment],
        composerText: String,
        composerAttachments: [ConversationImageAttachment],
        createdAt: Date,
        presentation: OutgoingMessagePresentation
    ) {
        self.id = id
        self.text = text
        self.imageAttachments = imageAttachments
        self.composerText = composerText
        self.composerAttachments = composerAttachments
        self.createdAt = createdAt
        self.presentation = presentation
        hasCompletedFlight = presentation != .messageFlight
    }
}

private struct MessageFlightComposerReservation: Equatable {
    let id: UUID
    let height: CGFloat
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
    static let stableAssistantWidthCharacterCount = 160
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
    @ObservationIgnored private var bufferedDelta = ""
    @ObservationIgnored private var bufferedToolInvocations: [ToolInvocation] = []
    @ObservationIgnored private var scheduledFlush: Task<Void, Never>?

    var hasVisibleContent: Bool {
        let displayedContent = message?.content ?? ""
        return !displayedContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            || !bufferedDelta
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    var visibleMessage: ChatMessage? {
        hasVisibleContent ? message : nil
    }

    func begin(_ message: ChatMessage) {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        bufferedDelta = ""
        bufferedToolInvocations = []
        self.message = message
    }

    func append(_ delta: String) {
        guard message != nil, !delta.isEmpty else { return }
        let hadVisibleContent = hasVisibleContent
        bufferedDelta += delta

        // Show the first visible token immediately. Subsequent tiny deltas are
        // coalesced so Markdown parsing and TextKit layout do not run once per
        // network event.
        if !hadVisibleContent {
            flushBufferedDelta()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    func clear() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        bufferedDelta = ""
        bufferedToolInvocations = []
        message = nil
    }

    func attachToolInvocations(_ invocations: [ToolInvocation]) {
        bufferedToolInvocations = invocations
    }

    func finalizedMessage() -> ChatMessage? {
        guard var finalized = message else { return nil }
        finalized.content += bufferedDelta
        finalized.toolInvocations = bufferedToolInvocations
        return finalized
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            self.scheduledFlush = nil
            self.flushBufferedDelta()
        }
    }

    private func flushBufferedDelta() {
        guard !bufferedDelta.isEmpty,
              var updated = message else { return }
        scheduledFlush?.cancel()
        scheduledFlush = nil
        updated.content += bufferedDelta
        bufferedDelta = ""
        message = updated
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
                ChatMessageBubble(
                    message: message,
                    usesStableAssistantWidth: true
                )
                    .transition(.opacity)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
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
                    imageAttachments: [],
                    createdAt: createdAt,
                    destinationID: transitionID
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("我的消息")
    }
}

struct ChatMessageBubble: View {
    let message: ChatMessage
    let activeImagePreviewSourceID: String?
    let onImagePreview: ConversationImagePreviewAction?
    let flightDestinationID: UUID?
    let reportsFlightDestination: Bool
    let isFlightComplete: Bool
    let usesStableAssistantWidth: Bool

    init(
        message: ChatMessage,
        activeImagePreviewSourceID: String? = nil,
        onImagePreview: ConversationImagePreviewAction? = nil,
        flightDestinationID: UUID? = nil,
        reportsFlightDestination: Bool = true,
        isFlightComplete: Bool = true,
        usesStableAssistantWidth: Bool = false
    ) {
        self.message = message
        self.activeImagePreviewSourceID = activeImagePreviewSourceID
        self.onImagePreview = onImagePreview
        self.flightDestinationID = flightDestinationID
        self.reportsFlightDestination = reportsFlightDestination
        self.isFlightComplete = isFlightComplete
        self.usesStableAssistantWidth = usesStableAssistantWidth
    }

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            if let flightDestinationID, !isFlightComplete {
                UserBubbleFlightPlaceholder(
                    text: message.content,
                    imageAttachments: message.imageAttachments,
                    createdAt: message.createdAt,
                    destinationID: reportsFlightDestination
                        ? flightDestinationID
                        : nil
                )
            } else {
                ChatBubbleSurface(role: message.role) {
                    ChatBubblePayload(
                        text: message.content,
                        rendersMarkdown: message.role == .assistant,
                        usesStableTextWidth: shouldUseStableAssistantWidth,
                        imageAttachments: message.imageAttachments,
                        activeImagePreviewSourceID: activeImagePreviewSourceID,
                        onImagePreview: onImagePreview,
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "我的消息" : "植物回复")
    }

    private var shouldUseStableAssistantWidth: Bool {
        message.role == .assistant
            && (usesStableAssistantWidth
                || message.content.index(
                    message.content.startIndex,
                    offsetBy: ConversationMotion.stableAssistantWidthCharacterCount,
                    limitedBy: message.content.endIndex
                ) != nil)
    }
}

private struct UserBubbleFlightPlaceholder: View {
    let text: String
    let imageAttachments: [ChatImageAttachment]
    let createdAt: Date
    let destinationID: UUID?

    var body: some View {
        ChatBubblePayload(
            text: text,
            imageAttachments: imageAttachments,
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
    let rendersMarkdown: Bool
    let usesStableTextWidth: Bool
    let imageAttachments: [ChatImageAttachment]
    let activeImagePreviewSourceID: String?
    let onImagePreview: ConversationImagePreviewAction?
    let createdAt: Date
    let toolInvocations: [ToolInvocation]

    init(
        text: String,
        rendersMarkdown: Bool = false,
        usesStableTextWidth: Bool = false,
        imageAttachments: [ChatImageAttachment] = [],
        activeImagePreviewSourceID: String? = nil,
        onImagePreview: ConversationImagePreviewAction? = nil,
        createdAt: Date,
        toolInvocations: [ToolInvocation] = []
    ) {
        self.text = text
        self.rendersMarkdown = rendersMarkdown
        self.usesStableTextWidth = usesStableTextWidth
        self.imageAttachments = imageAttachments
        self.activeImagePreviewSourceID = activeImagePreviewSourceID
        self.onImagePreview = onImagePreview
        self.createdAt = createdAt
        self.toolInvocations = toolInvocations
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if !imageAttachments.isEmpty {
                ChatBubbleImageGrid(
                    attachments: imageAttachments,
                    activePreviewSourceID: activeImagePreviewSourceID,
                    onPreview: onImagePreview
                )
            }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SelectableMessageText(
                    text: text,
                    rendersMarkdown: rendersMarkdown,
                    usesStableWidth: usesStableTextWidth
                )
                    .fixedSize(horizontal: false, vertical: true)
            }

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

/// Converts the block syntax commonly returned by chat models into one
/// selectable attributed string. Keeping a single `UITextView` preserves the
/// native long-press selection and edit menu used by conversation bubbles.
private enum MarkdownMessageRenderer {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
    }

    static func render(_ markdown: String, width: CGFloat) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = codeFence(in: trimmed) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index]
                        .trimmingCharacters(in: .whitespaces)
                        .hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                appendCode(codeLines.joined(separator: "\n"), to: output)
                continue
            }

            if index + 1 < lines.count,
               isTableSeparator(lines[index + 1]),
               let header = tableCells(in: line),
               header.count > 1 {
                var rows: [[String]] = [header]
                index += 2
                while index < lines.count,
                      let cells = tableCells(in: lines[index]),
                      cells.count > 1,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells)
                    index += 1
                }
                appendTable(rows, width: width, to: output)
                continue
            }

            if trimmed.isEmpty {
                appendBlankLine(to: output)
                index += 1
                continue
            }

            if let heading = heading(in: trimmed) {
                appendInline(
                    heading.text,
                    font: headingFont(level: heading.level),
                    paragraphStyle: paragraphStyle(
                        spacingBefore: output.length == 0 ? 0 : 7,
                        spacingAfter: 5
                    ),
                    forceBold: true,
                    to: output
                )
                appendNewline(to: output)
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                let rule = NSAttributedString(
                    string: "────────────────────",
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption1),
                        .foregroundColor: UIColor.separator,
                        .paragraphStyle: paragraphStyle(
                            spacingBefore: 5,
                            spacingAfter: 6
                        )
                    ]
                )
                output.append(rule)
                appendNewline(to: output)
                index += 1
                continue
            }

            if let item = listItem(in: line) {
                let indent = CGFloat(item.depth) * 16
                let style = paragraphStyle(spacingAfter: 3)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 22
                style.tabStops = [NSTextTab(
                    textAlignment: .left,
                    location: indent + 22
                )]
                appendPlain("\(item.marker)\t", style: style, to: output)
                appendInline(
                    item.text,
                    font: .preferredFont(forTextStyle: .body),
                    paragraphStyle: style,
                    to: output
                )
                appendNewline(style: style, to: output)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let quoted = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                let style = paragraphStyle(spacingAfter: 4)
                style.firstLineHeadIndent = 0
                style.headIndent = 17
                style.tabStops = [NSTextTab(
                    textAlignment: .left,
                    location: 17
                )]
                appendPlain(
                    "│\t",
                    style: style,
                    color: .tertiaryLabel,
                    to: output
                )
                appendInline(
                    quoted,
                    font: .preferredFont(forTextStyle: .body),
                    paragraphStyle: style,
                    color: .secondaryLabel,
                    to: output
                )
                appendNewline(style: style, to: output)
                index += 1
                continue
            }

            appendInline(
                line,
                font: .preferredFont(forTextStyle: .body),
                paragraphStyle: paragraphStyle(spacingAfter: 4),
                to: output
            )
            appendNewline(to: output)
            index += 1
        }

        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    private static func appendInline(
        _ source: String,
        font: UIFont,
        paragraphStyle: NSParagraphStyle,
        color: UIColor = .label,
        forceBold: Bool = false,
        to output: NSMutableAttributedString
    ) {
        let parsed: AttributedString
        do {
            parsed = try AttributedString(
                markdown: source,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            appendPlain(
                source,
                font: font,
                style: paragraphStyle,
                color: color,
                forceBold: forceBold,
                to: output
            )
            return
        }

        for run in parsed.runs {
            let content = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent
            var runFont = font
            var traits: UIFontDescriptor.SymbolicTraits = []
            if forceBold || intent?.contains(.stronglyEmphasized) == true {
                traits.insert(.traitBold)
            }
            if intent?.contains(.emphasized) == true {
                traits.insert(.traitItalic)
            }
            if !traits.isEmpty,
               let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            if intent?.contains(.code) == true {
                runFont = .monospacedSystemFont(
                    ofSize: font.pointSize * 0.92,
                    weight: forceBold ? .semibold : .regular
                )
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: run.link == nil ? color : UIColor.tintColor,
                .paragraphStyle: paragraphStyle
            ]
            if intent?.contains(.code) == true {
                attributes[.backgroundColor] = UIColor.secondarySystemFill
            }
            if intent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: content, attributes: attributes))
        }
    }

    private static func appendTable(
        _ rows: [[String]],
        width: CGFloat,
        to output: NSMutableAttributedString
    ) {
        let columnCount = max(rows.map(\.count).max() ?? 2, 2)
        let usableWidth = max(width - 4, 160)
        let style = paragraphStyle(spacingAfter: 3)
        style.tabStops = (1..<columnCount).map { column in
            NSTextTab(
                textAlignment: .left,
                location: usableWidth * CGFloat(column) / CGFloat(columnCount)
            )
        }
        style.defaultTabInterval = usableWidth / CGFloat(columnCount)

        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columnCount {
                if column > 0 { appendPlain("\t", style: style, to: output) }
                appendInline(
                    column < row.count ? row[column] : "",
                    font: .preferredFont(forTextStyle: .subheadline),
                    paragraphStyle: style,
                    forceBold: rowIndex == 0,
                    to: output
                )
            }
            appendNewline(style: style, to: output)
            if rowIndex == 0 {
                let separator = String(repeating: "─", count: 26)
                appendPlain(
                    separator,
                    font: .preferredFont(forTextStyle: .caption2),
                    style: style,
                    color: .separator,
                    to: output
                )
                appendNewline(style: style, to: output)
            }
        }
    }

    private static func appendCode(
        _ code: String,
        to output: NSMutableAttributedString
    ) {
        let style = paragraphStyle(spacingBefore: 5, spacingAfter: 7)
        style.firstLineHeadIndent = 9
        style.headIndent = 9
        style.tailIndent = -9
        output.append(NSAttributedString(
            string: code,
            attributes: [
                .font: UIFont.monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize * 0.9,
                    weight: .regular
                ),
                .foregroundColor: UIColor.label,
                .backgroundColor: UIColor.secondarySystemFill,
                .paragraphStyle: style
            ]
        ))
        appendNewline(style: style, to: output)
    }

    private static func appendPlain(
        _ text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        style: NSParagraphStyle,
        color: UIColor = .label,
        forceBold: Bool = false,
        to output: NSMutableAttributedString
    ) {
        let renderedFont: UIFont
        if forceBold,
           let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            renderedFont = UIFont(descriptor: descriptor, size: font.pointSize)
        } else {
            renderedFont = font
        }
        output.append(NSAttributedString(
            string: text,
            attributes: [
                .font: renderedFont,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        ))
    }

    private static func appendNewline(
        style: NSParagraphStyle = paragraphStyle(),
        to output: NSMutableAttributedString
    ) {
        appendPlain("\n", style: style, to: output)
    }

    private static func appendBlankLine(to output: NSMutableAttributedString) {
        guard output.length > 0, !output.string.hasSuffix("\n\n") else { return }
        appendNewline(to: output)
    }

    private static func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func headingFont(level: Int) -> UIFont {
        let textStyle: UIFont.TextStyle
        switch level {
        case 1: textStyle = .title2
        case 2: textStyle = .title3
        case 3: textStyle = .headline
        default: textStyle = .subheadline
        }
        return UIFont.preferredFont(forTextStyle: textStyle)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes),
              line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func codeFence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func listItem(
        in line: String
    ) -> (depth: Int, marker: String, text: String)? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
        let content = line.dropFirst(indentation)
        let depth = indentation / 2
        for marker in ["- ", "* ", "+ "] where content.hasPrefix(marker) {
            return (depth, "•", String(content.dropFirst(marker.count)))
        }

        let digits = content.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let remainder = content.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else {
            return nil
        }
        return (
            depth,
            "\(digits).",
            String(remainder.dropFirst(2))
        )
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(in: line), cells.count > 1 else {
            return false
        }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(in line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count > 1 ? cells : nil
    }
}

/// UIKit owns the selection gestures and edit menu here. SwiftUI's
/// `textSelection` is not reliable inside the conversation's nested glass and
/// scrolling hierarchy on a physical device.
private struct SelectableMessageText: UIViewRepresentable {
    let text: String
    let rendersMarkdown: Bool
    let usesStableWidth: Bool

    init(
        text: String,
        rendersMarkdown: Bool = false,
        usesStableWidth: Bool = false
    ) {
        self.text = text
        self.rendersMarkdown = rendersMarkdown
        self.usesStableWidth = usesStableWidth
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(
            textView,
            text: text,
            rendersMarkdown: rendersMarkdown,
            width: textView.bounds.width
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth > 0 else {
            return nil
        }

        context.coordinator.update(
            textView,
            text: text,
            rendersMarkdown: rendersMarkdown,
            width: proposedWidth
        )

        return context.coordinator.fittedSize(
            for: textView,
            proposedWidth: proposedWidth,
            rendersMarkdown: rendersMarkdown,
            usesStableWidth: usesStableWidth
        )
    }

    static func dismantleUIView(
        _ textView: UITextView,
        coordinator: Coordinator
    ) {
        ConversationTextSelectionManager.shared.deactivate(textView)
        textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var renderedText: String?
        private var renderedAsMarkdown = false
        private var renderedWidth: CGFloat = 0
        private var cachedMeasurement: (width: CGFloat, size: CGSize)?

        func update(
            _ textView: UITextView,
            text: String,
            rendersMarkdown: Bool,
            width: CGFloat
        ) {
            let normalizedWidth = width > 0 ? width : 320
            let widthChanged = abs(renderedWidth - normalizedWidth) > 0.5
            guard renderedText != text
                    || renderedAsMarkdown != rendersMarkdown
                    || (rendersMarkdown && widthChanged) else { return }

            renderedText = text
            renderedAsMarkdown = rendersMarkdown
            renderedWidth = normalizedWidth
            cachedMeasurement = nil
            if rendersMarkdown {
                textView.attributedText = MarkdownMessageRenderer.render(
                    text,
                    width: normalizedWidth
                )
            } else {
                textView.attributedText = NSAttributedString(
                    string: text,
                    attributes: MarkdownMessageRenderer.bodyAttributes
                )
            }
        }

        func fittedSize(
            for textView: UITextView,
            proposedWidth: CGFloat,
            rendersMarkdown: Bool,
            usesStableWidth: Bool
        ) -> CGSize {
            if let cachedMeasurement,
               abs(cachedMeasurement.width - proposedWidth) <= 0.5 {
                return cachedMeasurement.size
            }

            let textBounds = textView.attributedText.boundingRect(
                with: CGSize(
                    width: proposedWidth,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let fittedWidth = usesStableWidth
                ? proposedWidth
                : min(proposedWidth, max(ceil(textBounds.width), 1))

            // Markdown layout (tables, tab stops) depends on the render width, so
            // re-render at the final display width *now*. Otherwise `updateUIView`
            // renders a second time at the narrower `bounds.width`, re-wraps the
            // content, and changes the row height after layout — which makes the
            // scroll indicator jump when a long bubble settles at the bottom.
            if rendersMarkdown,
               let renderedText,
               abs(renderedWidth - fittedWidth) > 0.5 {
                update(
                    textView,
                    text: renderedText,
                    rendersMarkdown: true,
                    width: fittedWidth
                )
            }

            let fittedSize = textView.sizeThatFits(CGSize(
                width: fittedWidth,
                height: CGFloat.greatestFiniteMagnitude
            ))
            let result = CGSize(
                width: fittedWidth,
                height: ceil(fittedSize.height)
            )
            cachedMeasurement = (proposedWidth, result)
            return result
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                ConversationTextSelectionManager.shared.activate(textView)
            } else {
                ConversationTextSelectionManager.shared.deactivate(textView)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            ConversationTextSelectionManager.shared.deactivate(textView)
        }
    }
}

/// Read by the parent page gesture without exposing the selection manager or
/// coupling the conversation's message hierarchy to ContentView bindings.
@MainActor
var isConversationTextSelectionActive: Bool {
    ConversationTextSelectionManager.shared.hasActiveSelection
}

@MainActor
private final class ConversationTextSelectionManager: NSObject,
    UIGestureRecognizerDelegate {
    static let shared = ConversationTextSelectionManager()

    private weak var selectedTextView: UITextView?
    private weak var installedWindow: UIWindow?

    var hasActiveSelection: Bool {
        (selectedTextView?.selectedRange.length ?? 0) > 0
    }

    private lazy var outsideTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleWindowTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    func activate(_ textView: UITextView) {
        if let previous = selectedTextView, previous !== textView {
            clearSelection(in: previous)
        }
        selectedTextView = textView
        installRecognizerIfNeeded(on: textView.window)
    }

    func deactivate(_ textView: UITextView) {
        guard selectedTextView === textView else { return }
        selectedTextView = nil
    }

    func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        hasActiveSelection
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc
    private func handleWindowTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let textView = selectedTextView,
              textView.selectedRange.length > 0 else { return }

        let location = recognizer.location(in: textView)
        guard !selectionContains(location, in: textView) else { return }
        let selectedRange = textView.selectedRange

        // Let the tapped control or edit-menu command finish first. If that
        // interaction creates a new selection, the identity/range checks keep
        // the new selection intact.
        Task { @MainActor [weak self, weak textView] in
            await Task.yield()
            guard let self,
                  let textView,
                  self.selectedTextView === textView,
                  textView.selectedRange == selectedRange else { return }
            self.clearSelection(in: textView)
        }
    }

    private func installRecognizerIfNeeded(on window: UIWindow?) {
        guard let window, installedWindow !== window else { return }
        installedWindow?.removeGestureRecognizer(outsideTapRecognizer)
        window.addGestureRecognizer(outsideTapRecognizer)
        installedWindow = window
    }

    private func selectionContains(
        _ point: CGPoint,
        in textView: UITextView
    ) -> Bool {
        guard let range = textView.selectedTextRange, !range.isEmpty else {
            return false
        }
        return textView.selectionRects(for: range).contains { selectionRect in
            selectionRect.rect
                .insetBy(dx: -6, dy: -6)
                .contains(point)
        }
    }

    private func clearSelection(in textView: UITextView) {
        if selectedTextView === textView {
            selectedTextView = nil
        }
        let location = textView.selectedRange.location
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.resignFirstResponder()
    }
}

private struct ChatBubbleImageGrid: View {
    let attachments: [ChatImageAttachment]
    let activePreviewSourceID: String?
    let onPreview: ConversationImagePreviewAction?

    private var images: [(attachment: ChatImageAttachment, image: UIImage)] {
        attachments.compactMap { attachment in
            guard let image = UIImage(data: attachment.data) else { return nil }
            return (attachment, image)
        }
    }

    var body: some View {
        Group {
            if images.count > 1 {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: ConversationAttachmentLayout.itemSpacing) {
                        imageButtons
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: ConversationAttachmentLayout.itemSide)
            } else if let item = images.first {
                imageButton(item)
            }
        }
        .frame(height: ConversationAttachmentLayout.itemSide)
    }

    @ViewBuilder
    private var imageButtons: some View {
        ForEach(images, id: \.attachment.id) { item in
            imageButton(item)
        }
    }

    private func imageButton(
        _ item: (attachment: ChatImageAttachment, image: UIImage)
    ) -> some View {
        let sourceID = "bubble:\(item.attachment.id)"

        return GeometryReader { proxy in
            Button {
                onPreview?(
                    item.image,
                    sourceID,
                    proxy.frame(in: .global)
                )
            } label: {
                Group {
                    if activePreviewSourceID == sourceID {
                        Color.clear
                    } else {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(
                    width: ConversationAttachmentLayout.itemSide,
                    height: ConversationAttachmentLayout.itemSide
                )
                .clipShape(RoundedRectangle(
                    cornerRadius: ConversationAttachmentLayout.cornerRadius,
                    style: .continuous
                ))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(onPreview != nil)
            .accessibilityLabel("预览图片")
        }
        .frame(
            width: ConversationAttachmentLayout.itemSide,
            height: ConversationAttachmentLayout.itemSide
        )
    }
}

struct MessageFlightPayload: View {
    let text: String
    let imageAttachments: [ChatImageAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !imageAttachments.isEmpty {
                MessageFlightImageGrid(attachments: imageAttachments)
            }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(text)
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MessageFlightImageGrid: View {
    let attachments: [ChatImageAttachment]

    var body: some View {
        let images = attachments.compactMap { UIImage(data: $0.data) }
        Group {
            if images.count > 1 {
                HStack(spacing: ConversationAttachmentLayout.itemSpacing) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        imageView(image)
                    }
                }
            } else if let image = images.first {
                imageView(image)
            }
        }
        .frame(height: ConversationAttachmentLayout.itemSide)
    }

    private func imageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
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
                    .overlay { bubbleOutline(for: shape) }
            } else {
                paddedContent
                    .glassEffect(.regular, in: shape)
                    .overlay { bubbleOutline(for: shape) }
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

    private func bubbleOutline(for shape: ChatBubbleShape) -> some View {
        shape
            .stroke(
                Color(uiColor: .separator).opacity(
                    role == .user ? 0.26 : 0.36
                ),
                lineWidth: 0.5
            )
            .allowsHitTesting(false)
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

@MainActor
struct TextConversationImageInteractionPreview: View {
    private let database: PlantDatabase
    private let memoryStore: PlantMemoryStore
    private let toolExecutor: PlantDataToolExecutor
    private let composerAttachment: ConversationImageAttachment
    private let historyAttachment: ConversationImageAttachment

    @State private var conversation: AIConversation?
    @State private var messages: [ChatMessage] = []
    @State private var preparationError: String?
    @State private var activeFlight: ActiveMessageFlight?
    @State private var startedFlightID: UUID?
    @State private var completedFlightID: UUID?
    @State private var destinations: [UUID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        let previewID = UUID().uuidString
        let databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("plant-talk-preview-\(previewID).sqlite")
            .path
        let database = try! PlantDatabase(path: databasePath)
        let image = Self.makePlantPreviewImage()

        self.database = database
        memoryStore = PlantMemoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("plant-talk-preview-memory-\(previewID).json")
        )
        toolExecutor = PlantDataToolExecutor(
            database: database,
            deviceIDProvider: { nil },
            currentReadingProvider: { nil }
        )
        composerAttachment = ConversationImageAttachment(
            id: "preview-composer-\(previewID)",
            image: image
        )
        historyAttachment = ConversationImageAttachment(
            id: "preview-history-\(previewID)",
            image: image
        )
    }

    var body: some View {
        ZStack {
            if let conversation {
                TextConversationView(
                    database: database,
                    client: Self.fixedResponseClient,
                    memoryStore: memoryStore,
                    toolExecutor: toolExecutor,
                    plantBinding: .unbound(source: .noKnownPlant),
                    initialMessage: "",
                    initialMessageID: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000901"
                    )!,
                    initialMessageDate: Date(timeIntervalSince1970: 1_788_800_000),
                    resumedConversation: conversation,
                    resumedMessages: messages,
                    isInitialTransitionComplete: true,
                    completedMessageFlightID: completedFlightID,
                    startedMessageFlightID: startedFlightID,
                    initialPendingImageAttachments: [composerAttachment],
                    configurationProvider: { Self.previewConfiguration },
                    onMessageFlightRequested: beginFlight,
                    onMessageFlightCancelled: cancelFlight,
                    onHome: {}
                )
                .id(conversation.id)
            } else if let preparationError {
                ContentUnavailableView(
                    "Preview 准备失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(preparationError)
                )
            } else {
                ProgressView("正在准备离线对话…")
            }

            if let activeFlight,
               activeFlight.hasStarted
                || activeFlight.request.showsOverlayWhilePreparing {
                MessageFlightOverlay(flight: activeFlight)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        .coordinateSpace(name: messageFlightCoordinateSpace)
        .onPreferenceChange(MessageFlightDestinationPreferenceKey.self) { newValue in
            destinations = newValue
            startFlightIfPossible()
        }
        .task { await prepareConversationIfNeeded() }
    }

    private func prepareConversationIfNeeded() async {
        guard conversation == nil, preparationError == nil else { return }
        do {
            let conversation = try await database.createConversation(
                title: "图片交互 Preview"
            )
            let storedImage = try historyAttachment.encodedChatAttachment()
            let baseDate = Date(timeIntervalSince1970: 1_788_800_000)
            let seedMessages = [
                ChatMessage(
                    id: UUID(),
                    conversationID: conversation.id,
                    role: .user,
                    content: "请看看这片叶子的状态。",
                    createdAt: baseDate,
                    imageAttachments: [storedImage]
                ),
                ChatMessage(
                    id: UUID(),
                    conversationID: conversation.id,
                    role: .assistant,
                    content: "这是一段离线 Preview 的固定回答。你可以长按并任意选择其中的文字，然后复制；也可以点击上方图片检查浮层预览。",
                    createdAt: baseDate.addingTimeInterval(30)
                )
            ]
            for message in seedMessages {
                try await database.saveChatMessage(message)
            }
            messages = try await database.chatMessages(conversationID: conversation.id)
            self.conversation = conversation
        } catch {
            preparationError = error.localizedDescription
        }
    }

    private func beginFlight(_ request: MessageFlightRequest) {
        guard !request.sourceFrame.isEmpty else { return }
        startedFlightID = nil
        completedFlightID = nil
        activeFlight = ActiveMessageFlight(
            request: request,
            currentFrame: request.sourceFrame
        )
        startFlightIfPossible()
    }

    private func startFlightIfPossible() {
        guard var flight = activeFlight,
              !flight.hasStarted,
              let destination = destinations[flight.request.id],
              !destination.isEmpty else { return }
        let id = flight.request.id
        flight.hasStarted = true
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeFlight = flight
            startedFlightID = id
        }

        Task { @MainActor in
            await Task.yield()
            guard activeFlight?.request.id == id else { return }
            withAnimation(
                reduceMotion ? nil : .smooth(duration: 0.32),
                completionCriteria: .logicallyComplete
            ) {
                activeFlight?.currentFrame = destination
                activeFlight?.progress = 1
            } completion: {
                completeFlight(id)
            }
        }
    }

    private func completeFlight(_ id: UUID) {
        guard activeFlight?.request.id == id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            startedFlightID = id
            completedFlightID = id
            activeFlight = nil
        }
    }

    private func cancelFlight(_ id: UUID) {
        guard activeFlight?.request.id == id || completedFlightID == id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeFlight = nil
            startedFlightID = nil
            if completedFlightID == id {
                completedFlightID = nil
            }
        }
    }

    private static let previewConfiguration = AIConfiguration(
        baseURL: URL(string: "https://preview.invalid/v1")!,
        model: "offline-preview-model",
        systemPrompt: "",
        apiKey: "preview-only"
    )

    private static let fixedResponseClient = OpenAICompatibleClient { _, _, _ in
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                continuation.yield(.textDelta(
                    "这是写死的离线模型回答：图片已经随消息进入聊天气泡，"
                ))
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                continuation.yield(.textDelta(
                    "输入框也已在飞行动画开始时正常清空。长按这段文字可以任意选择并复制。"
                ))
                continuation.yield(.finished(reason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makePlantPreviewImage() -> UIImage {
        let size = CGSize(width: 900, height: 1_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.08, green: 0.24, blue: 0.16, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            let leafRect = CGRect(
                x: size.width * 0.18,
                y: size.height * 0.15,
                width: size.width * 0.64,
                height: size.height * 0.7
            )
            let leaf = UIBezierPath(
                roundedRect: leafRect,
                cornerRadius: min(leafRect.width, leafRect.height) * 0.48
            )
            UIColor(red: 0.31, green: 0.72, blue: 0.42, alpha: 1).setFill()
            leaf.fill()

            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.76))
            stem.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.28))
            UIColor.white.withAlphaComponent(0.72).setStroke()
            stem.lineWidth = size.width * 0.018
            stem.lineCapStyle = .round
            stem.stroke()
        }
    }
}

#Preview("Text Conversation · 底部输入栏") {
    TextConversationBottomBarPreview()
}

#Preview("Text Conversation · 图片交互（离线固定回复）") {
    TextConversationImageInteractionPreview()
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

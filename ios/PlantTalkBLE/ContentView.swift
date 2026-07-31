import AVFAudio
import Combine
import CoreHaptics
import os
import SwiftUI
import UIKit

let messageFlightCoordinateSpace = "plant-talk-message-flight"

let plantTalkPageTransitionSignposter = OSSignposter(
    subsystem: "com.example.PlantTalkBLE",
    category: .pointsOfInterest
)

/// Owns the two haptics of the realtime-voice flow:
///
/// - `playTapConfirmation()` — a crisp, very short double tick played the moment
///   the orb is tapped, acknowledging that the request was accepted.
/// - `playSuccess()` — the "Soft Swell": one ~0.45s continuous vibration whose
///   intensity follows a bell-shaped envelope (quick rise, brief peak, gentle
///   fall), played when the realtime model actually connects.
///
/// Both fall back to system feedback generators when Core Haptics is unavailable
/// (simulator or unsupported hardware). Engine start always goes through the
/// completion-handler form so a cold or auto-shut-down engine never blocks the
/// main actor — that would stall the orb's animation clock.
@MainActor
final class RealtimeConnectionHaptic {
    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine
        .capabilitiesForHardware()
        .supportsHaptics

    func prepare() {
        guard supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // A reset drops the running instance; rebuild lazily on next play.
            engine.resetHandler = { [weak self] in
                self?.engine?.start(completionHandler: nil)
            }
            engine.start(completionHandler: nil)
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    /// Two tightly spaced transients, the second brighter than the first. Short
    /// enough (~70ms) to feel like a single crisp click rather than a buzz, but
    /// the rising pair reads as confirmation instead of a plain tap.
    func playTapConfirmation() {
        play(
            makePattern: {
                try CHHapticPattern(
                    events: [
                        CHHapticEvent(
                            eventType: .hapticTransient,
                            parameters: [
                                CHHapticEventParameter(
                                    parameterID: .hapticIntensity,
                                    value: 0.75
                                ),
                                CHHapticEventParameter(
                                    parameterID: .hapticSharpness,
                                    value: 0.85
                                )
                            ],
                            relativeTime: 0
                        ),
                        CHHapticEvent(
                            eventType: .hapticTransient,
                            parameters: [
                                CHHapticEventParameter(
                                    parameterID: .hapticIntensity,
                                    value: 0.55
                                ),
                                CHHapticEventParameter(
                                    parameterID: .hapticSharpness,
                                    value: 1
                                )
                            ],
                            relativeTime: 0.07
                        )
                    ],
                    parameters: []
                )
            },
            fallback: {
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.impactOccurred(intensity: 0.9)
            }
        )
    }

    func playSuccess() {
        play(
            makePattern: {
                let swell = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                    ],
                    relativeTime: 0,
                    duration: 0.45
                )
                // Bell-shaped intensity: quick rise → peak → gentle fall.
                let bellCurve = CHHapticParameterCurve(
                    parameterID: .hapticIntensityControl,
                    controlPoints: [
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.15),
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0.14, value: 0.95),
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0.26, value: 0.85),
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0.45, value: 0.0)
                    ],
                    relativeTime: 0
                )
                // Sharpness lifts slightly so the tail reads brighter, not muffled.
                let sharpnessCurve = CHHapticParameterCurve(
                    parameterID: .hapticSharpnessControl,
                    controlPoints: [
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.2),
                        CHHapticParameterCurve.ControlPoint(relativeTime: 0.45, value: 0.5)
                    ],
                    relativeTime: 0
                )
                return try CHHapticPattern(
                    events: [swell],
                    parameterCurves: [bellCurve, sharpnessCurve]
                )
            },
            fallback: {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        )
    }

    private func play(
        makePattern: () throws -> CHHapticPattern,
        fallback: @escaping @MainActor () -> Void
    ) {
        guard supportsHaptics else {
            fallback()
            return
        }
        prepare()
        guard let engine, let pattern = try? makePattern() else {
            fallback()
            return
        }

        // Starting an already-running engine is a cheap no-op, so the callback
        // fires almost immediately once `prepare()` has run.
        engine.start { error in
            guard error == nil else {
                Task { @MainActor in fallback() }
                return
            }
            do {
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                Task { @MainActor in fallback() }
            }
        }
    }
}

struct MessageFlightRequest: Equatable {
    let id: UUID
    let text: String
    let imageAttachments: [ChatImageAttachment]
    let createdAt: Date
    let sourceFrame: CGRect

    init(
        id: UUID,
        text: String,
        imageAttachments: [ChatImageAttachment] = [],
        createdAt: Date,
        sourceFrame: CGRect
    ) {
        self.id = id
        self.text = text
        self.imageAttachments = imageAttachments
        self.createdAt = createdAt
        self.sourceFrame = sourceFrame
    }
}

struct ActiveMessageFlight: Equatable {
    let request: MessageFlightRequest
    var currentFrame: CGRect
    var layoutProgress: CGFloat = 0
    var hasStarted = false
}

struct MessageFlightDestinationPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MessageFlightSourcePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

extension View {
    func messageFlightDestination(id: UUID?) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MessageFlightDestinationPreferenceKey.self,
                    value: id.map {
                        [$0: proxy.frame(in: .named(messageFlightCoordinateSpace))]
                    } ?? [:]
                )
            }
        }
    }

    func messageFlightSource() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MessageFlightSourcePreferenceKey.self,
                    value: proxy.frame(in: .named(messageFlightCoordinateSpace))
                )
            }
        }
    }
}

@MainActor
struct ContentView: View {
    let bluetooth: PlantBluetoothManager
    let database: PlantDatabase
    let aiClient: OpenAICompatibleClient
    let memoryStore: PlantMemoryStore
    let plantBindingResolver: PlantConversationBindingResolver

    @State private var realtimeConversation: QwenRealtimeConversation
    @State private var isRealtimeTranscriptPresented = false
    @State private var isHistoryOverviewPresented = false
    @State private var isHistoryDetailPresented = false
    @State private var selectedHistoryTab: HistoryTab = .sensor
    @State private var interactivePageTransition: InteractivePageTransition?
    @State private var interactivePageDragState = InteractivePageDragState()
    @State private var isInteractivePageSettling = false
    @State private var isHomeDashboardInteractionSuppressed = false
    @State private var homeDashboardInteractionReleaseTask: Task<Void, Never>?
    @State private var homeDashboardSnapshotAnchor: UIView?
    @State private var activeHomeDashboardSnapshot: HomeDashboardTransitionSnapshot?
    @State private var textConversationSnapshotAnchor: UIView?
    @State private var cachedTextConversationSnapshot: TextConversationTransitionSnapshot?
    @State private var activeTextConversationSnapshot: TextConversationTransitionSnapshot?
    @State private var textConversationSnapshotRefreshTask: Task<Void, Never>?
    @State private var historyOverviewSnapshotAnchor: UIView?
    @State private var cachedHistoryOverviewSnapshot: HistoryOverviewTransitionSnapshot?
    @State private var activeHistoryOverviewSnapshot: HistoryOverviewTransitionSnapshot?
    @State private var historyOverviewSnapshotRefreshTask: Task<Void, Never>?
    @State private var isPlantDetailsExpanded = false
    @State private var activeTextChat: TextChatLaunch?
    @State private var isTextConversationPresented = false
    @State private var textConversationTransitionPhase: TextConversationTransitionPhase = .idle
    @State private var isSoftwareKeyboardVisible = false
    @State private var isInitialTextChatTransitionComplete = false
    @State private var activeMessageFlight: ActiveMessageFlight?
    @State private var startedMessageFlightID: UUID?
    @State private var completedMessageFlightID: UUID?
    @State private var messageFlightDestinations: [UUID: CGRect] = [:]
    @State private var messageFlightDestinationValidationTask: Task<Void, Never>?
    @State private var textChatStartError: String?
    @State private var isTextChatStartErrorPresented = false
    @State private var plantArtwork: PlantArtwork?
    @State private var connectionHaptic = RealtimeConnectionHaptic()
    @FocusState private var isHomeTextComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(
        bluetooth: PlantBluetoothManager,
        database: PlantDatabase,
        aiClient: OpenAICompatibleClient,
        memoryStore: PlantMemoryStore
    ) {
        self.bluetooth = bluetooth
        self.database = database
        self.aiClient = aiClient
        self.memoryStore = memoryStore
        let plantBindingResolver = PlantConversationBindingResolver(
            database: database,
            currentDeviceIDProvider: { bluetooth.currentOrLastKnownDeviceID }
        )
        self.plantBindingResolver = plantBindingResolver
        _plantArtwork = State(initialValue: PlantArtworkStorage.load())
        _realtimeConversation = State(
            initialValue: QwenRealtimeConversation(
                database: database,
                bluetooth: bluetooth,
                plantBindingResolver: plantBindingResolver,
                memoryStore: memoryStore
            )
        )
        plantTalkPageTransitionSignposter.emitEvent("TransitionTracingReady")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NavigationStack {
                    ZStack {
                        screenLayers

                        if let activeMessageFlight {
                            MessageFlightOverlay(flight: activeMessageFlight)
                                .allowsHitTesting(false)
                                .zIndex(100)
                        }
                    }
                    .ignoresSafeArea(
                        textConversationTransitionPhase != .idle ? .keyboard : [],
                        edges: .bottom
                    )
                    .coordinateSpace(name: messageFlightCoordinateSpace)
                    .onPreferenceChange(MessageFlightDestinationPreferenceKey.self) { destinations in
                        messageFlightDestinations = destinations
                        scheduleMessageFlightDestinationValidation()
                    }
                    .sheet(isPresented: $isRealtimeTranscriptPresented) {
                        RealtimeConversationSheet(
                            conversation: realtimeConversation,
                            containerSize: geometry.size
                        )
                    }
                    .onChange(of: realtimeConversation.state) { previous, state in
                        if case .error = state {
                            isRealtimeTranscriptPresented = true
                        }
                        // Connection success is conveyed by the Soft Swell haptic
                        // only, since the orb no longer changes color between states.
                        if state == .connected, previous != .connected {
                            connectionHaptic.playSuccess()
                        }
                    }
                    .simultaneousGesture(
                        horizontalPageGesture(pageWidth: geometry.size.width)
                    )
                }
                .scrollDisabled(interactivePageTransition != nil)
                // The outgoing history page is a sibling of this stack in the
                // outer ZStack, so the reveal can move the whole stack here —
                // navigation bar included, matching the window snapshot the
                // presenting side parallaxes. The conversation page cannot use
                // this attachment point because it lives *inside* the stack.
                .modifier(
                    InteractiveHomeRevealModifier(
                        page: .history,
                        dragState: interactivePageDragState,
                        transition: interactivePageTransition,
                        pageWidth: geometry.size.width
                    )
                )

                if let activeHomeDashboardSnapshot {
                    TransitionSnapshotView(
                        contentView: activeHomeDashboardSnapshot.contentView
                    )
                    .id(activeHomeDashboardSnapshot.id)
                    // Must stay flexible rather than pinned to `pageSize`. A
                    // fixed window-sized frame reports 852pt back to this ZStack,
                    // whose own region is only the safe-area rect; the ZStack then
                    // re-proposes the inflated height to its flexible page layers,
                    // pushing their bottom edge below the screen. `ignoresSafeArea`
                    // below already stretches this layer to the full window.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(
                        InteractiveHomeSnapshotModifier(
                            dragState: interactivePageDragState,
                            transition: interactivePageTransition,
                            pageWidth: geometry.size.width
                        )
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(30)
                }

                if let activeTextConversationSnapshot {
                    TransitionSnapshotView(
                        contentView: activeTextConversationSnapshot.contentView
                    )
                    .id(activeTextConversationSnapshot.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: transitionSnapshotCornerRadius(
                                for: geometry
                            ),
                            style: .continuous
                        )
                    )
                    .modifier(
                        InteractivePageOffsetModifier(
                            page: .textConversation,
                            dragState: interactivePageDragState,
                            transition: interactivePageTransition,
                            isPresented: isTextConversationPresented,
                            pageWidth: geometry.size.width
                        )
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(40)
                }

                if isHistoryOverviewRendered {
                    NavigationStack {
                        HistoryOverviewView(
                            database: database,
                            selectedTab: $selectedHistoryTab,
                            onContinueTextConversation: continueTextConversation,
                            onContinueRealtimeConversation: continueRealtimeConversation,
                            onDetailPresentationChanged: { isPresented in
                                isHistoryDetailPresented = isPresented
                                if isPresented {
                                    historyOverviewSnapshotRefreshTask?.cancel()
                                    historyOverviewSnapshotRefreshTask = nil
                                } else {
                                    scheduleHistoryOverviewSnapshotRefresh()
                                }
                            },
                            onApplyGeneratedImageToPlantCard: applyGeneratedImageToPlantCard,
                            onDeleteGeneratedImage: removeGeneratedImageFromPlantCardIfNeeded
                        )
                            .background(Color(uiColor: .systemBackground))
                            .background {
                                TransitionSnapshotAnchor { anchor in
                                    guard historyOverviewSnapshotAnchor !== anchor else { return }
                                    historyOverviewSnapshotAnchor = anchor
                                }
                            }
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(action: hideHistoryOverview) {
                                        Image(systemName: "xmark")
                                    }
                                    .accessibilityLabel("返回")
                                }
                            }
                    }
                    .scrollDisabled(interactivePageTransition != nil)
                    // The page must not take taps mid-transition: the snapshot
                    // stands in for it, and on the first entry (no cache yet)
                    // the live page slides in and would otherwise be tappable
                    // while it moves. Disabling hit testing here — inside the
                    // gesture attachment below — keeps the dismissal gesture
                    // itself alive, so an in-flight drag can still settle.
                    .allowsHitTesting(
                        activeHistoryOverviewSnapshot == nil
                            && !isHistoryPageTransitionActive
                    )
                    .opacity(activeHistoryOverviewSnapshot == nil ? 1 : 0)
                    .accessibilityHidden(activeHistoryOverviewSnapshot != nil)
                    // On the first interactive entry there is no cached history
                    // snapshot yet, so this live NavigationStack is the layer
                    // that follows the finger. Give it the same device-shaped
                    // clipping as the cached snapshot used on later entries.
                    //
                    // Unlike those snapshot layers, this one carries no
                    // `ignoresSafeArea`, so its region is the safe-area rect
                    // while the stack still paints the full window. The insets
                    // grow the clip path back out to the window edges; note
                    // `geometry.size + safeAreaInsets` always equals the window,
                    // keyboard included, so the path stays correct throughout.
                    .clipShape(
                        OutsetRoundedRectangle(
                            cornerRadius: transitionSnapshotCornerRadius(
                                for: geometry
                            ),
                            outsets: geometry.safeAreaInsets
                        )
                    )
                    .modifier(
                        InteractivePageOffsetModifier(
                            page: .history,
                            dragState: interactivePageDragState,
                            transition: activeHistoryOverviewSnapshot == nil
                                ? interactivePageTransition
                                : nil,
                            isPresented: isHistoryOverviewPresented,
                            pageWidth: geometry.size.width
                        )
                    )
                    .simultaneousGesture(
                        hideHistoryGesture(pageWidth: geometry.size.width)
                    )
                    .transition(historyOverviewTransition)
                    .zIndex(50)
                    .onChange(of: selectedHistoryTab) { _, _ in
                        scheduleHistoryOverviewSnapshotRefresh()
                    }
                }

                if let activeHistoryOverviewSnapshot {
                    TransitionSnapshotView(
                        contentView: activeHistoryOverviewSnapshot.contentView
                    )
                    .id(activeHistoryOverviewSnapshot.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: transitionSnapshotCornerRadius(
                                for: geometry
                            ),
                            style: .continuous
                        )
                    )
                    .modifier(
                        InteractivePageOffsetModifier(
                            page: .history,
                            dragState: interactivePageDragState,
                            transition: interactivePageTransition,
                            isPresented: isHistoryOverviewPresented,
                            pageWidth: geometry.size.width
                        )
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(60)
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in
            isSoftwareKeyboardVisible = true
            if isHistoryOverviewRendered {
                dismissHomeKeyboardForHistoryOverview()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidHideNotification
            )
        ) { _ in
            isSoftwareKeyboardVisible = false
            scheduleTextConversationSnapshotRefresh()
            scheduleHistoryOverviewSnapshotRefresh()
        }
        .alert("无法开始植物对话", isPresented: $isTextChatStartErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(textChatStartError ?? "无法绑定当前植物。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                forceResolveInFlightTransitions()
            }
        }
    }

    private var screenLayers: some View {
        GeometryReader { geometry in
            ZStack {
                HomeDashboard(
                    reading: bluetooth.reading,
                    database: database,
                    isDetailsExpanded: $isPlantDetailsExpanded,
                    plantArtwork: plantArtworkBinding,
                    isTextComposerFocused: $isHomeTextComposerFocused,
                    realtimeConversationState: realtimeConversation.state,
                    voiceVisualDriver: realtimeConversation.voiceVisualDriver,
                    isInteractionSuppressed: isHomeDashboardInteractionSuppressed,
                    isMotionPaused: isPageTransitionActive,
                    isOrbMotionPaused: isHomeOrbMotionPaused,
                    onTextSend: startTextConversation,
                    onPrimaryButtonTap: handleRealtimeButtonTap
                )
                .background {
                    TransitionSnapshotAnchor { anchor in
                        guard homeDashboardSnapshotAnchor !== anchor else { return }
                        homeDashboardSnapshotAnchor = anchor
                    }
                }
                .zIndex(1)
                .allowsHitTesting(
                    !isTextConversationPresented
                        && !isHomeDashboardInteractionSuppressed
                )
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    if !isTextConversationPresented {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: showHistoryOverview) {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .accessibilityLabel("查看历史记录")
                        }

                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button(action: toggleBluetoothConnection) {
                                Image(systemName: bluetoothSymbol)
                                    .foregroundStyle(bluetooth.state == .connected ? .green : .primary)
                            }
                            .disabled(bluetoothConnectionUnavailable)
                            .accessibilityLabel(bluetooth.state == .connected ? "断开蓝牙" : "连接蓝牙")
                            .accessibilityValue(bluetooth.state.title)

                            NavigationLink {
                                AppSettingsView(
                                    database: database,
                                    memoryStore: memoryStore
                                )
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("设置")
                        }
                    }
                }

                // Attached to the dashboard alone rather than to the enclosing
                // stack: the outgoing conversation page is a sibling in this
                // same ZStack and carries its own offset, so moving the stack
                // would displace it twice.
                .modifier(
                    InteractiveHomeRevealModifier(
                        page: .textConversation,
                        dragState: interactivePageDragState,
                        transition: interactivePageTransition,
                        pageWidth: geometry.size.width
                    )
                )

                if let activeTextChat,
                   let plantBinding = activeTextChat.plantBinding {
                    TextConversationView(
                        database: database,
                        client: aiClient,
                        memoryStore: memoryStore,
                        toolExecutor: PlantDataToolExecutor(
                            database: database,
                            bluetooth: bluetooth,
                            boundDeviceID: plantBinding.deviceID
                        ),
                        plantBinding: plantBinding,
                        initialMessage: activeTextChat.message,
                        initialMessageID: activeTextChat.id,
                        initialMessageDate: activeTextChat.createdAt,
                        resumedConversation: activeTextChat.conversation,
                        resumedMessages: activeTextChat.messages,
                        isPagePresented: isTextConversationPresented,
                        isPageTransitioning: textConversationTransitionPhase != .idle,
                        isInitialTransitionComplete: activeTextChat.isResumed
                            || isInitialTextChatTransitionComplete,
                        completedMessageFlightID: completedMessageFlightID,
                        startedMessageFlightID: startedMessageFlightID,
                        onMessageFlightRequested: { request in
                            beginMessageFlight(request)
                        },
                        onMessageFlightCancelled: cancelMessageFlight,
                        onHome: returnToHome
                    )
                    .id(activeTextChat.id)
                    .background {
                        TransitionSnapshotAnchor { anchor in
                            guard textConversationSnapshotAnchor !== anchor else { return }
                            textConversationSnapshotAnchor = anchor
                        }
                    }
                    .modifier(
                        InteractivePageOffsetModifier(
                            page: .textConversation,
                            dragState: interactivePageDragState,
                            transition: activeTextConversationSnapshot == nil
                                ? interactivePageTransition
                                : nil,
                            isPresented: isTextConversationPresented,
                            pageWidth: geometry.size.width
                        )
                    )
                    .opacity(activeTextConversationSnapshot == nil ? 1 : 0)
                    .allowsHitTesting(
                        isTextConversationPresented
                            && activeTextConversationSnapshot == nil
                    )
                    .accessibilityHidden(
                        !isTextConversationPresented
                            || activeTextConversationSnapshot != nil
                    )
                    .zIndex(2)
                }

            }
        }
    }

    private var historyOverviewTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .leading)
    }

    private func applyGeneratedImageToPlantCard(_ item: GeneratedPlantImage) {
        plantArtworkBinding.wrappedValue = PlantArtwork(
            image: item.image,
            scale: 1,
            normalizedOffset: .zero,
            sourceGeneratedImageID: item.id
        )
    }

    private func removeGeneratedImageFromPlantCardIfNeeded(_ imageID: String) {
        guard plantArtwork?.sourceGeneratedImageID == imageID else { return }
        plantArtworkBinding.wrappedValue = nil
    }

    private var plantArtworkBinding: Binding<PlantArtwork?> {
        Binding(
            get: { plantArtwork },
            set: { artwork in
                plantArtwork = artwork
                PlantArtworkStorage.save(artwork)
            }
        )
    }

    private var isHistoryOverviewRendered: Bool {
        isHistoryOverviewPresented
            || interactivePageTransition == .presentingHistory
            || interactivePageTransition == .dismissingHistory
    }

    /// True while a page is being dragged or is settling. The home dashboard's
    /// orb runs a 30fps `TimelineView`; pausing it for the duration of a page
    /// transition removes continuous recomposition of the revealed home behind
    /// the sliding layer, which is a large per-frame cost on iOS 26 glass.
    private var isPageTransitionActive: Bool {
        interactivePageTransition != nil || isInteractivePageSettling
    }

    private var isHomeOrbMotionPaused: Bool {
        isPageTransitionActive
            || isHistoryOverviewPresented
            || isTextConversationPresented
            || textConversationTransitionPhase != .idle
    }

    /// True while the history page is sliding in or out, including the settling
    /// animation after the finger lifts.
    private var isHistoryPageTransitionActive: Bool {
        switch interactivePageTransition {
        case .presentingHistory, .dismissingHistory:
            return true
        case .presentingTextConversation, .dismissingTextConversation, nil:
            return false
        }
    }

    private func horizontalPageGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                updateHorizontalPageDrag(value, pageWidth: pageWidth)
            }
            .onEnded { value in
                finishHorizontalPageDrag(value, pageWidth: pageWidth)
            }
    }

    private func hideHistoryGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isInteractivePageSettling else { return }

                if interactivePageTransition == .dismissingHistory {
                    interactivePageDragState.translation = min(0, value.translation.width)
                    return
                }

                guard interactivePageTransition == nil,
                      isHistoryOverviewPresented,
                      !isHistoryDetailPresented,
                      value.translation.width < 0,
                      isHorizontalSwipe(value.translation) else { return }

                // The history page is on screen here, so capture it live and let
                // the snapshot carry the slide-out.
                let historySnapshot = captureCurrentHistoryOverviewSnapshot()
                    ?? cachedSnapshotForHistoryOverview
                historyOverviewSnapshotRefreshTask?.cancel()
                historyOverviewSnapshotRefreshTask = nil
                setWithoutAnimation {
                    if let historySnapshot {
                        cachedHistoryOverviewSnapshot = historySnapshot
                    }
                    activeHistoryOverviewSnapshot = historySnapshot
                    interactivePageTransition = .dismissingHistory
                    interactivePageDragState.translation = value.translation.width
                }
            }
            .onEnded { value in
                guard interactivePageTransition == .dismissingHistory else { return }
                let shouldDismiss = shouldCompleteInteractiveTransition(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    direction: -1,
                    pageWidth: pageWidth
                )
                settleHistoryDismissal(shouldDismiss: shouldDismiss, pageWidth: pageWidth)
            }
    }

    private func updateHorizontalPageDrag(
        _ value: DragGesture.Value,
        pageWidth: CGFloat
    ) {
        guard !isInteractivePageSettling else { return }

        // A selected message is owned by UIKit's UITextView. Its selection
        // handles also move horizontally, so the page gesture must stay idle
        // until that native interaction ends. Once a page transition has
        // already begun, keep driving it so it can always settle cleanly.
        guard interactivePageTransition != nil
                || !isConversationTextSelectionActive else { return }

        // Multi-image bubbles own horizontal drags that begin over their photo
        // strip. Ignore only a new page transition so an already-started
        // transition can always finish instead of getting stuck midway.
        guard interactivePageTransition != nil
                || !isConversationImageSwipeExcluded(
                    at: value.startLocation
                ) else { return }

        switch interactivePageTransition {
        case .presentingHistory:
            interactivePageDragState.translation = max(0, value.translation.width)
            return
        case .presentingTextConversation:
            interactivePageDragState.translation = min(0, value.translation.width)
            return
        case .dismissingTextConversation:
            interactivePageDragState.translation = max(0, value.translation.width)
            return
        case .dismissingHistory:
            return
        case nil:
            break
        }

        guard !isHistoryOverviewPresented,
              textConversationTransitionPhase == .idle,
              isHorizontalSwipe(value.translation) else { return }

        if isTextConversationPresented, value.translation.width > 0 {
            activateTextConversationSnapshotForDismissal()
            interactivePageTransition = .dismissingTextConversation
            interactivePageDragState.translation = value.translation.width
        } else if !isTextConversationPresented, value.translation.width > 0 {
            guard let homeSnapshot = captureHomeDashboardSnapshot() else { return }
            // The history page is not mounted yet at this point, so its snapshot
            // comes from the cache captured while it was last on screen. When no
            // valid cache exists (first entry, or a size change), the live page
            // slides in instead.
            let historySnapshot = cachedSnapshotForHistoryOverview
            historyOverviewSnapshotRefreshTask?.cancel()
            historyOverviewSnapshotRefreshTask = nil
            dismissHomeKeyboardForHistoryOverview()
            suppressHomeDashboardInteraction()
            setWithoutAnimation {
                activeHomeDashboardSnapshot = homeSnapshot
                activeHistoryOverviewSnapshot = historySnapshot
                interactivePageTransition = .presentingHistory
                interactivePageDragState.translation = value.translation.width
            }
        } else if !isTextConversationPresented,
                  value.translation.width < 0,
                  activeTextChat != nil {
            guard let homeSnapshot = captureHomeDashboardSnapshot(),
                  activeMessageFlight == nil,
                  let textSnapshot = cachedSnapshotForActiveConversation else {
                return
            }
            isHomeTextComposerFocused = false
            suppressHomeDashboardInteraction()
            textConversationSnapshotRefreshTask?.cancel()
            textConversationSnapshotRefreshTask = nil
            setWithoutAnimation {
                activeHomeDashboardSnapshot = homeSnapshot
                activeTextConversationSnapshot = textSnapshot
                interactivePageTransition = .presentingTextConversation
                interactivePageDragState.translation = value.translation.width
            }
        }
    }

    private func finishHorizontalPageDrag(
        _ value: DragGesture.Value,
        pageWidth: CGFloat
    ) {
        guard let transition = interactivePageTransition else { return }

        switch transition {
        case .presentingHistory:
            let shouldPresent = shouldCompleteInteractiveTransition(
                translation: value.translation.width,
                predictedTranslation: value.predictedEndTranslation.width,
                direction: 1,
                pageWidth: pageWidth
            )
            settleHistoryPresentation(shouldPresent: shouldPresent, pageWidth: pageWidth)
        case .presentingTextConversation:
            let shouldPresent = shouldCompleteInteractiveTransition(
                translation: value.translation.width,
                predictedTranslation: value.predictedEndTranslation.width,
                direction: -1,
                pageWidth: pageWidth
            )
            settleTextConversationPresentation(
                shouldPresent: shouldPresent,
                pageWidth: pageWidth
            )
        case .dismissingTextConversation:
            let shouldDismiss = shouldCompleteInteractiveTransition(
                translation: value.translation.width,
                predictedTranslation: value.predictedEndTranslation.width,
                direction: 1,
                pageWidth: pageWidth
            )
            settleTextConversationDismissal(
                shouldDismiss: shouldDismiss,
                pageWidth: pageWidth
            )
        case .dismissingHistory:
            break
        }
    }

    private func shouldCompleteInteractiveTransition(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        direction: CGFloat,
        pageWidth: CGFloat
    ) -> Bool {
        let distance = translation * direction
        let projectedDistance = predictedTranslation * direction
        return distance > pageWidth * 0.33
            || (distance > 12 && projectedDistance > pageWidth * 0.5)
    }

    private func settleHistoryPresentation(
        shouldPresent: Bool,
        pageWidth: CGFloat
    ) {
        if shouldPresent {
            dismissHomeKeyboardForHistoryOverview()
            setWithoutAnimation {
                isHistoryOverviewPresented = true
            }
        }
        isInteractivePageSettling = true
        withAnimation(interactivePageSettleAnimation, completionCriteria: .logicallyComplete) {
            interactivePageDragState.translation = shouldPresent ? pageWidth : 0
        } completion: {
            guard interactivePageTransition == .presentingHistory else { return }
            resetInteractivePageTransition()
            if shouldPresent {
                scheduleHistoryOverviewSnapshotRefresh()
            }
        }
    }

    private func settleHistoryDismissal(
        shouldDismiss: Bool,
        pageWidth: CGFloat
    ) {
        isInteractivePageSettling = true
        withAnimation(interactivePageSettleAnimation, completionCriteria: .logicallyComplete) {
            interactivePageDragState.translation = shouldDismiss ? -pageWidth : 0
        } completion: {
            guard interactivePageTransition == .dismissingHistory else { return }
            setWithoutAnimation {
                if shouldDismiss {
                    isHistoryOverviewPresented = false
                    isHistoryDetailPresented = false
                }
                resetInteractivePageTransition()
            }
            if !shouldDismiss {
                scheduleHistoryOverviewSnapshotRefresh()
            }
        }
    }

    private func settleTextConversationPresentation(
        shouldPresent: Bool,
        pageWidth: CGFloat
    ) {
        if shouldPresent {
            if isSoftwareKeyboardVisible {
                dismissSoftwareKeyboard()
            }
            setTextConversationTransitionPhase(.presenting)
        }
        isInteractivePageSettling = true
        withAnimation(interactivePageSettleAnimation, completionCriteria: .logicallyComplete) {
            interactivePageDragState.translation = shouldPresent ? -pageWidth : 0
        } completion: {
            guard interactivePageTransition == .presentingTextConversation else { return }
            setWithoutAnimation {
                if shouldPresent {
                    isTextConversationPresented = true
                    cachedTextConversationSnapshot = nil
                }
                resetInteractivePageTransition()
                if shouldPresent {
                    textConversationTransitionPhase = .idle
                }
            }
            if shouldPresent {
                scheduleTextConversationSnapshotRefresh()
            }
        }
    }

    private func settleTextConversationDismissal(
        shouldDismiss: Bool,
        pageWidth: CGFloat
    ) {
        if shouldDismiss {
            messageFlightDestinationValidationTask?.cancel()
            messageFlightDestinationValidationTask = nil
            clearMessageFlightForPageExit()
            if isSoftwareKeyboardVisible {
                dismissSoftwareKeyboard()
            }
            setTextConversationTransitionPhase(.dismissing)
        }
        isInteractivePageSettling = true
        withAnimation(interactivePageSettleAnimation, completionCriteria: .logicallyComplete) {
            interactivePageDragState.translation = shouldDismiss ? pageWidth : 0
        } completion: {
            guard interactivePageTransition == .dismissingTextConversation else { return }
            setWithoutAnimation {
                if shouldDismiss {
                    isTextConversationPresented = false
                } else {
                    cachedTextConversationSnapshot = nil
                }
                resetInteractivePageTransition()
                if shouldDismiss {
                    textConversationTransitionPhase = .idle
                }
            }
        }
    }

    private func resetInteractivePageTransition() {
        interactivePageTransition = nil
        interactivePageDragState.translation = 0
        isInteractivePageSettling = false
        activeHomeDashboardSnapshot = nil
        activeTextConversationSnapshot = nil
        activeHistoryOverviewSnapshot = nil
        releaseHomeDashboardInteractionAfterGesture()
    }

    /// Interactive transitions resolve their final state inside `withAnimation`
    /// completion closures. When the scene leaves `.active` mid-transition those
    /// closures can be dropped, leaving `isInteractivePageSettling` /
    /// `interactivePageTransition` stuck — which then blocks every page gesture
    /// and disables the scroll views, so the app looks frozen after relaunch.
    /// Snap all in-flight transition state back to a consistent resting state.
    private func forceResolveInFlightTransitions() {
        homeDashboardInteractionReleaseTask?.cancel()
        homeDashboardInteractionReleaseTask = nil
        textConversationSnapshotRefreshTask?.cancel()
        textConversationSnapshotRefreshTask = nil
        historyOverviewSnapshotRefreshTask?.cancel()
        historyOverviewSnapshotRefreshTask = nil
        messageFlightDestinationValidationTask?.cancel()
        messageFlightDestinationValidationTask = nil

        let stuckFlightID = activeMessageFlight?.request.id

        setWithoutAnimation {
            interactivePageTransition = nil
            interactivePageDragState.translation = 0
            isInteractivePageSettling = false
            activeHomeDashboardSnapshot = nil
            activeTextConversationSnapshot = nil
            activeHistoryOverviewSnapshot = nil
            cachedHistoryOverviewSnapshot = nil
            isHomeDashboardInteractionSuppressed = false
            textConversationTransitionPhase = .idle

            // A flight interrupted before reaching its destination would keep the
            // composer and the real chat bubble hidden forever. Resolve it the
            // same way `completeMessageFlight` would have.
            if let stuckFlightID {
                activeMessageFlight = nil
                startedMessageFlightID = stuckFlightID
                completedMessageFlightID = stuckFlightID
                if stuckFlightID == activeTextChat?.id {
                    isInitialTextChatTransitionComplete = true
                }
            }
        }
    }

    private func transitionSnapshotCornerRadius(
        for proxy: GeometryProxy
    ) -> CGFloat {
        if #available(iOS 26, *) {
            let insets = proxy.containerCornerInsets
            let radius = [
                insets.topLeading.height,
                insets.topTrailing.height,
                insets.bottomLeading.height,
                insets.bottomTrailing.height
            ].max() ?? 0
            if radius > 0 {
                return radius
            }
        }

        return 55
    }

    private func activateTextConversationSnapshotForDismissal() {
        textConversationSnapshotRefreshTask?.cancel()
        textConversationSnapshotRefreshTask = nil
        let snapshot: TextConversationTransitionSnapshot?
        if activeMessageFlight == nil {
            snapshot = captureCurrentTextConversationSnapshot()
                ?? cachedSnapshotForActiveConversation
        } else {
            snapshot = nil
        }
        setWithoutAnimation {
            if let snapshot {
                cachedTextConversationSnapshot = snapshot
            }
            activeTextConversationSnapshot = snapshot
        }
    }

    private func cacheCurrentTextConversationSnapshot() {
        guard let snapshot = captureCurrentTextConversationSnapshot() else { return }
        setWithoutAnimation {
            cachedTextConversationSnapshot = snapshot
        }
    }

    private func scheduleTextConversationSnapshotRefresh() {
        textConversationSnapshotRefreshTask?.cancel()
        textConversationSnapshotRefreshTask = nil
        guard isTextConversationPresented,
              interactivePageTransition == nil,
              activeMessageFlight == nil,
              !isSoftwareKeyboardVisible else { return }

        textConversationSnapshotRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isTextConversationPresented,
                  interactivePageTransition == nil,
                  activeMessageFlight == nil,
                  !isSoftwareKeyboardVisible else { return }
            cacheCurrentTextConversationSnapshot()
            textConversationSnapshotRefreshTask = nil
        }
    }

    private func cacheCurrentHistoryOverviewSnapshot() {
        guard let snapshot = captureCurrentHistoryOverviewSnapshot() else { return }
        setWithoutAnimation {
            cachedHistoryOverviewSnapshot = snapshot
        }
    }

    /// The presenting gesture fires before the history page is mounted, so its
    /// snapshot has to be taken in advance — while the page sits idle on screen.
    /// Refreshing on tab changes and detail dismissals keeps that cache current.
    private func scheduleHistoryOverviewSnapshotRefresh() {
        historyOverviewSnapshotRefreshTask?.cancel()
        historyOverviewSnapshotRefreshTask = nil
        guard isHistoryOverviewPresented,
              !isHistoryDetailPresented,
              interactivePageTransition == nil,
              !isSoftwareKeyboardVisible else { return }

        historyOverviewSnapshotRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isHistoryOverviewPresented,
                  !isHistoryDetailPresented,
                  interactivePageTransition == nil,
                  !isSoftwareKeyboardVisible else { return }
            cacheCurrentHistoryOverviewSnapshot()
            historyOverviewSnapshotRefreshTask = nil
        }
    }

    private var cachedSnapshotForHistoryOverview: HistoryOverviewTransitionSnapshot? {
        guard let snapshot = cachedHistoryOverviewSnapshot,
              snapshot.tab == selectedHistoryTab,
              let anchor = historyOverviewSnapshotAnchor ?? homeDashboardSnapshotAnchor,
              let window = anchor.window,
              abs(snapshot.pageSize.width - window.bounds.width) < 1,
              abs(snapshot.pageSize.height - window.bounds.height) < 1 else {
            return nil
        }
        return snapshot
    }

    private func captureCurrentHistoryOverviewSnapshot()
        -> HistoryOverviewTransitionSnapshot? {
        guard isHistoryOverviewPresented,
              !isHistoryDetailPresented,
              !isSoftwareKeyboardVisible,
              let anchor = historyOverviewSnapshotAnchor,
              let window = anchor.window,
              !anchor.bounds.isEmpty else { return nil }

        let pageRect = anchor.convert(anchor.bounds, to: window)
        let windowRect = window.bounds
        let visiblePageRect = pageRect.intersection(windowRect)
        guard !visiblePageRect.isNull,
              visiblePageRect.width > 0,
              visiblePageRect.height > 0,
              abs(visiblePageRect.width - pageRect.width) < 1,
              abs(visiblePageRect.height - pageRect.height) < 1,
              let snapshotView = window.resizableSnapshotView(
                from: windowRect,
                afterScreenUpdates: false,
                withCapInsets: .zero
              ) else { return nil }

        snapshotView.isUserInteractionEnabled = false
        return HistoryOverviewTransitionSnapshot(
            tab: selectedHistoryTab,
            pageSize: windowRect.size,
            contentView: snapshotView
        )
    }

    private var cachedSnapshotForActiveConversation: TextConversationTransitionSnapshot? {
        guard let snapshot = cachedTextConversationSnapshot,
              snapshot.conversationID == activeTextChat?.id,
              let anchor = textConversationSnapshotAnchor,
              let window = anchor.window,
              abs(snapshot.pageSize.width - window.bounds.width) < 1,
              abs(snapshot.pageSize.height - window.bounds.height) < 1 else {
            return nil
        }
        return snapshot
    }

    private func captureHomeDashboardSnapshot()
        -> HomeDashboardTransitionSnapshot? {
        guard !isHistoryOverviewPresented,
              !isTextConversationPresented,
              let anchor = homeDashboardSnapshotAnchor,
              let window = anchor.window,
              !anchor.bounds.isEmpty else { return nil }

        let pageRect = anchor.convert(anchor.bounds, to: window)
        let visiblePageRect = pageRect.intersection(window.bounds)
        guard !visiblePageRect.isNull,
              visiblePageRect.width > 0,
              visiblePageRect.height > 0,
              let snapshotView = window.resizableSnapshotView(
                from: window.bounds,
                afterScreenUpdates: false,
                withCapInsets: .zero
              ) else { return nil }

        snapshotView.isUserInteractionEnabled = false
        return HomeDashboardTransitionSnapshot(
            pageSize: window.bounds.size,
            contentView: snapshotView
        )
    }

    private func captureCurrentTextConversationSnapshot()
        -> TextConversationTransitionSnapshot? {
        guard isTextConversationPresented,
              activeMessageFlight == nil,
              !isSoftwareKeyboardVisible,
              let conversationID = activeTextChat?.id,
              let anchor = textConversationSnapshotAnchor,
              let window = anchor.window,
              !anchor.bounds.isEmpty else { return nil }

        let pageRect = anchor.convert(anchor.bounds, to: window)
        let windowRect = window.bounds
        let visiblePageRect = pageRect.intersection(windowRect)
        guard !visiblePageRect.isNull,
              visiblePageRect.width > 0,
              visiblePageRect.height > 0,
              abs(visiblePageRect.width - pageRect.width) < 1,
              abs(visiblePageRect.height - pageRect.height) < 1,
              let snapshotView = window.resizableSnapshotView(
                from: windowRect,
                afterScreenUpdates: false,
                withCapInsets: .zero
              ) else { return nil }

        snapshotView.isUserInteractionEnabled = false
        return TextConversationTransitionSnapshot(
            conversationID: conversationID,
            pageSize: windowRect.size,
            contentView: snapshotView
        )
    }

    private func suppressHomeDashboardInteraction() {
        homeDashboardInteractionReleaseTask?.cancel()
        homeDashboardInteractionReleaseTask = nil
        setWithoutAnimation {
            isHomeDashboardInteractionSuppressed = true
        }
    }

    private func releaseHomeDashboardInteractionAfterGesture() {
        homeDashboardInteractionReleaseTask?.cancel()
        homeDashboardInteractionReleaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isHomeDashboardInteractionSuppressed = false
            }
            homeDashboardInteractionReleaseTask = nil
        }
    }

    private func setWithoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func isHorizontalSwipe(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.25
    }

    private func showHistoryOverview() {
        dismissHomeKeyboardForHistoryOverview()
        withAnimation(
            reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35),
            completionCriteria: .logicallyComplete
        ) {
            isHistoryOverviewPresented = true
        } completion: {
            scheduleHistoryOverviewSnapshotRefresh()
        }
    }

    private func dismissHomeKeyboardForHistoryOverview() {
        setWithoutAnimation {
            isHomeTextComposerFocused = false
        }
        dismissSoftwareKeyboard()
    }

    private func hideHistoryOverview() {
        historyOverviewSnapshotRefreshTask?.cancel()
        historyOverviewSnapshotRefreshTask = nil
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
            isHistoryOverviewPresented = false
        }
        isHistoryDetailPresented = false
    }

    private var bluetoothSymbol: String {
        switch bluetooth.state {
        case .connected:
            "antenna.radiowaves.left.and.right"
        case .scanning, .connecting:
            "dot.radiowaves.left.and.right"
        default:
            "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var bluetoothConnectionUnavailable: Bool {
        if case .bluetoothUnavailable = bluetooth.state { return true }
        return false
    }

    private func toggleBluetoothConnection() {
        switch bluetooth.state {
        case .connected, .scanning, .connecting:
            bluetooth.disconnect()
        default:
            bluetooth.connect()
        }
    }

    private func handleRealtimeButtonTap() {
        if realtimeConversation.state.isActive {
            isRealtimeTranscriptPresented = true
            return
        }

        // Acknowledge the tap immediately. This also warms up the haptic engine,
        // so the Soft Swell fires without a cold-start delay once the connection
        // lands a moment later.
        connectionHaptic.playTapConfirmation()
        Task {
            await realtimeConversation.start()
        }
    }

    private func startTextConversation(_ launch: TextChatLaunch) {
        isInitialTextChatTransitionComplete = false
        completedMessageFlightID = nil
        beginMessageFlight(
            MessageFlightRequest(
                id: launch.id,
                text: launch.message,
                createdAt: launch.createdAt,
                sourceFrame: launch.sourceFrame
            ),
            schedulesDestinationValidation: false
        )

        Task { @MainActor in
            do {
                let plantBinding = try await plantBindingResolver.bindCurrentPlant()
                guard !Task.isCancelled else { return }
                presentTextConversation(launch.bound(to: plantBinding))
            } catch {
                guard !Task.isCancelled else { return }
                cancelMessageFlight(id: launch.id)
                textChatStartError = error.localizedDescription
                isTextChatStartErrorPresented = true
            }
        }
    }

    private func presentTextConversation(_ launch: TextChatLaunch) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cachedTextConversationSnapshot = nil
            activeTextConversationSnapshot = nil
            activeTextChat = launch
            isTextConversationPresented = true
        }
        scheduleMessageFlightDestinationValidation()
    }

    private func returnToHome() {
        guard textConversationTransitionPhase == .idle else { return }
        cacheCurrentTextConversationSnapshot()
        messageFlightDestinationValidationTask?.cancel()
        messageFlightDestinationValidationTask = nil
        clearMessageFlightForPageExit()

        if isSoftwareKeyboardVisible {
            dismissSoftwareKeyboard()
        }
        beginReturnToHomeTransition()
    }

    private func beginReturnToHomeTransition() {
        guard textConversationTransitionPhase == .idle else { return }
        setTextConversationTransitionPhase(.dismissing)
        withAnimation(
            pageTransitionAnimation,
            completionCriteria: .removed
        ) {
            isTextConversationPresented = false
        } completion: {
            finishTextConversationTransition(.dismissing)
        }
    }

    private func clearMessageFlightForPageExit() {
        var cleanupTransaction = Transaction(animation: nil)
        cleanupTransaction.disablesAnimations = true
        withTransaction(cleanupTransaction) {
            activeMessageFlight = nil
            startedMessageFlightID = nil
            completedMessageFlightID = nil
        }
    }

    private func showTextConversation() {
        guard textConversationTransitionPhase == .idle else { return }
        isHomeTextComposerFocused = false
        if isSoftwareKeyboardVisible {
            dismissSoftwareKeyboard()
        }
        beginShowTextConversationTransition()
    }

    private func beginShowTextConversationTransition() {
        guard textConversationTransitionPhase == .idle else { return }
        setTextConversationTransitionPhase(.presenting)
        withAnimation(
            pageTransitionAnimation,
            completionCriteria: .removed
        ) {
            isTextConversationPresented = true
        } completion: {
            finishTextConversationTransition(.presenting)
        }
    }

    private func dismissSoftwareKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func setTextConversationTransitionPhase(
        _ phase: TextConversationTransitionPhase
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            textConversationTransitionPhase = phase
        }
    }

    private func finishTextConversationTransition(
        _ phase: TextConversationTransitionPhase
    ) {
        guard textConversationTransitionPhase == phase else { return }
        setTextConversationTransitionPhase(.idle)
        if phase == .presenting {
            scheduleTextConversationSnapshotRefresh()
        }
    }

    private var pageTransitionAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)
    }

    private var interactivePageSettleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .interactiveSpring(response: 0.32, dampingFraction: 0.9)
    }

    private func continueTextConversation(
        _ conversation: AIConversation,
        messages: [ChatMessage]
    ) {
        Task { @MainActor in
            do {
                let plantBinding = try await plantBindingResolver.bindCurrentPlant()
                guard !Task.isCancelled else { return }
                let launch = TextChatLaunch(
                    resuming: conversation,
                    messages: messages,
                    plantBinding: plantBinding
                )
                historyOverviewSnapshotRefreshTask?.cancel()
                historyOverviewSnapshotRefreshTask = nil
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    cachedTextConversationSnapshot = nil
                    activeTextConversationSnapshot = nil
                    activeHistoryOverviewSnapshot = nil
                    activeTextChat = launch
                    isInitialTextChatTransitionComplete = true
                }
                withAnimation(pageTransitionAnimation) {
                    isHistoryOverviewPresented = false
                    isTextConversationPresented = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                textChatStartError = error.localizedDescription
                isTextChatStartErrorPresented = true
            }
        }
    }

    private func continueRealtimeConversation(
        _ conversation: AIConversation,
        messages: [ChatMessage]
    ) {
        historyOverviewSnapshotRefreshTask?.cancel()
        historyOverviewSnapshotRefreshTask = nil
        withAnimation(pageTransitionAnimation) {
            isHistoryOverviewPresented = false
        }
        isRealtimeTranscriptPresented = true
        Task {
            if realtimeConversation.state.isActive {
                realtimeConversation.stop()
            }
            await realtimeConversation.start(
                resuming: conversation,
                messages: messages
            )
        }
    }

    private func beginMessageFlight(
        _ request: MessageFlightRequest,
        schedulesDestinationValidation: Bool = true
    ) {
        guard !request.sourceFrame.isEmpty else { return }
        messageFlightDestinationValidationTask?.cancel()
        startedMessageFlightID = nil
        completedMessageFlightID = nil
        activeMessageFlight = ActiveMessageFlight(
            request: request,
            currentFrame: request.sourceFrame
        )
        if schedulesDestinationValidation {
            scheduleMessageFlightDestinationValidation()
        }
    }

    private func scheduleMessageFlightDestinationValidation() {
        messageFlightDestinationValidationTask?.cancel()
        guard let flight = activeMessageFlight,
              !flight.hasStarted else { return }

        let id = flight.request.id
        messageFlightDestinationValidationTask = Task { @MainActor in
            var previousFrame: CGRect?
            var stableSampleCount = 0

            // Geometry preferences can be emitted before ScrollViewReader has
            // applied its bottom scroll. Sample across display cycles and only
            // accept a destination after the final layout has stopped moving.
            for _ in 0..<30 {
                guard !Task.isCancelled,
                      let active = activeMessageFlight,
                      active.request.id == id,
                      !active.hasStarted else { return }

                guard let frame = messageFlightDestinations[id],
                      !frame.isEmpty else {
                    previousFrame = nil
                    stableSampleCount = 0
                    do {
                        try await Task.sleep(for: .milliseconds(16))
                    } catch {
                        return
                    }
                    continue
                }

                if let previousFrame,
                   destinationFrame(previousFrame, matches: frame) {
                    stableSampleCount += 1
                } else {
                    previousFrame = frame
                    stableSampleCount = 1
                }

                if stableSampleCount >= 2 {
                    startMessageFlight(id: id, destination: frame)
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }

            // Do not leave the composer snapshot or response presentation
            // blocked forever if the destination view disappears unexpectedly.
            guard !Task.isCancelled,
                  activeMessageFlight?.request.id == id else { return }
            completeMessageFlight(id: id)
        }
    }

    private func startMessageFlight(id: UUID, destination: CGRect) {
        guard var flight = activeMessageFlight,
              flight.request.id == id,
              !flight.hasStarted,
              !destination.isEmpty else {
            return
        }

        messageFlightDestinationValidationTask = nil
        flight.hasStarted = true
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMessageFlight = flight
            startedMessageFlightID = id
        }

        Task { @MainActor in
            // Give SwiftUI one update to replace the live composer with the
            // source-frame overlay before its position starts changing.
            await Task.yield()
            guard activeMessageFlight?.request.id == id,
                  activeMessageFlight?.hasStarted == true else { return }
            withAnimation(
                reduceMotion ? nil : .smooth(duration: 0.32),
                completionCriteria: .removed
            ) {
                activeMessageFlight?.currentFrame = destination
                activeMessageFlight?.layoutProgress = 1
            } completion: {
                completeMessageFlight(id: id)
            }
        }
    }

    private func completeMessageFlight(id: UUID) {
        guard activeMessageFlight?.request.id == id else { return }
        messageFlightDestinationValidationTask?.cancel()
        messageFlightDestinationValidationTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            startedMessageFlightID = id
            completedMessageFlightID = id
            if activeTextChat?.id == id {
                isInitialTextChatTransitionComplete = true
            }
            activeMessageFlight = nil
        }
        scheduleTextConversationSnapshotRefresh()
    }

    private func cancelMessageFlight(id: UUID) {
        guard activeMessageFlight?.request.id == id
                || completedMessageFlightID == id else { return }
        messageFlightDestinationValidationTask?.cancel()
        messageFlightDestinationValidationTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMessageFlight = nil
            startedMessageFlightID = nil
            if completedMessageFlightID == id {
                completedMessageFlightID = nil
            }
        }
    }

    private func destinationFrame(
        _ lhs: CGRect,
        matches rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

private enum TextConversationTransitionPhase {
    case idle
    case presenting
    case dismissing
}

private enum InteractivePageTransition {
    case presentingHistory
    case dismissingHistory
    case presentingTextConversation
    case dismissingTextConversation
}

@Observable
private final class InteractivePageDragState {
    var translation: CGFloat = 0
}

private enum InteractivePageKind {
    case history
    case textConversation
}

/// Gives the outgoing home-page snapshot a quarter-speed parallax movement.
/// The dimming layer follows the same linear drag progress and tops out at 20%.
private struct InteractiveHomeSnapshotModifier: ViewModifier {
    @Bindable var dragState: InteractivePageDragState
    let transition: InteractivePageTransition?
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                Color.black
                    .opacity(dimmingOpacity)
                    .allowsHitTesting(false)
            }
            .offset(x: horizontalOffset)
    }

    private var horizontalOffset: CGFloat {
        switch transition {
        case .presentingHistory:
            clampedTranslation / 4
        case .presentingTextConversation:
            clampedTranslation / 4
        default:
            0
        }
    }

    private var dimmingOpacity: Double {
        guard pageWidth > 0 else { return 0 }
        return Double(min(1, abs(clampedTranslation) / pageWidth)) * 0.2
    }

    private var clampedTranslation: CGFloat {
        switch transition {
        case .presentingHistory:
            min(max(dragState.translation, 0), pageWidth)
        case .presentingTextConversation:
            min(max(dragState.translation, -pageWidth), 0)
        default:
            0
        }
    }
}

/// The dismissal counterpart of `InteractiveHomeSnapshotModifier`: runs that
/// parallax-and-dim ramp backwards, so swiping a page away mirrors its entry.
///
/// Unlike the presenting side this drives the *live* home instead of a
/// snapshot, because a dismissal has nothing to snapshot from. The outgoing
/// page owns the window when the gesture starts, so a fresh capture would
/// return that page rather than the home, and a snapshot cached during the
/// entry can be stale by the time the user swipes back — the history page can
/// replace the plant card artwork while it is up. Driving the real view is
/// affordable here because `isPageTransitionActive` already parks the orb's
/// 30fps timeline, so nothing behind the moving page is animating.
///
/// `page` selects which dismissal this instance responds to; the two are
/// attached at different depths in the hierarchy (see the call sites).
private struct InteractiveHomeRevealModifier: ViewModifier {
    let page: InteractivePageKind
    @Bindable var dragState: InteractivePageDragState
    let transition: InteractivePageTransition?
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                Color.black
                    .opacity(dimmingOpacity)
                    // The home is laid out in the safe-area rect while it paints
                    // to the window edges, so a plain overlay would leave an
                    // undimmed strip under the status bar and home indicator.
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .offset(x: horizontalOffset)
    }

    /// How much of the outgoing page's exit is still ahead, as a 1...0 fraction.
    /// Starts at 1 — where the presentation left the home displaced and dimmed —
    /// and reaches 0 as the page clears the screen and the home settles back.
    private var remainingProgress: CGFloat {
        guard pageWidth > 0 else { return 0 }
        switch (page, transition) {
        case (.history, .dismissingHistory):
            let translation = min(max(dragState.translation, -pageWidth), 0)
            return (pageWidth + translation) / pageWidth
        case (.textConversation, .dismissingTextConversation):
            let translation = min(max(dragState.translation, 0), pageWidth)
            return (pageWidth - translation) / pageWidth
        default:
            return 0
        }
    }

    /// Signs mirror the presenting parallax: history comes in from the leading
    /// edge and holds the home pushed right, the conversation comes in from the
    /// trailing edge and holds it pulled left. Quarter speed keeps the
    /// displacement small enough that the outgoing page still covers the strip
    /// the home vacates.
    private var horizontalOffset: CGFloat {
        switch page {
        case .history:
            return pageWidth / 4 * remainingProgress
        case .textConversation:
            return -pageWidth / 4 * remainingProgress
        }
    }

    private var dimmingOpacity: Double {
        Double(remainingProgress) * 0.2
    }
}

/// Keeps high-frequency drag invalidation at the transform boundary instead of
/// propagating it through ContentView and the conversation's message hierarchy.
/// A device-shaped rounded rectangle grown outward by `outsets`.
///
/// The live pages are laid out inside the safe-area rect, yet a
/// `NavigationStack` paints its bar material and background across the whole
/// window. Clipping such a layer with a plain `RoundedRectangle` would shear
/// off those out-of-region strips along the top and bottom. Passing the
/// window's safe-area insets in as outsets puts the clip path back on the
/// window edges, so only the sliding leading and trailing edges get rounded.
private struct OutsetRoundedRectangle: Shape {
    let cornerRadius: CGFloat
    let outsets: EdgeInsets

    func path(in rect: CGRect) -> Path {
        // Leading/trailing map to minX/maxX, matching the LTR layout this app
        // ships in. Both are 0 in portrait, where the shearing actually shows.
        let expanded = CGRect(
            x: rect.minX - outsets.leading,
            y: rect.minY - outsets.top,
            width: rect.width + outsets.leading + outsets.trailing,
            height: rect.height + outsets.top + outsets.bottom
        )
        return Path(
            roundedRect: expanded,
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }
}

private struct InteractivePageOffsetModifier: ViewModifier {
    let page: InteractivePageKind
    @Bindable var dragState: InteractivePageDragState
    let transition: InteractivePageTransition?
    let isPresented: Bool
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: horizontalOffset)
    }

    private var horizontalOffset: CGFloat {
        switch (page, transition) {
        case (.history, .presentingHistory):
            return -pageWidth + clamped(
                dragState.translation,
                lowerBound: 0,
                upperBound: pageWidth
            )
        case (.history, .dismissingHistory):
            return clamped(
                dragState.translation,
                lowerBound: -pageWidth,
                upperBound: 0
            )
        case (.textConversation, .presentingTextConversation):
            return pageWidth + clamped(
                dragState.translation,
                lowerBound: -pageWidth,
                upperBound: 0
            )
        case (.textConversation, .dismissingTextConversation):
            return clamped(
                dragState.translation,
                lowerBound: 0,
                upperBound: pageWidth
            )
        default:
            switch page {
            case .history:
                return isPresented ? 0 : -pageWidth
            case .textConversation:
                return isPresented ? 0 : pageWidth
            }
        }
    }

    private func clamped(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }
}

@MainActor
private final class HomeDashboardTransitionSnapshot: Identifiable {
    let id = UUID()
    let pageSize: CGSize
    let contentView: UIView

    init(pageSize: CGSize, contentView: UIView) {
        self.pageSize = pageSize
        self.contentView = contentView
    }
}

@MainActor
private final class HistoryOverviewTransitionSnapshot: Identifiable {
    let id = UUID()
    let tab: HistoryTab
    let pageSize: CGSize
    let contentView: UIView

    init(tab: HistoryTab, pageSize: CGSize, contentView: UIView) {
        self.tab = tab
        self.pageSize = pageSize
        self.contentView = contentView
    }
}

@MainActor
private final class TextConversationTransitionSnapshot: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let pageSize: CGSize
    let contentView: UIView

    init(conversationID: UUID, pageSize: CGSize, contentView: UIView) {
        self.conversationID = conversationID
        self.pageSize = pageSize
        self.contentView = contentView
    }
}

private struct TransitionSnapshotAnchor: UIViewRepresentable {
    let onResolve: @MainActor (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        resolve(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        resolve(uiView)
    }

    private func resolve(_ view: UIView) {
        Task { @MainActor in
            onResolve(view)
        }
    }
}

private struct TransitionSnapshotView: UIViewRepresentable {
    let contentView: UIView

    func makeUIView(context: Context) -> TransitionSnapshotHostView {
        let host = TransitionSnapshotHostView()
        host.install(contentView)
        return host
    }

    func updateUIView(
        _ uiView: TransitionSnapshotHostView,
        context: Context
    ) {
        uiView.install(contentView)
    }

    static func dismantleUIView(
        _ uiView: TransitionSnapshotHostView,
        coordinator: Void
    ) {
        uiView.removeSnapshot()
    }
}

@MainActor
private final class TransitionSnapshotHostView: UIView {
    private var snapshotView: UIView?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(_ view: UIView) {
        guard snapshotView !== view else { return }
        snapshotView?.removeFromSuperview()
        view.removeFromSuperview()
        snapshotView = view
        addSubview(view)
        setNeedsLayout()
    }

    func removeSnapshot() {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        snapshotView?.frame = bounds
    }
}

private struct TextChatLaunch: Identifiable, Equatable {
    let id: UUID
    let message: String
    let createdAt: Date
    let sourceFrame: CGRect
    let plantBinding: PlantConversationBinding?
    let conversation: AIConversation?
    let messages: [ChatMessage]

    var isResumed: Bool { conversation != nil }

    init(message: String, sourceFrame: CGRect) {
        id = UUID()
        self.message = message
        createdAt = Date()
        self.sourceFrame = sourceFrame
        plantBinding = nil
        conversation = nil
        messages = []
    }

    private init(
        id: UUID,
        message: String,
        createdAt: Date,
        sourceFrame: CGRect,
        plantBinding: PlantConversationBinding,
        conversation: AIConversation?,
        messages: [ChatMessage]
    ) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.sourceFrame = sourceFrame
        self.plantBinding = plantBinding
        self.conversation = conversation
        self.messages = messages
    }

    init(
        resuming conversation: AIConversation,
        messages: [ChatMessage],
        plantBinding: PlantConversationBinding
    ) {
        id = conversation.id
        message = ""
        createdAt = conversation.createdAt
        sourceFrame = .zero
        self.plantBinding = plantBinding
        self.conversation = conversation
        self.messages = messages
    }

    func bound(to plantBinding: PlantConversationBinding) -> TextChatLaunch {
        TextChatLaunch(
            id: id,
            message: message,
            createdAt: createdAt,
            sourceFrame: sourceFrame,
            plantBinding: plantBinding,
            conversation: conversation,
            messages: messages
        )
    }
}

private struct HomeDashboard: View {
    let reading: PlantReading?
    let database: PlantDatabase
    @Binding var isDetailsExpanded: Bool
    @Binding var plantArtwork: PlantArtwork?
    let isTextComposerFocused: FocusState<Bool>.Binding
    let realtimeConversationState: RealtimeConversationState
    let voiceVisualDriver: VoiceVisualDriver
    let isInteractionSuppressed: Bool
    let isMotionPaused: Bool
    let isOrbMotionPaused: Bool
    let onTextSend: (TextChatLaunch) -> Void
    let onPrimaryButtonTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stableLayoutHeight: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let liveHeight = proxy.size.height
            // 页面横向转场时，导航栏的顶部安全区会短暂出现/消失，使这里的可用
            // 高度跳动，从而让植物卡片和底部主按钮上下漂移。转场进行中改用最近
            // 一次稳定态记录的高度来分配布局，转场结束后再跟随真实高度。
            let layoutHeight = isMotionPaused
                ? (stableLayoutHeight ?? liveHeight)
                : liveHeight
            let horizontalInset = proxy.size.width * 0.05
            let contentWidth = proxy.size.width - horizontalInset * 2
            let artworkWidth = contentWidth * (isDetailsExpanded ? 0.38 : 0.66)
            let actionButtonWidth = contentWidth * 0.32

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isTextComposerFocused.wrappedValue = false
                    }

                VStack(spacing: 0) {
                    if isDetailsExpanded {
                        HomeTextComposer(
                            isInputFocused: isTextComposerFocused,
                            isInputDisabled: realtimeConversationState.isActive,
                            onSend: { launch in
                                guard !isInteractionSuppressed else { return }
                                onTextSend(launch)
                            }
                        )
                        .padding(.top)
                        .padding(.bottom, 12)
                        .transition(textComposerTransition)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxHeight: layoutHeight * 0.12)
                    }

                    PlantArtworkControl(
                        artwork: $plantArtwork,
                        isDetailsExpanded: isDetailsExpanded,
                        onTap: toggleDetails
                    )
                    .frame(width: artworkWidth)

                    if isDetailsExpanded {
                        SensorReadingGrid(
                            reading: reading,
                            database: database,
                            isInteractionSuppressed: isInteractionSuppressed
                        )
                            .padding(.top, 12)
                            .transition(sensorGridTransition)
                    }

                    Spacer(minLength: 0)

                    PrimaryInteractionButton(
                        realtimeConversationState: realtimeConversationState,
                        voiceVisualDriver: voiceVisualDriver,
                        isMotionPaused: isOrbMotionPaused,
                        onTap: {
                            guard !isInteractionSuppressed else { return }
                            onPrimaryButtonTap()
                        }
                    )
                    .frame(width: actionButtonWidth)
                    .padding(.bottom)
                }
                .padding(.horizontal, horizontalInset)
                .frame(maxWidth: .infinity, minHeight: layoutHeight, maxHeight: layoutHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: liveHeight) { _, newValue in
                recordStableLayoutHeight(newValue)
            }
            .onAppear {
                recordStableLayoutHeight(liveHeight)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: realtimeConversationState.isActive) { _, isActive in
            if isActive {
                isTextComposerFocused.wrappedValue = false
            }
        }
    }

    /// Only capture the container height while no page transition is running,
    /// so the frozen height used during a transition always reflects the last
    /// settled layout rather than a mid-animation safe-area jump.
    private func recordStableLayoutHeight(_ height: CGFloat) {
        guard !isMotionPaused, height > 0 else { return }
        if stableLayoutHeight != height {
            stableLayoutHeight = height
        }
    }

    private var layoutAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .smooth(duration: 0.42)
    }

    private var textComposerTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .top)
            .combined(with: .scale(scale: 0.94, anchor: .top))
            .combined(with: .opacity)
    }

    private var sensorGridTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .bottom)
            .combined(with: .scale(scale: 0.94, anchor: .top))
            .combined(with: .opacity)
    }

    private func toggleDetails() {
        guard !isInteractionSuppressed else { return }
        withAnimation(layoutAnimation) {
            isDetailsExpanded.toggle()
        }
    }
}

private struct HomeTextComposer: View {
    let isInputFocused: FocusState<Bool>.Binding
    let isInputDisabled: Bool
    let onSend: (TextChatLaunch) -> Void

    @State private var draft = ""
    @State private var textEntryFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 10) {
            textEntry
                .messageFlightSource()
                .onPreferenceChange(MessageFlightSourcePreferenceKey.self) {
                    textEntryFrame = $0
                }

            sendButton
        }
        .padding(.horizontal, 2)
        .disabled(isInputDisabled)
        .opacity(isInputDisabled ? 0.55 : 1)
        .accessibilityHint(
            isInputDisabled
                ? "结束实时语音对话后可使用文字输入"
                : "输入文字后发送"
        )
    }

    private var baseTextEntry: some View {
        TextField(
            isInputDisabled ? "实时语音对话中，文字输入已禁用" : "和植物说点什么…",
            text: $draft,
            axis: .vertical
        )
            .lineLimit(1...5)
            .focused(isInputFocused)
            .submitLabel(.send)
            .onSubmit {
                send()
            }
            .onChange(of: draft) { _, newValue in
                handleDraftChange(newValue)
            }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var textEntry: some View {
        textEntrySurface
    }

    private var textEntrySurface: some View {
        InitialMessageTransitionSurface {
            baseTextEntry
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if #available(iOS 26, *) {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(trimmedDraft.isEmpty)
            .accessibilityLabel("发送")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(trimmedDraft.isEmpty)
            .accessibilityLabel("发送")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ rawText: String? = nil) {
        let message = (rawText ?? draft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isInputDisabled,
              !message.isEmpty,
              !textEntryFrame.isEmpty else { return }

        let launch = TextChatLaunch(
            message: message,
            sourceFrame: textEntryFrame
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onSend(launch)
            draft = ""
            isInputFocused.wrappedValue = false
        }
        clearRecommittedDraftIfNeeded(afterSubmitting: message)
    }

    private func handleDraftChange(_ newValue: String) {
        guard newValue.last?.isNewline == true else { return }

        var submittedText = newValue
        while submittedText.last?.isNewline == true {
            submittedText.removeLast()
        }
        draft = submittedText
        send(submittedText)
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
}

struct MessageFlightOverlay: View {
    let flight: ActiveMessageFlight

    var body: some View {
        let frame = flight.currentFrame

        MessageFlightBubble(
            text: flight.request.text,
            imageAttachments: flight.request.imageAttachments,
            createdAt: flight.request.createdAt,
            layoutProgress: flight.layoutProgress
        )
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
    }
}

struct InitialMessageTransitionSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 24)
                )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.4))
                }
        }
    }
}

private struct SensorReadingGrid: View {
    let reading: PlantReading?
    let database: PlantDatabase
    let isInteractionSuppressed: Bool

    @State private var selectedMetric: SensorMetric?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(metrics) { metric in
                SensorMetricCard(metric: metric) {
                    guard !isInteractionSuppressed else { return }
                    selectedMetric = metric
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $selectedMetric) { selectedMetric in
            SensorChartSheet(metric: metric(for: selectedMetric.kind), database: database)
        }
    }

    private var metrics: [SensorMetric] {
        SensorMetricKind.allCases.map(metric(for:))
    }

    private func metric(for kind: SensorMetricKind) -> SensorMetric {
        switch kind {
        case .temperature:
            SensorMetric(
                kind: .temperature,
                title: "温度",
                value: reading?.temperature.map { String(format: "%.1f", $0) } ?? "--",
                unit: "°C",
                symbol: "thermometer.medium",
                tint: Color(uiColor: .systemOrange)
            )
        case .humidity:
            SensorMetric(
                kind: .humidity,
                title: "空气湿度",
                value: reading?.humidity.map { String(format: "%.1f", $0) } ?? "--",
                unit: "%",
                symbol: "humidity",
                tint: Color(uiColor: .systemBlue)
            )
        case .soil:
            SensorMetric(
                kind: .soil,
                title: "土壤湿度",
                value: reading.map { String($0.soilRaw) } ?? "--",
                unit: "ADC",
                symbol: "drop.degreesign",
                tint: Color(uiColor: .systemBrown)
            )
        case .light:
            SensorMetric(
                kind: .light,
                title: "光照",
                value: lightValue,
                unit: reading?.lightLux == nil ? "" : "lx",
                symbol: "sun.max.fill",
                tint: Color(uiColor: .systemYellow)
            )
        }
    }

    private var lightValue: String {
        guard let reading else { return "--" }
        return reading.lightLux.map { String(format: "%.0f", $0) } ?? "未接入"
    }
}

enum SensorMetricKind: String, CaseIterable {
    case temperature, humidity, soil, light
}

struct SensorMetric: Identifiable {
    let kind: SensorMetricKind
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let tint: Color

    var id: String { title }
}

private struct SensorMetricCard: View {
    let metric: SensorMetric
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(metric.title, systemImage: metric.symbol)
                        .font(.caption)
                        .foregroundStyle(metric.tint)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(metric.tint.opacity(isPressed ? 0.5 : 0.15), lineWidth: isPressed ? 1.5 : 1)
            }
        }
        .buttonStyle(SensorCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看\(metric.title)趋势图")
    }
}

private struct SensorCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct PrimaryInteractionButton: View {
    let realtimeConversationState: RealtimeConversationState
    let voiceVisualDriver: VoiceVisualDriver
    let isMotionPaused: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let tint = buttonTint

            Button(action: onTap) {
                DiffuseOrb(
                    tint: tint,
                    activity: animationActivity,
                    visualLevel: voiceVisualDriver.normalizedLevel,
                    accent: voiceVisualDriver.accent,
                    isMotionReduced: reduceMotion,
                    isMotionPaused: isMotionPaused
                )
                    .shadow(
                        color: tint.opacity(0.25),
                        radius: proxy.size.width * 0.12,
                        y: proxy.size.width * 0.05
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(
            realtimeConversationState.isActive
                ? "查看实时语音状态"
                : "开始实时语音对话"
        )
        .accessibilityHint(
            realtimeConversationState.isActive
                ? "打开半屏文字记录"
                : "仅使用麦克风，不会开启摄像头"
        )
    }

    // The orb keeps a single tint across every state. Connection success is
    // signaled by haptics instead of a color change.
    private var buttonTint: Color {
        .accentColor
    }

    private var animationActivity: Double {
        switch realtimeConversationState {
        case .connected:
            2.5
        case .requestingPermission, .preparingAudio, .connecting:
            1.62
        case .idle, .error:
            1.34
        }
    }

}

/// A low-frequency animated color field clipped to a circle. Moving the inner
/// mesh vertices independently creates local folds without rotating the whole
/// gradient, which reads more like light diffusing through a translucent liquid.
private struct DiffuseOrb: View {
    let tint: Color
    let activity: Double
    var visualLevel: Double = 0
    var accent: VoiceVisualAccent? = nil
    let isMotionReduced: Bool
    var isMotionPaused: Bool = false

    @State private var animationClock = PausableAnimationClock()

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: isMotionReduced || isMotionPaused
            )
        ) { timeline in
            let wallTime = timeline.date.timeIntervalSinceReferenceDate
            let meshTime = isMotionReduced
                ? 0
                : animationClock.time(at: wallTime)
            let phase = meshTime * (0.34 + 0.28 * activity)
            let accentEnvelope = isMotionReduced ? 0 : accentEnvelope(at: wallTime)
            let pulse: Double = switch accent?.kind {
            case .strongPulse:
                accentEnvelope * (0.055 + 0.04 * (accent?.intensity ?? 0))
            // A single decisive swell: roughly triple a speech pulse, so the
            // moment the model connects is unmistakable without looking glitchy.
            case .connectionEstablished:
                accentEnvelope * 0.16
            default:
                0
            }
            let breathing = isMotionReduced ? 0 : min(1, max(0, visualLevel)) * 0.012

            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 4,
                    height: 4,
                    points: meshPoints(phase: phase, accentEnvelope: accentEnvelope),
                    colors: meshColors(accentEnvelope: accentEnvelope),
                    background: Color.white,
                    smoothsColors: true
                )
                .scaleEffect(1.06)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
                .clipShape(Circle())
                .scaleEffect(1 + breathing + pulse)
            } else {
                fallbackOrb(accentEnvelope: accentEnvelope)
                    .scaleEffect(1 + breathing + pulse)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            animationClock.setPaused(
                isMotionPaused,
                at: Date.now.timeIntervalSinceReferenceDate
            )
        }
        .onChange(of: isMotionPaused) { _, isPaused in
            animationClock.setPaused(
                isPaused,
                at: Date.now.timeIntervalSinceReferenceDate
            )
        }
    }

    @available(iOS 18.0, *)
    private func meshColors(accentEnvelope: Double) -> [Color] {
        var softening = [
            0.12, 0.18, 0.3, 0.22,
            0.25, 0.18, 0.36, 0.32,
            0.78, 0.52, 0.78, 0.76,
            0.9, 0.94, 1, 0.92
        ]
        if let accent, accent.deformsMesh {
            softening[accent.meshPointIndex] = min(
                1,
                softening[accent.meshPointIndex] + accentEnvelope * 0.3
            )
        }
        return softening.map(softened)
    }

    @available(iOS 18.0, *)
    private func softened(_ amount: Double) -> Color {
        tint.mix(with: .white, by: amount, in: .perceptual)
    }

    private func fallbackOrb(accentEnvelope: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        tint.opacity(0.92),
                        tint.opacity(0.58 + accentEnvelope * 0.16),
                        .white.opacity(0.86)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 160
                )
            )
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            }
    }

    private func meshPoints(
        phase: Double,
        accentEnvelope: Double
    ) -> [SIMD2<Float>] {
        let drift = 0.035 + 0.07 * activity

        var points = [
            point(0, 0),
            point(0.33 + sin(phase * 0.73) * drift * 0.45, 0),
            point(0.67 + cos(phase * 0.81) * drift * 0.45, 0),
            point(1, 0),

            point(0, 0.33 + cos(phase * 0.69) * drift * 0.4),
            point(
                0.33 + cos(phase * 0.91) * drift,
                0.33 + sin(phase * 1.13) * drift
            ),
            point(
                0.67 + sin(phase * 1.19) * drift,
                0.33 + cos(phase * 0.83) * drift
            ),
            point(1, 0.33 + sin(phase * 0.77) * drift * 0.4),

            point(0, 0.67 + sin(phase * 0.87) * drift * 0.4),
            point(
                0.33 + sin(phase * 0.71) * drift,
                0.67 + cos(phase * 1.07) * drift
            ),
            point(
                0.67 + cos(phase * 0.67) * drift,
                0.67 + sin(phase * 0.89) * drift
            ),
            point(1, 0.67 + cos(phase * 0.93) * drift * 0.4),

            point(0, 1),
            point(0.33 + cos(phase * 0.79) * drift * 0.45, 1),
            point(0.67 + sin(phase * 0.75) * drift * 0.45, 1),
            point(1, 1)
        ]
        if let accent, accent.deformsMesh {
            points[accent.meshPointIndex] += accent.offset * Float(accentEnvelope)
        }
        return points
    }

    private func accentEnvelope(at time: TimeInterval) -> Double {
        guard let accent else { return 0 }
        let elapsed = max(0, time - accent.startedAt)
        // The connection pulse snaps out and back in ~0.4s total: a shorter,
        // harder envelope than a speech accent so it reads as one event.
        let attack: Double = switch accent.kind {
        case .connectionEstablished: 0.11
        case .strongPulse: 0.09
        case .colorShift: 0.07
        }
        let release: Double = switch accent.kind {
        case .connectionEstablished: 0.3
        case .strongPulse: 0.5
        case .colorShift: 0.34
        }

        if elapsed < attack {
            let progress = elapsed / attack
            return progress * progress * (3 - 2 * progress)
        }
        let progress = min(1, (elapsed - attack) / release)
        return (1 - progress) * (1 - progress)
    }

    private func point(_ x: Double, _ y: Double) -> SIMD2<Float> {
        SIMD2(Float(x), Float(y))
    }
}

/// Converts wall-clock time into an animation time that excludes every paused
/// interval. Keeping an in-progress pause in the calculation also prevents a
/// one-frame jump before SwiftUI delivers the corresponding `onChange`.
private struct PausableAnimationClock {
    private var accumulatedPauseDuration: TimeInterval = 0
    private var pauseStartedAt: TimeInterval?

    mutating func setPaused(_ isPaused: Bool, at wallTime: TimeInterval) {
        if isPaused {
            if pauseStartedAt == nil {
                pauseStartedAt = wallTime
            }
        } else if let pauseStartedAt {
            accumulatedPauseDuration += max(0, wallTime - pauseStartedAt)
            self.pauseStartedAt = nil
        }
    }

    func time(at wallTime: TimeInterval) -> TimeInterval {
        let effectiveWallTime = pauseStartedAt ?? wallTime
        return effectiveWallTime - accumulatedPauseDuration
    }
}

private struct HomeDashboardPreview: View {
    @State var isExpanded: Bool
    @State private var plantArtwork: PlantArtwork?
    @FocusState private var isTextComposerFocused: Bool

    var body: some View {
        HomeDashboard(
            reading: PlantReading(
                temperature: 24.8,
                humidity: 61.2,
                soilRaw: 2180,
                lightLux: 540,
                receivedAt: .now
            ),
            database: try! PlantDatabase.makeDefault(),
            isDetailsExpanded: $isExpanded,
            plantArtwork: $plantArtwork,
            isTextComposerFocused: $isTextComposerFocused,
            realtimeConversationState: .idle,
            voiceVisualDriver: VoiceVisualDriver(),
            isInteractionSuppressed: false,
            isMotionPaused: false,
            isOrbMotionPaused: false,
            onTextSend: { _ in },
            onPrimaryButtonTap: {}
        )
    }
}

@MainActor
private struct VoiceReactiveOrbPreview: View {
    @State private var driver = VoiceVisualDriver(randomUnit: { 0 })
    @State private var playback = PreviewAudioPlaybackController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiffuseOrb(
                tint: Color(hue: 0.34, saturation: 0.88, brightness: 0.62),
                activity: 1,
                visualLevel: driver.normalizedLevel,
                accent: driver.accent,
                isMotionReduced: false
            )
            .frame(width: 250, height: 250)
        }
        .task {
            await playback.playLoop(driving: driver)
        }
        .onDisappear {
            playback.stop()
        }
    }
}

@MainActor
private final class PreviewAudioPlaybackController {
    private static let frameDuration = 0.09
    private var audioPlayer: AVAudioPlayer?

    private var audioURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("PreviewAudio/gpt-live-image-interaction.wav")
    }

    func playLoop(driving driver: VoiceVisualDriver) async {
        do {
            let levels = try readLevels()
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            audioPlayer = player

            while !Task.isCancelled {
                driver.reset()
                player.currentTime = 0
                player.play()
                let playbackStart = Date.now.timeIntervalSinceReferenceDate
                var nextFrameIndex = 0

                while player.isPlaying, !Task.isCancelled {
                    let currentFrameIndex = min(
                        levels.count - 1,
                        Int(player.currentTime / Self.frameDuration)
                    )
                    while nextFrameIndex <= currentFrameIndex {
                        driver.ingest(
                            source: .assistant,
                            levelDBFS: levels[nextFrameIndex],
                            at: Date(
                                timeIntervalSinceReferenceDate: playbackStart
                                    + Double(nextFrameIndex) * Self.frameDuration
                            )
                        )
                        nextFrameIndex += 1
                    }
                    try await Task.sleep(for: .milliseconds(16))
                }

                guard !Task.isCancelled else { break }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            // Preview cancellation is expected when Canvas stops or recompiles.
        } catch {
            assertionFailure("无法播放 Preview 音频：\(error)")
        }
        stop()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func readLevels() throws -> [Float] {
        let file = try AVAudioFile(
            forReading: audioURL,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let sampleRate = file.processingFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(sampleRate * Self.frameDuration)
        var levels: [Float] = []

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCapacity
            ) else {
                throw RealtimeAudioError.unsupportedAudioFormat
            }
            try file.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0,
                  let samples = buffer.int16ChannelData?.pointee else {
                break
            }
            levels.append(AudioLevelAnalyzer.levelDBFS(
                samples: samples,
                count: Int(buffer.frameLength)
            ))
        }

        guard !levels.isEmpty else {
            throw RealtimeAudioError.conversionFailed("Preview 音频没有可读取的 PCM 数据。")
        }
        return levels
    }
}

#Preview("声音响应 · 真实音频同步") {
    VoiceReactiveOrbPreview()
}

// hue 0.37  ≈ 翠绿（介于纯绿和青绿之间）
// saturation 越高 → 越鲜艳；brightness 越低 → 越深沉
// softened 用 mix(with:.white) 混白，tint 越深混完之后仍保留厚重感

// ── A：中深绿（brightness 0.62）────────────────────────
// 比系统 .green 明显更深，混白后仍饱满，不发黑
#Preview("A · 中深绿 b=0.62") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.34, saturation: 0.88, brightness: 0.62),
            activity: 2.4,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

// ── B：深绿（brightness 0.52）──────────────────────────
// 再深一档，顶部区域会出现明显的墨绿感
#Preview("B · 深绿 b=0.52") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.37, saturation: 0.90, brightness: 0.52),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

// ── C：更深绿（brightness 0.42）────────────────────────
// 接近森林绿 / 墨绿，顶部极深，向白色渐变对比强烈
#Preview("C · 更深绿 b=0.42") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.37, saturation: 0.92, brightness: 0.42),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

// ── D：极深绿（brightness 0.32）────────────────────────
// 极限深色，顶部接近暗绿/黑绿，仅供参考下限
#Preview("D · 极深绿 b=0.32") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.37, saturation: 0.95, brightness: 0.32),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

// ── 以下四组基于方案A参数：saturation 0.88，brightness 0.62 ──────
// 黄色例外：brightness 提至 0.80，否则低亮度下黄色变芥末色

#Preview("蓝色 hue=0.62") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.62, saturation: 0.88, brightness: 0.62),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

#Preview("紫色 hue=0.77") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.77, saturation: 0.88, brightness: 0.62),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

// 黄色在低 brightness 下会偏芥末/橄榄色，提至 0.80 保持纯正黄
#Preview("黄色 hue=0.13 b=0.80") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.13, saturation: 0.88, brightness: 0.80),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}

#Preview("粉色 hue=0.94") {
    ZStack {
        Color.black.ignoresSafeArea()
        DiffuseOrb(
            tint: Color(hue: 0.94, saturation: 0.88, brightness: 0.62),
            activity: 1.6,
            isMotionReduced: false
        )
        .frame(width: 220, height: 220)
    }
}


#Preview("收起") {
    HomeDashboardPreview(isExpanded: false)
}

#Preview("展开") {
    HomeDashboardPreview(isExpanded: true)
}

#Preview("展开 · 深色") {
    HomeDashboardPreview(isExpanded: true)
        .preferredColorScheme(.dark)
}

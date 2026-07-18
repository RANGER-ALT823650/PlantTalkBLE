import AVFAudio
import SwiftUI

let messageFlightCoordinateSpace = "plant-talk-message-flight"

struct MessageFlightRequest: Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let sourceFrame: CGRect
    let showsOverlayWhilePreparing: Bool
}

private struct ActiveMessageFlight: Equatable {
    let request: MessageFlightRequest
    var currentFrame: CGRect
    var progress: CGFloat = 0
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
    let plantBindingResolver: PlantConversationBindingResolver

    @State private var realtimeConversation: QwenRealtimeConversation
    @State private var isRealtimeTranscriptPresented = false
    @State private var isHistoryOverviewPresented = false
    @State private var isPlantDetailsExpanded = false
    @State private var activeTextChat: TextChatLaunch?
    @State private var isInitialTextChatTransitionComplete = false
    @State private var activeMessageFlight: ActiveMessageFlight?
    @State private var startedMessageFlightID: UUID?
    @State private var completedMessageFlightID: UUID?
    @State private var messageFlightDestinations: [UUID: CGRect] = [:]
    @State private var messageFlightDestinationValidationTask: Task<Void, Never>?
    @State private var textChatStartError: String?
    @State private var isTextChatStartErrorPresented = false
    @State private var plantArtwork: PlantArtwork?
    @FocusState private var isHomeTextComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        bluetooth: PlantBluetoothManager,
        database: PlantDatabase,
        aiClient: OpenAICompatibleClient
    ) {
        self.bluetooth = bluetooth
        self.database = database
        self.aiClient = aiClient
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
                plantBindingResolver: plantBindingResolver
            )
        )
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ZStack {
                    screenLayers

                    if let activeMessageFlight,
                       activeMessageFlight.hasStarted
                        || activeMessageFlight.request.showsOverlayWhilePreparing {
                        MessageFlightOverlay(flight: activeMessageFlight)
                            .allowsHitTesting(false)
                            .zIndex(100)
                    }
                }
                .coordinateSpace(name: messageFlightCoordinateSpace)
                .onPreferenceChange(MessageFlightDestinationPreferenceKey.self) { destinations in
                    messageFlightDestinations = destinations
                    scheduleMessageFlightDestinationValidation()
                }
                .sheet(isPresented: $isRealtimeTranscriptPresented) {
                    RealtimeConversationSheet(conversation: realtimeConversation)
                }
                .onChange(of: realtimeConversation.state) { _, state in
                    if case .error = state {
                        isRealtimeTranscriptPresented = true
                    }
                }
                .simultaneousGesture(showHistoryGesture)
            }

            if isHistoryOverviewPresented {
                NavigationStack {
                    HistoryOverviewView(database: database)
                        .background(Color(uiColor: .systemBackground))
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(action: hideHistoryOverview) {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel("返回")
                            }
                        }
                }
                .simultaneousGesture(hideHistoryGesture)
                .transition(historyOverviewTransition)
                .zIndex(50)
            }
        }
        .alert("无法开始植物对话", isPresented: $isTextChatStartErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(textChatStartError ?? "无法绑定当前植物。")
        }
    }

    private var screenLayers: some View {
        ZStack {
            if let activeTextChat,
               let plantBinding = activeTextChat.plantBinding {
                TextConversationView(
                    database: database,
                    client: aiClient,
                    toolExecutor: PlantDataToolExecutor(
                        database: database,
                        bluetooth: bluetooth,
                        boundDeviceID: plantBinding.deviceID
                    ),
                    plantBinding: plantBinding,
                    initialMessage: activeTextChat.message,
                    initialMessageID: activeTextChat.id,
                    initialMessageDate: activeTextChat.createdAt,
                    isInitialTransitionComplete: isInitialTextChatTransitionComplete,
                    completedMessageFlightID: completedMessageFlightID,
                    startedMessageFlightID: startedMessageFlightID,
                    onMessageFlightRequested: beginMessageFlight,
                    onMessageFlightCancelled: cancelMessageFlight,
                    onHome: returnToHome
                )
                .zIndex(0)
            } else {
                HomeDashboard(
                    reading: bluetooth.reading,
                    database: database,
                    isDetailsExpanded: $isPlantDetailsExpanded,
                    plantArtwork: plantArtworkBinding,
                    isTextComposerFocused: $isHomeTextComposerFocused,
                    realtimeConversationState: realtimeConversation.state,
                    voiceVisualDriver: realtimeConversation.voiceVisualDriver,
                    onTextSend: startTextConversation,
                    onPrimaryButtonTap: handleRealtimeButtonTap
                )
                .zIndex(1)
                .toolbar {
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
                            AppSettingsView(database: database)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
            }
        }
    }

    private var historyOverviewTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .leading)
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

    private var showHistoryGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard activeTextChat == nil,
                      !isHistoryOverviewPresented,
                      isHorizontalSwipe(value.translation),
                      value.translation.width > 70 else { return }
                showHistoryOverview()
            }
    }

    private var hideHistoryGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard isHorizontalSwipe(value.translation),
                      value.translation.width < -70 else { return }
                hideHistoryOverview()
            }
    }

    private func isHorizontalSwipe(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.25
    }

    private func showHistoryOverview() {
        isHomeTextComposerFocused = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
            isHistoryOverviewPresented = true
        }
    }

    private func hideHistoryOverview() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
            isHistoryOverviewPresented = false
        }
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

        Task {
            await realtimeConversation.start()
        }
    }

    private func startTextConversation(_ launch: TextChatLaunch) {
        Task { @MainActor in
            do {
                let plantBinding = try await plantBindingResolver.bindCurrentPlant()
                guard !Task.isCancelled else { return }
                presentTextConversation(launch.bound(to: plantBinding))
            } catch {
                guard !Task.isCancelled else { return }
                textChatStartError = error.localizedDescription
                isTextChatStartErrorPresented = true
            }
        }
    }

    private func presentTextConversation(_ launch: TextChatLaunch) {
        isInitialTextChatTransitionComplete = false
        completedMessageFlightID = nil
        beginMessageFlight(MessageFlightRequest(
            id: launch.id,
            text: launch.message,
            createdAt: launch.createdAt,
            sourceFrame: launch.sourceFrame,
            showsOverlayWhilePreparing: true
        ))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeTextChat = launch
        }
    }

    private func returnToHome() {
        messageFlightDestinationValidationTask?.cancel()
        messageFlightDestinationValidationTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeTextChat = nil
            isInitialTextChatTransitionComplete = false
            activeMessageFlight = nil
            startedMessageFlightID = nil
            completedMessageFlightID = nil
        }
    }

    private func beginMessageFlight(_ request: MessageFlightRequest) {
        guard !request.sourceFrame.isEmpty else { return }
        messageFlightDestinationValidationTask?.cancel()
        startedMessageFlightID = nil
        completedMessageFlightID = nil
        activeMessageFlight = ActiveMessageFlight(
            request: request,
            currentFrame: request.sourceFrame
        )
        scheduleMessageFlightDestinationValidation()
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
                completionCriteria: .logicallyComplete
            ) {
                activeMessageFlight?.currentFrame = destination
                activeMessageFlight?.progress = 1
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

private struct TextChatLaunch: Identifiable, Equatable {
    let id: UUID
    let message: String
    let createdAt: Date
    let sourceFrame: CGRect
    let plantBinding: PlantConversationBinding?

    init(message: String, sourceFrame: CGRect) {
        id = UUID()
        self.message = message
        createdAt = Date()
        self.sourceFrame = sourceFrame
        plantBinding = nil
    }

    private init(
        id: UUID,
        message: String,
        createdAt: Date,
        sourceFrame: CGRect,
        plantBinding: PlantConversationBinding
    ) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.sourceFrame = sourceFrame
        self.plantBinding = plantBinding
    }

    func bound(to plantBinding: PlantConversationBinding) -> TextChatLaunch {
        TextChatLaunch(
            id: id,
            message: message,
            createdAt: createdAt,
            sourceFrame: sourceFrame,
            plantBinding: plantBinding
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
    let onTextSend: (TextChatLaunch) -> Void
    let onPrimaryButtonTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset = proxy.size.width * 0.05
            let contentWidth = proxy.size.width - horizontalInset * 2
            let artworkWidth = contentWidth * (isDetailsExpanded ? 0.38 : 0.66)
            let actionButtonWidth = contentWidth * 0.32

            ZStack {
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
                            onSend: onTextSend
                        )
                        .padding(.top)
                        .padding(.bottom, 12)
                        .transition(textComposerTransition)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxHeight: proxy.size.height * 0.12)
                    }

                    PlantArtworkControl(
                        artwork: $plantArtwork,
                        isDetailsExpanded: isDetailsExpanded,
                        onTap: toggleDetails
                    )
                    .frame(width: artworkWidth)

                    if isDetailsExpanded {
                        SensorReadingGrid(reading: reading, database: database)
                            .padding(.top, 12)
                            .transition(sensorGridTransition)
                    }

                    Spacer(minLength: 0)

                    PrimaryInteractionButton(
                        realtimeConversationState: realtimeConversationState,
                        voiceVisualDriver: voiceVisualDriver,
                        onTap: onPrimaryButtonTap
                    )
                    .frame(width: actionButtonWidth)
                    .padding(.bottom)
                }
                .padding(.horizontal, horizontalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: realtimeConversationState.isActive) { _, isActive in
            if isActive {
                isTextComposerFocused.wrappedValue = false
            }
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
            draft = ""
        }
        isInputFocused.wrappedValue = false
        onSend(launch)
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

private struct MessageFlightOverlay: View {
    let flight: ActiveMessageFlight

    var body: some View {
        let frame = flight.currentFrame
        let shape = MessageFlightBubbleShape()

        Text(flight.request.text)
            .foregroundStyle(.primary)
            .lineLimit(5)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18 - 4 * flight.progress)
            .padding(.trailing, 18 + 2 * flight.progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.accentColor.opacity(0.2 * flight.progress))
            }
            .overlay {
                shape.stroke(
                    Color.accentColor.opacity(0.32 * flight.progress),
                    lineWidth: 0.5
                )
            }
            .clipShape(shape)
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .compositingGroup()
    }
}

private struct MessageFlightBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        ChatBubbleShape(tailSide: .trailing).path(in: rect)
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

    @State private var selectedMetric: SensorMetric?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(metrics) { metric in
                SensorMetricCard(metric: metric) {
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
                    isMotionReduced: reduceMotion
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

    private var buttonTint: Color {
        switch realtimeConversationState {
        case .connected:
            .green
        case .requestingPermission, .preparingAudio, .connecting:
            .orange
        case .idle, .error:
            .accentColor
        }
    }

    private var animationActivity: Double {
        switch realtimeConversationState {
        case .connected:
            1
        case .requestingPermission, .preparingAudio, .connecting:
            0.62
        case .idle, .error:
            0.34
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isMotionReduced)) { timeline in
            let time = isMotionReduced ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let phase = time * (0.34 + 0.28 * activity)
            let accentEnvelope = isMotionReduced ? 0 : accentEnvelope(at: time)
            let pulse = accent?.kind == .strongPulse
                ? accentEnvelope * (0.035 + 0.02 * (accent?.intensity ?? 0))
                : 0
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
    }

    @available(iOS 18.0, *)
    private func meshColors(accentEnvelope: Double) -> [Color] {
        var softening = [
            0.12, 0.18, 0.3, 0.22,
            0.25, 0.38, 0.56, 0.32,
            0.78, 0.62, 0.88, 0.76,
            0.9, 0.94, 1, 0.92
        ]
        if let accent {
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
        if let accent {
            points[accent.meshPointIndex] += accent.offset * Float(accentEnvelope)
        }
        return points
    }

    private func accentEnvelope(at time: TimeInterval) -> Double {
        guard let accent else { return 0 }
        let elapsed = max(0, time - accent.startedAt)
        let attack = accent.kind == .strongPulse ? 0.09 : 0.07
        let release = accent.kind == .strongPulse ? 0.5 : 0.34

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

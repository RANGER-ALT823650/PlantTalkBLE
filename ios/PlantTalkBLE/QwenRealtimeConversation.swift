import AVFAudio
import Foundation
import Observation
import UIKit

struct RealtimeTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let text: String
    let createdAt: Date
    let imageAttachments: [ChatImageAttachment]
    let toolInvocations: [ToolInvocation]

    init(
        id: UUID,
        role: ChatRole,
        text: String,
        createdAt: Date,
        imageAttachments: [ChatImageAttachment] = [],
        toolInvocations: [ToolInvocation]
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.imageAttachments = imageAttachments
        self.toolInvocations = toolInvocations
    }
}

enum RealtimeConversationState: Equatable {
    case idle
    case requestingPermission
    case preparingAudio
    case connecting
    case connected
    case error(String)

    var title: String {
        switch self {
        case .idle: "尚未开始"
        case .requestingPermission: "正在请求麦克风权限…"
        case .preparingAudio: "正在准备麦克风…"
        case .connecting: "正在连接实时模型…"
        case .connected: "正在实时对话"
        case .error(let message): message
        }
    }

    var isActive: Bool {
        switch self {
        case .requestingPermission, .preparingAudio, .connecting, .connected: true
        case .idle, .error: false
        }
    }
}

enum RealtimeConversationError: LocalizedError {
    case microphonePermissionDenied
    case missingPlantBinding
    case invalidServerMessage
    case server(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "未获得麦克风权限，请在系统设置中允许 Plant Talk 使用麦克风。"
        case .missingPlantBinding:
            "当前实时对话尚未绑定植物设备。"
        case .invalidServerMessage:
            "实时模型返回了无法识别的消息。"
        case .server(let message):
            "实时模型错误：\(message)"
        }
    }
}

struct QwenRealtimeServerEvent: Decodable, Equatable, Sendable {
    struct ErrorPayload: Decodable, Equatable, Sendable {
        let message: String
    }

    let type: String
    let delta: String?
    let transcript: String?
    let text: String?
    let stash: String?
    let name: String?
    let callID: String?
    let arguments: String?
    let error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
        case type, delta, transcript, text, stash, name, arguments, error
        case callID = "call_id"
    }
}

/// Provider-specific framing for Qwen Omni Realtime tool use. Keeping these
/// messages separate from the live WebSocket makes the protocol executable in
/// tests without connecting to a model.
enum QwenRealtimeToolProtocol {
    static let functionCallArgumentsDone = "response.function_call_arguments.done"
    /// Qwen requires an audio append before an image append. Priming each frame
    /// with 20 ms of silent PCM16 also re-establishes that ordering after
    /// server-side VAD commits the previous input buffer.
    static let visualPrimingPCMByteCount = Int(16_000 * 2 * 0.02)

    static func toolCall(from event: QwenRealtimeServerEvent) throws -> AIModelToolCall {
        guard event.type == functionCallArgumentsDone,
              let callID = event.callID,
              !callID.isEmpty,
              let name = event.name,
              !name.isEmpty,
              let arguments = event.arguments else {
            throw RealtimeConversationError.invalidServerMessage
        }
        return AIModelToolCall(
            id: callID,
            type: "function",
            function: .init(name: name, arguments: arguments)
        )
    }

    static func sessionTools(
        from definitions: [AIModelToolDefinition]
    ) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(definitions)
        guard let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RealtimeConversationError.invalidServerMessage
        }
        return tools
    }

    static func sessionUpdateEvent(
        eventID: String,
        voice: String,
        instructions: String,
        tools: [[String: Any]]
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": voice,
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                "input_audio_transcription": [
                    "model": "qwen3-asr-flash-realtime"
                ],
                "instructions": instructions,
                "tools": tools,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800
                ]
            ]
        ]
    }

    static func functionCallOutputEvent(
        eventID: String,
        callID: String,
        output: String
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ]
    }

    static func responseCreateEvent(eventID: String) -> [String: Any] {
        // Qwen's Realtime protocol uses the modalities from session.update.
        // It explicitly does not support OpenAI's tool_choice parameters.
        [
            "event_id": eventID,
            "type": "response.create"
        ]
    }

    static func imageAppendEvent(
        eventID: String,
        imageData: Data
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "type": "input_image_buffer.append",
            "image": imageData.base64EncodedString()
        ]
    }

    static func audioAppendEvent(
        eventID: String,
        audioData: Data
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "type": "input_audio_buffer.append",
            "audio": audioData.base64EncodedString()
        ]
    }

    static func visualInputEvents(
        eventIDPrefix: String,
        imageData: Data
    ) -> [[String: Any]] {
        let silentPCM = Data(repeating: 0, count: visualPrimingPCMByteCount)
        return [
            audioAppendEvent(
                eventID: "\(eventIDPrefix)_audio",
                audioData: silentPCM
            ),
            imageAppendEvent(
                eventID: "\(eventIDPrefix)_image",
                imageData: imageData
            )
        ]
    }

    static func historyMessageEvent(
        eventID: String,
        message: ChatMessage
    ) -> [String: Any]? {
        let contentType: String
        switch message.role {
        case .user:
            contentType = "input_text"
        case .assistant:
            contentType = "output_text"
        case .system:
            return nil
        }

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return [
            "event_id": eventID,
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": message.role.rawValue,
                "content": [[
                    "type": contentType,
                    "text": text
                ]]
            ]
        ]
    }
}

enum RealtimeBargeInPolicy {
    static let requiredDuration: TimeInterval = 0.28

    /// Residual speaker audio is commonly quieter than the assistant output,
    /// so interruption requires the microphone to exceed the audible response
    /// by 3 dB. Clamp the threshold so quiet and loud playback both remain usable.
    static func requiredInputLevel(responseLevelDBFS: Float) -> Float {
        min(-10, max(-24, responseLevelDBFS + 3))
    }
}

@MainActor
@Observable
final class QwenRealtimeConversation {
    private static let maximumBargeInPreRollBytes = Int(16_000 * 2 * 0.35)
    private static let maximumPreConnectionAudioBytes = Int(16_000 * 2 * 15)

    private(set) var state: RealtimeConversationState = .idle
    private(set) var entries: [RealtimeTranscriptEntry] = []
    private(set) var currentUserText = ""
    private(set) var currentAssistantText = ""
    private(set) var currentUserEntryID: UUID?
    private(set) var currentAssistantEntryID: UUID?
    private(set) var currentUserStartedAt: Date?
    private(set) var currentAssistantStartedAt: Date?
    private(set) var isUserSpeaking = false
    private(set) var isWaitingForAssistantText = false
    let voiceVisualDriver = VoiceVisualDriver()

    @ObservationIgnored private let database: PlantDatabase
    @ObservationIgnored private let bluetooth: PlantBluetoothManager
    @ObservationIgnored private let plantBindingResolver: PlantConversationBindingResolver
    @ObservationIgnored private let memoryStore: PlantMemoryStore
    @ObservationIgnored private var toolExecutor: PlantDataToolExecutor?
    @ObservationIgnored private let audioIO = RealtimeAudioIO()
    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var mediaSendTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var bargeInConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var audioStartupWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var startAttemptID: UUID?
    @ObservationIgnored private var currentPersistenceSessionID = UUID()
    @ObservationIgnored private var conversationsBySessionID: [UUID: AIConversation] = [:]
    @ObservationIgnored private var isResponding = false
    @ObservationIgnored private var isDiscardingCancelledResponse = false
    @ObservationIgnored private var audioStarted = false
    @ObservationIgnored private var bargeInPreRoll: [Data] = []
    @ObservationIgnored private var bargeInPreRollByteCount = 0
    @ObservationIgnored private var candidateBargeInDuration: TimeInterval = 0
    @ObservationIgnored private var isReleasingBargeInAudio = false
    @ObservationIgnored private var preConnectionAudio: [Data] = []
    @ObservationIgnored private var preConnectionAudioByteCount = 0
    @ObservationIgnored private var microphoneChunkCount = 0
    @ObservationIgnored private var pinnedStillImageData: Data?
    @ObservationIgnored private var hasReplayedPinnedImageForCurrentSpeech = false
    @ObservationIgnored private var hasRetriedSilentAudioStart = false
    @ObservationIgnored private var pendingToolCalls: [AIModelToolCall] = []
    @ObservationIgnored private var pendingAssistantToolInvocations: [ToolInvocation] = []

    init(
        database: PlantDatabase,
        bluetooth: PlantBluetoothManager,
        plantBindingResolver: PlantConversationBindingResolver,
        memoryStore: PlantMemoryStore
    ) {
        self.database = database
        self.bluetooth = bluetooth
        self.plantBindingResolver = plantBindingResolver
        self.memoryStore = memoryStore
    }

    func start(
        resuming conversation: AIConversation? = nil,
        messages: [ChatMessage] = []
    ) async {
        guard !state.isActive else { return }
        let historyMessages = messages.filter {
            $0.role != .system
                && (
                    !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !$0.imageAttachments.isEmpty
                )
        }
        let attemptID = UUID()
        startAttemptID = attemptID
        entries = historyMessages.map { message in
            RealtimeTranscriptEntry(
                id: message.id,
                role: message.role,
                text: message.content,
                createdAt: message.createdAt,
                imageAttachments: message.imageAttachments,
                toolInvocations: message.toolInvocations
            )
        }
        currentUserText = ""
        currentAssistantText = ""
        currentUserEntryID = nil
        currentAssistantEntryID = nil
        currentUserStartedAt = nil
        currentAssistantStartedAt = nil
        currentPersistenceSessionID = UUID()
        if let conversation {
            conversationsBySessionID[currentPersistenceSessionID] = conversation
        }
        isUserSpeaking = false
        isWaitingForAssistantText = false
        voiceVisualDriver.reset()
        isResponding = false
        isDiscardingCancelledResponse = false
        resetPreConnectionAudio()
        microphoneChunkCount = 0
        pinnedStillImageData = nil
        hasReplayedPinnedImageForCurrentSpeech = false
        hasRetriedSilentAudioStart = false
        pendingToolCalls.removeAll(keepingCapacity: true)
        pendingAssistantToolInvocations.removeAll(keepingCapacity: true)
        resetLocalBargeInDetection()
        toolExecutor = nil
        state = .requestingPermission

        do {
            let plantBinding = try await plantBindingResolver.bindCurrentPlant()
            guard isCurrentStartAttempt(attemptID) else { return }
            toolExecutor = PlantDataToolExecutor(
                database: database,
                bluetooth: bluetooth,
                boundDeviceID: plantBinding.deviceID
            )

            let configuration = try AISettingsStore.realtimeConfiguration()
            let permissionResult = await requestMicrophonePermission()
            guard isCurrentStartAttempt(attemptID) else { return }
            guard permissionResult != .denied else {
                throw RealtimeConversationError.microphonePermissionDenied
            }

            state = .preparingAudio
            if permissionResult == .newlyGranted {
                await waitForAudioSystemAfterFirstAuthorization(attemptID: attemptID)
                guard isCurrentStartAttempt(attemptID) else { return }
            }
            try audioIO.prepareForRealtimeConversation()
            guard isCurrentStartAttempt(attemptID) else { return }
            // Begin capturing before the cold WebSocket handshake finishes.
            // Audio spoken during startup is retained locally and flushed once
            // the server confirms session.updated.
            try await startAudioIfNeeded()
            guard isCurrentStartAttempt(attemptID) else { return }

            state = .connecting
            var request = URLRequest(url: Self.endpointURL(
                baseURL: configuration.baseURL,
                model: configuration.model
            ))
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

            let socket = URLSession.shared.webSocketTask(with: request)
            webSocket = socket
            socket.resume()
            connectionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled,
                      let self,
                      self.isCurrentStartAttempt(attemptID),
                      self.state == .connecting else { return }
                self.fail(URLError(.timedOut), attemptID: attemptID)
            }

            // Respect the server handshake order on a cold connection. The
            // server creates the session first; only then do we update it.
            let initialEvent = try await receiveServerEvent(from: socket)
            guard isCurrentStartAttempt(attemptID) else { return }
            if initialEvent.type == "error" {
                throw RealtimeConversationError.server(
                    initialEvent.error?.message ?? "未知服务端错误"
                )
            }
            if initialEvent.type != "session.created" {
                try await handle(initialEvent)
            }

            try await sendSessionUpdate(configuration, plantBinding: plantBinding)
            guard isCurrentStartAttempt(attemptID) else { return }
            for message in historyMessages {
                guard let event = QwenRealtimeToolProtocol.historyMessageEvent(
                    eventID: "event_\(UUID().uuidString)",
                    message: message
                ) else { continue }
                try await sendJSON(event)
            }
            guard isCurrentStartAttempt(attemptID) else { return }
            receiveTask = Task { [weak self] in
                await self?.receiveMessages(from: socket, attemptID: attemptID)
            }
        } catch {
            fail(error, attemptID: attemptID)
        }
    }

    func stop() {
        startAttemptID = nil
        finishPendingTranscripts()
        tearDown()
        state = .idle
    }

    /// Adds a still image or an extracted camera frame to the current realtime
    /// turn. Qwen commits the visual buffer together with the audio buffer when
    /// server-side VAD detects the end of the user's next utterance.
    func sendVisualFrame(_ imageData: Data) async throws {
        guard state == .connected else {
            throw URLError(.notConnectedToInternet)
        }
        let operation = enqueueMediaEvents(
            QwenRealtimeToolProtocol.visualInputEvents(
                eventIDPrefix: "event_\(UUID().uuidString)",
                imageData: imageData
            )
        )
        try await operation.value.get()
    }

    /// Adds a user-visible image-only message after a one-shot photo has been
    /// written to the realtime socket. Continuous camera samples intentionally
    /// do not call this method, so the transcript is not flooded with frames.
    func recordSentImage(_ imageData: Data) {
        guard !imageData.isEmpty else { return }
        pinnedStillImageData = imageData
        // If VAD has already marked this utterance as active, the original
        // sendVisualFrame call placed the image inside the current turn.
        hasReplayedPinnedImageForCurrentSpeech = isUserSpeaking
        let messageID = UUID()
        let entry = RealtimeTranscriptEntry(
            id: messageID,
            role: .user,
            text: "",
            createdAt: Date(),
            imageAttachments: [
                ChatImageAttachment(
                    id: "realtime-\(messageID.uuidString)-image",
                    mimeType: "image/jpeg",
                    data: imageData
                )
            ],
            toolInvocations: []
        )
        entries.append(entry)
        enqueuePersistence(entry)
    }

    func clearPinnedStillImage() {
        pinnedStillImageData = nil
        hasReplayedPinnedImageForCurrentSpeech = false
    }

    nonisolated static func endpointURL(baseURL: URL, model: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "model" }
        queryItems.append(URLQueryItem(name: "model", value: model))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    private func receiveMessages(
        from socket: URLSessionWebSocketTask,
        attemptID: UUID
    ) async {
        do {
            while !Task.isCancelled {
                let event = try await receiveServerEvent(from: socket)
                guard isCurrentStartAttempt(attemptID) else { return }
                try await handle(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            fail(error, attemptID: attemptID)
        }
    }

    private func receiveServerEvent(
        from socket: URLSessionWebSocketTask
    ) async throws -> QwenRealtimeServerEvent {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            guard let valueData = value.data(using: .utf8) else {
                throw RealtimeConversationError.invalidServerMessage
            }
            data = valueData
        @unknown default:
            throw RealtimeConversationError.invalidServerMessage
        }
        return try JSONDecoder().decode(QwenRealtimeServerEvent.self, from: data)
    }

    private func handle(_ event: QwenRealtimeServerEvent) async throws {
        switch event.type {
        case "session.updated":
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            state = .connected
            flushPreConnectionAudio()

        case "input_audio_buffer.speech_started":
            prepareCurrentUserTranscript()
            isUserSpeaking = true
            replayPinnedStillImageForCurrentSpeech()
            scheduleBargeInConfirmation()

        case "input_audio_buffer.speech_stopped":
            isUserSpeaking = false
            hasReplayedPinnedImageForCurrentSpeech = false
            bargeInConfirmationTask?.cancel()
            bargeInConfirmationTask = nil

        case "conversation.item.input_audio_transcription.delta":
            prepareCurrentUserTranscript()
            currentUserText = (event.text ?? "") + (event.stash ?? "")

        case "conversation.item.input_audio_transcription.completed":
            let text = event.transcript ?? currentUserText
            finishCurrentUserTranscript(text: text)

        case "response.created":
            isResponding = true
            isWaitingForAssistantText = true
            currentAssistantText = ""

        case QwenRealtimeToolProtocol.functionCallArgumentsDone:
            let call = try QwenRealtimeToolProtocol.toolCall(from: event)
            guard !pendingToolCalls.contains(where: { $0.id == call.id }) else { return }
            pendingToolCalls.append(call)

        case "response.audio_transcript.delta":
            if !isDiscardingCancelledResponse {
                prepareCurrentAssistantTranscript()
                currentAssistantText += event.delta ?? ""
                if !currentAssistantText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    isWaitingForAssistantText = false
                }
            }

        case "response.audio.delta":
            if !isUserSpeaking,
               !isDiscardingCancelledResponse,
               let encoded = event.delta,
               let data = Data(base64Encoded: encoded) {
                audioIO.playResponsePCM(data)
            }

        case "response.audio_transcript.done":
            if !isDiscardingCancelledResponse {
                let text = event.transcript ?? currentAssistantText
                finishCurrentAssistantTranscript(text: text)
            }

        case "response.done":
            isResponding = false
            let wasDiscardingCancelledResponse = isDiscardingCancelledResponse
            isDiscardingCancelledResponse = false
            guard !wasDiscardingCancelledResponse else {
                pendingToolCalls.removeAll(keepingCapacity: true)
                isWaitingForAssistantText = false
                return
            }
            if pendingToolCalls.isEmpty {
                isWaitingForAssistantText = false
            } else {
                clearCurrentAssistantTranscript()
                try await executePendingToolCalls()
            }

        case "error":
            throw RealtimeConversationError.server(event.error?.message ?? "未知服务端错误")

        default:
            break
        }
    }

    private func startAudioIfNeeded() async throws {
        guard !audioStarted else { return }
        do {
            try startAudioEngine()
        } catch {
            // The first engine start after the system permission alert can race
            // the audio route becoming available. Tear down the partial graph and
            // retry once after the route has settled.
            audioIO.stop()
            try await Task.sleep(for: .milliseconds(250))
            try audioIO.prepareForRealtimeConversation()
            try startAudioEngine()
        }
        audioStarted = true
        scheduleAudioStartupWatchdog()
    }

    private func startAudioEngine() throws {
        try audioIO.start(
            onMicrophonePCM: { [weak self] chunk in
                Task { @MainActor in
                    self?.handleMicrophoneChunk(chunk)
                }
            },
            onResponseLevelDBFS: { [weak self] levelDBFS in
                Task { @MainActor in
                    guard self?.state == .connected else { return }
                    self?.voiceVisualDriver.ingest(
                        source: .assistant,
                        levelDBFS: levelDBFS
                    )
                }
            }
        )
    }

    private func handleMicrophoneChunk(_ chunk: RealtimeMicrophoneChunk) {
        microphoneChunkCount += 1

        if state == .connected, !chunk.isResponsePlaybackActive {
            voiceVisualDriver.ingest(source: .user, levelDBFS: chunk.levelDBFS)
        }

        guard state == .connected else {
            if state.isActive {
                appendPreConnectionAudio(chunk.data)
            }
            return
        }

        if isReleasingBargeInAudio {
            appendBargeInPreRoll(chunk.data)
            return
        }

        guard chunk.isResponsePlaybackActive else {
            resetLocalBargeInDetection()
            enqueueAudio(chunk.data)
            return
        }

        // Never send ordinary microphone frames while response audio is audible.
        // This keeps residual speaker echo away from the server-side VAD/ASR.
        appendBargeInPreRoll(chunk.data)

        let adaptiveThreshold = RealtimeBargeInPolicy.requiredInputLevel(
            responseLevelDBFS: chunk.responseLevelDBFS
        )
        let chunkDuration = Double(chunk.data.count) / (16_000 * 2)
        if chunk.levelDBFS >= adaptiveThreshold {
            candidateBargeInDuration += chunkDuration
        } else {
            candidateBargeInDuration = 0
        }

        guard candidateBargeInDuration >= RealtimeBargeInPolicy.requiredDuration else { return }

        isUserSpeaking = true
        isReleasingBargeInAudio = true
        audioIO.interruptPlayback()
        Task { [weak self] in
            await self?.releaseConfirmedBargeInAudio()
        }
    }

    private func appendPreConnectionAudio(_ data: Data) {
        preConnectionAudio.append(data)
        preConnectionAudioByteCount += data.count
        while preConnectionAudioByteCount > Self.maximumPreConnectionAudioBytes,
              preConnectionAudio.count > 1 {
            preConnectionAudioByteCount -= preConnectionAudio.removeFirst().count
        }
    }

    private func flushPreConnectionAudio() {
        let bufferedAudio = preConnectionAudio
        resetPreConnectionAudio()
        for data in bufferedAudio {
            enqueueAudio(data)
        }
    }

    private func resetPreConnectionAudio() {
        preConnectionAudio.removeAll(keepingCapacity: true)
        preConnectionAudioByteCount = 0
    }

    private func scheduleAudioStartupWatchdog() {
        audioStartupWatchdogTask?.cancel()
        guard let attemptID = startAttemptID else { return }
        audioStartupWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentStartAttempt(attemptID),
                  self.state.isActive,
                  self.microphoneChunkCount == 0,
                  !self.hasRetriedSilentAudioStart else { return }

            self.hasRetriedSilentAudioStart = true
            self.audioIO.stop()
            self.audioStarted = false
            do {
                try await self.startAudioIfNeeded()
            } catch {
                self.fail(error, attemptID: attemptID)
            }
        }
    }

    private func appendBargeInPreRoll(_ data: Data) {
        bargeInPreRoll.append(data)
        bargeInPreRollByteCount += data.count
        while bargeInPreRollByteCount > Self.maximumBargeInPreRollBytes,
              bargeInPreRoll.count > 1 {
            bargeInPreRollByteCount -= bargeInPreRoll.removeFirst().count
        }
    }

    private func releaseConfirmedBargeInAudio() async {
        if isResponding {
            isDiscardingCancelledResponse = true
            try? await sendJSON(["type": "response.cancel"])
            finishAssistantTranscript(interrupted: true)
        }

        let bufferedAudio = bargeInPreRoll
        resetLocalBargeInDetection()
        for data in bufferedAudio {
            enqueueAudio(data)
        }
    }

    private func resetLocalBargeInDetection() {
        bargeInPreRoll.removeAll(keepingCapacity: true)
        bargeInPreRollByteCount = 0
        candidateBargeInDuration = 0
        isReleasingBargeInAudio = false
    }

    private func scheduleBargeInConfirmation() {
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.isUserSpeaking else { return }
            await self.confirmBargeIn()
        }
    }

    private func confirmBargeIn() async {
        bargeInConfirmationTask = nil
        guard isUserSpeaking else { return }

        audioIO.interruptPlayback()
        guard isResponding else { return }

        isDiscardingCancelledResponse = true
        try? await sendJSON(["type": "response.cancel"])
        finishAssistantTranscript(interrupted: true)
    }

    private func enqueueAudio(_ data: Data) {
        let operation = enqueueMediaEvents([
            QwenRealtimeToolProtocol.audioAppendEvent(
                eventID: "event_\(UUID().uuidString)",
                audioData: data
            )
        ])
        let attemptID = startAttemptID
        Task { [weak self] in
            if case .failure(let error) = await operation.value {
                self?.fail(error, attemptID: attemptID)
            }
        }
    }

    /// A still image selected before speaking is replayed only after Qwen has
    /// detected real speech. This places the image inside the same audio
    /// timeline and VAD commit as the user's question. The latest still remains
    /// pinned for later follow-up questions until another visual source replaces it.
    private func replayPinnedStillImageForCurrentSpeech() {
        guard let imageData = pinnedStillImageData,
              !hasReplayedPinnedImageForCurrentSpeech else { return }
        hasReplayedPinnedImageForCurrentSpeech = true

        let operation = enqueueMediaEvents([
            QwenRealtimeToolProtocol.imageAppendEvent(
                eventID: "event_\(UUID().uuidString)_speech_image",
                imageData: imageData
            )
        ])
        let attemptID = startAttemptID
        Task { [weak self] in
            if case .failure(let error) = await operation.value {
                self?.fail(error, attemptID: attemptID)
            }
        }
    }

    /// Audio chunks and camera frames share one ordered task chain so frames
    /// cannot overtake the microphone data that Qwen requires first.
    private func enqueueMediaEvents(
        _ events: [[String: Any]]
    ) -> Task<Result<Void, Error>, Never> {
        let previous = mediaSendTask
        let attemptID = startAttemptID
        let operation = Task { [weak self] () -> Result<Void, Error> in
            await previous?.value
            guard !Task.isCancelled,
                  let self,
                  let attemptID,
                  self.isCurrentStartAttempt(attemptID),
                  self.state == .connected else {
                return .failure(URLError(.cancelled))
            }
            do {
                for event in events {
                    try await self.sendJSON(event)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        mediaSendTask = Task {
            _ = await operation.value
        }
        return operation
    }

    nonisolated static func sessionInstructions(
        systemPrompt: String,
        plantBinding: PlantConversationBinding,
        memoryContext: String = "",
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        [
            systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            """
            当前实时会话支持用户上传图片和共享摄像头画面。当前回合存在视觉输入时，直接观察实际画面并回答相关问题；不要因为“植物传感器”的角色设定而声称自己看不到图片，也不要把图片或画面问题错误地改成传感器工具查询。当前回合没有视觉输入时不要虚构画面。视觉观察与 BLE 传感器数据是两类独立信息，只有问题确实依赖温度、湿度、土壤 ADC、光照或历史记录时才调用工具。
            """,
            plantBinding.modelInstructions,
            memoryContext,
            PlantDataToolCatalog.usageInstructions,
            "当前本地时间：\(now.formatted(date: .abbreviated, time: .standard))（\(timeZone.identifier)）。"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private func sendSessionUpdate(
        _ configuration: QwenRealtimeConfiguration,
        plantBinding: PlantConversationBinding
    ) async throws {
        let memoryContext = (try? await memoryStore.promptContext()) ?? ""
        let instructions = Self.sessionInstructions(
            systemPrompt: configuration.systemPrompt,
            plantBinding: plantBinding,
            memoryContext: memoryContext
        )
        let tools = try QwenRealtimeToolProtocol.sessionTools(
            from: PlantDataToolCatalog.definitions
        )
        try await sendJSON(QwenRealtimeToolProtocol.sessionUpdateEvent(
            eventID: "event_\(UUID().uuidString)",
            voice: configuration.voice,
            instructions: instructions,
            tools: tools
        ))
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeConversationError.invalidServerMessage
        }
        try await webSocket.send(.string(text))
    }

    private func finishAssistantTranscript(interrupted: Bool) {
        guard !currentAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearCurrentAssistantTranscript()
            isResponding = false
            isWaitingForAssistantText = false
            return
        }
        let suffix = interrupted ? "（已打断）" : ""
        finishCurrentAssistantTranscript(text: currentAssistantText + suffix)
        isResponding = false
        isWaitingForAssistantText = false
    }

    private func prepareCurrentUserTranscript() {
        guard currentUserEntryID == nil else { return }
        currentUserEntryID = UUID()
        currentUserStartedAt = Date()
    }

    private func prepareCurrentAssistantTranscript() {
        guard currentAssistantEntryID == nil else { return }
        currentAssistantEntryID = UUID()
        currentAssistantStartedAt = Date()
    }

    private func finishCurrentUserTranscript(text: String) {
        prepareCurrentUserTranscript()
        finishTranscript(
            id: currentUserEntryID ?? UUID(),
            role: .user,
            text: text,
            createdAt: currentUserStartedAt ?? Date()
        )
        currentUserText = ""
        currentUserEntryID = nil
        currentUserStartedAt = nil
    }

    private func finishCurrentAssistantTranscript(text: String) {
        prepareCurrentAssistantTranscript()
        finishTranscript(
            id: currentAssistantEntryID ?? UUID(),
            role: .assistant,
            text: text,
            createdAt: currentAssistantStartedAt ?? Date(),
            toolInvocations: pendingAssistantToolInvocations
        )
        pendingAssistantToolInvocations.removeAll(keepingCapacity: true)
        clearCurrentAssistantTranscript()
    }

    private func clearCurrentAssistantTranscript() {
        currentAssistantText = ""
        currentAssistantEntryID = nil
        currentAssistantStartedAt = nil
    }

    private func finishPendingTranscripts() {
        if !currentUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentUserTranscript(text: currentUserText)
        }
        if !currentAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentAssistantTranscript(text: currentAssistantText)
        }
    }

    private func finishTranscript(
        id: UUID,
        role: ChatRole,
        text: String,
        createdAt: Date,
        toolInvocations: [ToolInvocation] = []
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let entry = RealtimeTranscriptEntry(
            id: id,
            role: role,
            text: value,
            createdAt: createdAt,
            toolInvocations: toolInvocations
        )
        entries.append(entry)
        enqueuePersistence(entry)
    }

    private func enqueuePersistence(_ entry: RealtimeTranscriptEntry) {
        let previous = persistenceTask
        let persistenceSessionID = currentPersistenceSessionID
        persistenceTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let activeConversation: AIConversation
                if let conversation = self.conversationsBySessionID[persistenceSessionID] {
                    activeConversation = conversation
                } else {
                    let titleSource: String
                    if entry.role == .user,
                       !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        titleSource = entry.text
                    } else if !entry.imageAttachments.isEmpty {
                        titleSource = "实时视觉对话"
                    } else {
                        titleSource = "实时语音对话"
                    }
                    let created = try await self.database.createConversation(
                        title: String(titleSource.replacingOccurrences(of: "\n", with: " ").prefix(28)),
                        kind: .realtime
                    )
                    self.conversationsBySessionID[persistenceSessionID] = created
                    activeConversation = created
                }
                try await self.database.saveChatMessage(ChatMessage(
                    id: entry.id,
                    conversationID: activeConversation.id,
                    role: entry.role,
                    content: entry.text,
                    createdAt: entry.createdAt,
                    imageAttachments: entry.imageAttachments,
                    toolInvocations: entry.toolInvocations
                ))
            } catch {
                // The live call must continue even if local transcript persistence fails.
            }
        }
    }

    private func executePendingToolCalls() async throws {
        let calls = pendingToolCalls
        pendingToolCalls.removeAll(keepingCapacity: true)
        guard !calls.isEmpty else { return }
        guard let toolExecutor else {
            throw RealtimeConversationError.missingPlantBinding
        }

        isWaitingForAssistantText = true
        var invocations: [ToolInvocation] = []
        for call in calls {
            let invocation = await toolExecutor.execute(call)
            invocations.append(invocation)
            try await sendJSON(QwenRealtimeToolProtocol.functionCallOutputEvent(
                eventID: "event_\(UUID().uuidString)",
                callID: call.id,
                output: invocation.resultJSON
            ))
        }
        pendingAssistantToolInvocations.append(contentsOf: invocations)
        try await sendJSON(QwenRealtimeToolProtocol.responseCreateEvent(
            eventID: "event_\(UUID().uuidString)"
        ))
    }

    private enum MicrophonePermissionResult {
        case alreadyGranted
        case newlyGranted
        case denied
    }

    private func requestMicrophonePermission() async -> MicrophonePermissionResult {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .alreadyGranted
        case .denied:
            return .denied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .newlyGranted : .denied
        @unknown default:
            return .denied
        }
    }

    private func waitForAudioSystemAfterFirstAuthorization(attemptID: UUID) async {
        for _ in 0..<60 where UIApplication.shared.applicationState != .active {
            guard isCurrentStartAttempt(attemptID) else { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        guard isCurrentStartAttempt(attemptID) else { return }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func isCurrentStartAttempt(_ attemptID: UUID) -> Bool {
        startAttemptID == attemptID
    }

    private func fail(_ error: Error, attemptID: UUID? = nil) {
        if let attemptID, !isCurrentStartAttempt(attemptID) {
            return
        }
        startAttemptID = nil
        finishPendingTranscripts()
        tearDown()
        state = .error(error.localizedDescription)
    }

    private func tearDown() {
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        audioStartupWatchdogTask?.cancel()
        audioStartupWatchdogTask = nil
        mediaSendTask?.cancel()
        mediaSendTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        audioIO.stop()
        voiceVisualDriver.reset()
        audioStarted = false
        resetPreConnectionAudio()
        microphoneChunkCount = 0
        pinnedStillImageData = nil
        hasReplayedPinnedImageForCurrentSpeech = false
        hasRetriedSilentAudioStart = false
        resetLocalBargeInDetection()
        isUserSpeaking = false
        isResponding = false
        isWaitingForAssistantText = false
        toolExecutor = nil
    }
}

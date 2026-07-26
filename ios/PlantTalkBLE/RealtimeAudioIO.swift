import AVFAudio
import Foundation
import Observation

enum VoiceAudioSource: Hashable, Sendable {
    case user
    case assistant
}

enum VoiceVisualAccentKind: Equatable, Sendable {
    case colorShift
    case strongPulse
    /// Fired once when the realtime model connects. Unlike the audio-driven
    /// accents this one scales the whole orb instead of folding a single mesh
    /// vertex, so a successful connection never looks like ordinary speech.
    case connectionEstablished
}

struct VoiceVisualAccent: Equatable, Sendable {
    let id: UUID
    let kind: VoiceVisualAccentKind
    let meshPointIndex: Int
    let offset: SIMD2<Float>
    let intensity: Double
    let startedAt: TimeInterval

    /// The connection pulse deliberately leaves the mesh untouched: a localized
    /// fold or highlight would read as another voice accent.
    var deformsMesh: Bool {
        kind != .connectionEstablished
    }
}

struct AudioLevelAnalyzer {
    static func levelDBFS(samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return -160 }
        var sumOfSquares = 0.0
        for index in 0..<count {
            let normalized = Double(samples[index]) / Double(Int16.max)
            sumOfSquares += normalized * normalized
        }
        let rms = sqrt(sumOfSquares / Double(count))
        return rms > 0 ? Float(20 * log10(rms)) : -160
    }

    static func levelDBFS(buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0,
              let channels = buffer.floatChannelData else {
            return -160
        }

        var sumOfSquares = 0.0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame])
                sumOfSquares += sample * sample
            }
        }
        let rms = sqrt(sumOfSquares / Double(frameCount * channelCount))
        return rms > 0 ? Float(20 * log10(rms)) : -160
    }
}

/// Converts dense audio-level frames into a quiet continuous response plus
/// deliberately sparse accent events suitable for an ambient interface.
@MainActor
@Observable
final class VoiceVisualDriver {
    private struct LevelEnvelope {
        var fastDBFS: Double?
        var slowDBFS: Double?
        var lastAudibleAt: TimeInterval?
    }

    private(set) var normalizedLevel = 0.0
    private(set) var accent: VoiceVisualAccent?

    private var envelopes: [VoiceAudioSource: LevelEnvelope] = [:]
    private var lastColorShiftAt = -Double.infinity
    private var lastStrongPulseAt = -Double.infinity
    private var strongPulseTimes: [TimeInterval] = []
    private var lastMeshPointIndex: Int?
    private let randomUnit: () -> Double

    init(randomUnit: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.randomUnit = randomUnit
    }

    func ingest(
        source: VoiceAudioSource,
        levelDBFS: Float,
        at date: Date = .now
    ) {
        let now = date.timeIntervalSinceReferenceDate
        let level = min(-3, max(-80, Double(levelDBFS)))
        var envelope = envelopes[source] ?? LevelEnvelope()

        guard let previousFast = envelope.fastDBFS,
              let previousSlow = envelope.slowDBFS else {
            envelope.fastDBFS = level
            envelope.slowDBFS = level
            if level > -48 {
                envelope.lastAudibleAt = now
            }
            envelopes[source] = envelope
            updateDisplayLevel(level)
            return
        }

        let fast = previousFast * 0.55 + level * 0.45
        let slow = previousSlow * 0.93 + level * 0.07
        envelope.fastDBFS = fast
        envelope.slowDBFS = slow

        if let lastAudibleAt = envelope.lastAudibleAt,
           now - lastAudibleAt >= 1.2 {
            strongPulseTimes.removeAll()
        }
        if level > -48 {
            envelope.lastAudibleAt = now
        }
        envelopes[source] = envelope
        updateDisplayLevel(level)

        guard level > -48 else { return }
        let onset = fast - slow
        let strongThreshold = source == .assistant ? 4.2 : 5.5
        let colorShiftThreshold = source == .assistant ? 2.0 : 2.8
        strongPulseTimes.removeAll { now - $0 >= 4 }

        if onset >= strongThreshold,
           now - lastStrongPulseAt >= 0.65,
           strongPulseTimes.count < 3 {
            let intensity = min(1, max(0, (onset - strongThreshold) / 8))
            let probability = min(0.82, 0.3 + intensity * 0.52)
            if randomUnit() <= probability {
                emitAccent(kind: .strongPulse, intensity: intensity, now: now)
                lastStrongPulseAt = now
                lastColorShiftAt = now
                strongPulseTimes.append(now)
                return
            }
        }

        if onset >= colorShiftThreshold, now - lastColorShiftAt >= 0.35 {
            let intensity = min(1, max(0, (onset - colorShiftThreshold) / 6))
            let probability = min(0.72, 0.24 + intensity * 0.48)
            if randomUnit() <= probability {
                emitAccent(kind: .colorShift, intensity: intensity, now: now)
                lastColorShiftAt = now
            }
        }
    }

    /// Signals a successful realtime connection. Emitted directly rather than
    /// through the level pipeline so it is never suppressed by the accent
    /// cooldowns, and it also arms those cooldowns so the first words spoken
    /// after connecting do not stack a second pulse on top of this one.
    func emitConnectionEstablishedPulse(at date: Date = .now) {
        let now = date.timeIntervalSinceReferenceDate
        lastStrongPulseAt = now
        lastColorShiftAt = now
        accent = VoiceVisualAccent(
            id: UUID(),
            kind: .connectionEstablished,
            meshPointIndex: 5,
            offset: .zero,
            intensity: 1,
            startedAt: now
        )
    }

    func reset() {
        normalizedLevel = 0
        accent = nil
        envelopes.removeAll()
        lastColorShiftAt = -.infinity
        lastStrongPulseAt = -.infinity
        strongPulseTimes.removeAll()
        lastMeshPointIndex = nil
    }

    private func updateDisplayLevel(_ levelDBFS: Double) {
        let target = min(1, max(0, (levelDBFS + 55) / 43))
        normalizedLevel = normalizedLevel * 0.78 + target * 0.22
    }

    private func emitAccent(
        kind: VoiceVisualAccentKind,
        intensity: Double,
        now: TimeInterval
    ) {
        let internalPointIndices = [5, 6, 9, 10]
        var position = min(
            internalPointIndices.count - 1,
            Int(randomUnit() * Double(internalPointIndices.count))
        )
        if internalPointIndices[position] == lastMeshPointIndex {
            position = (position + 1) % internalPointIndices.count
        }
        let pointIndex = internalPointIndices[position]
        lastMeshPointIndex = pointIndex

        let angle = randomUnit() * .pi * 2
        let baseAmplitude = kind == .strongPulse ? 0.06 : 0.03
        let amplitudeRange = kind == .strongPulse ? 0.035 : 0.02
        let amplitude = baseAmplitude + amplitudeRange * intensity
        accent = VoiceVisualAccent(
            id: UUID(),
            kind: kind,
            meshPointIndex: pointIndex,
            offset: SIMD2(
                Float(cos(angle) * amplitude),
                Float(sin(angle) * amplitude)
            ),
            intensity: intensity,
            startedAt: now
        )
    }
}

enum RealtimeAudioError: LocalizedError {
    case microphoneUnavailable
    case unsupportedAudioFormat
    case voiceProcessingUnavailable(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "当前设备没有可用的麦克风输入。"
        case .unsupportedAudioFormat:
            "无法创建实时对话所需的 PCM 音频格式。"
        case .voiceProcessingUnavailable(let message):
            "无法启用语音回声消除：\(message)"
        case .conversionFailed(let message):
            "麦克风音频转换失败：\(message)"
        }
    }
}

struct RealtimeMicrophoneChunk: Sendable {
    let data: Data
    let levelDBFS: Float
    let isResponsePlaybackActive: Bool
    let responseLevelDBFS: Float
}

/// Owns the full-duplex audio graph used by Qwen Realtime. The microphone is
/// converted to mono PCM16 at 16 kHz; response audio is PCM16 at 24 kHz.
///
/// Every `AVAudioSession` / `AVAudioEngine` call runs on `engineQueue`. Session
/// activation, voice-processing installation and engine start each block for
/// tens to hundreds of milliseconds; running them on the main actor froze the
/// home orb's `TimelineView` for the whole connection handshake. The queue is
/// serial, so node access stays ordered exactly as the callers issued it.
final class RealtimeAudioIO: @unchecked Sendable {
    private let engineQueue = DispatchQueue(
        label: "com.example.PlantTalkBLE.realtime-audio",
        qos: .userInitiated
    )
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )
    private var hasInputTap = false
    private var hasResponseLevelTap = false
    private let playbackStateLock = NSLock()
    private var scheduledResponseBufferCount = 0
    private var responseLevelDBFS: Float = -160
    private var playbackGeneration = 0

    init() {
        engine.attach(player)
    }

    /// Activates the record/playback session before the realtime socket begins.
    /// This is intentionally separate from starting the engine because a first-run
    /// microphone permission alert can temporarily disturb the audio-session lifecycle.
    func prepareForRealtimeConversation() async throws {
        try await onEngineQueue { [self] in
            try activateSessionOnEngineQueue()
        }
    }

    private func activateSessionOnEngineQueue() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        // notifyOthersOnDeactivation is only valid while deactivating a session.
        try session.setActive(true)
    }

    func start(
        onMicrophonePCM: @escaping @Sendable (RealtimeMicrophoneChunk) -> Void,
        onResponseLevelDBFS: @escaping @Sendable (Float) -> Void
    ) async throws {
        try await onEngineQueue { [self] in
            try startOnEngineQueue(
                onMicrophonePCM: onMicrophonePCM,
                onResponseLevelDBFS: onResponseLevelDBFS
            )
        }
    }

    private func startOnEngineQueue(
        onMicrophonePCM: @escaping @Sendable (RealtimeMicrophoneChunk) -> Void,
        onResponseLevelDBFS: @escaping @Sendable (Float) -> Void
    ) throws {
        guard let inputFormat, let outputFormat else {
            throw RealtimeAudioError.unsupportedAudioFormat
        }

        try activateSessionOnEngineQueue()

        let inputNode = engine.inputNode
        do {
            // Voice-processing I/O removes this engine's speaker output from
            // the microphone signal while preserving near-end speech for barge-in.
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw RealtimeAudioError.voiceProcessingUnavailable(error.localizedDescription)
        }
        guard inputNode.isVoiceProcessingEnabled,
              engine.outputNode.isVoiceProcessingEnabled else {
            throw RealtimeAudioError.voiceProcessingUnavailable("当前音频路由不支持 Voice Processing I/O。")
        }

        // Enabling voice processing can change the I/O format, so read it only
        // after the voice-processing audio unit has been installed.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RealtimeAudioError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: hardwareFormat, to: inputFormat) else {
            throw RealtimeAudioError.unsupportedAudioFormat
        }

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: nil
        ) { [weak self] buffer, _ in
            guard let self,
                  self.responsePlaybackState().isActive else { return }
            let levelDBFS = AudioLevelAnalyzer.levelDBFS(buffer: buffer)
            self.updateResponsePlaybackLevel(levelDBFS)
            onResponseLevelDBFS(levelDBFS)
        }
        hasResponseLevelTap = true

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: hardwareFormat) { buffer, _ in
            let ratio = inputFormat.sampleRate / hardwareFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity) else {
                return
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
                if suppliedInput {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outputStatus.pointee = .haveData
                return buffer
            }

            guard status != .error,
                  conversionError == nil,
                  converted.frameLength > 0,
                  let samples = converted.int16ChannelData?.pointee else {
                return
            }
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let playbackState = self.responsePlaybackState()
            onMicrophonePCM(RealtimeMicrophoneChunk(
                data: Data(bytes: samples, count: byteCount),
                levelDBFS: AudioLevelAnalyzer.levelDBFS(
                    samples: samples,
                    count: Int(converted.frameLength)
                ),
                isResponsePlaybackActive: playbackState.isActive,
                responseLevelDBFS: playbackState.levelDBFS
            ))
        }
        hasInputTap = true

        engine.prepare()
        try engine.start()
        player.play()
    }

    /// Fire-and-forget: the caller never waits for the scheduling hop, and the
    /// serial queue preserves the order in which chunks arrived.
    func playResponsePCM(_ data: Data) {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size),
              let outputFormat else {
            return
        }
        engineQueue.async { [self] in
            let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: frameCount
            ), let samples = buffer.int16ChannelData?.pointee else {
                return
            }
            buffer.frameLength = frameCount
            data.copyBytes(to: UnsafeMutableRawBufferPointer(
                start: samples,
                count: data.count
            ))
            let levelDBFS = AudioLevelAnalyzer.levelDBFS(
                samples: samples,
                count: Int(frameCount)
            )
            guard engine.isRunning else { return }
            let generation = markResponseBufferScheduled(levelDBFS: levelDBFS)
            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.markResponseBufferFinished(generation: generation)
            }
            if !player.isPlaying {
                player.play()
            }
        }
    }

    func interruptPlayback() {
        // Invalidate the generation synchronously so microphone frames stop
        // being treated as echo the instant a barge-in is confirmed.
        playbackStateLock.withLock {
            playbackGeneration += 1
            scheduledResponseBufferCount = 0
            responseLevelDBFS = -160
        }
        engineQueue.async { [self] in
            guard engine.isRunning else { return }
            player.stop()
            player.play()
        }
    }

    func stop() {
        playbackStateLock.withLock {
            playbackGeneration += 1
            scheduledResponseBufferCount = 0
            responseLevelDBFS = -160
        }
        engineQueue.async { [self] in
            if hasInputTap {
                engine.inputNode.removeTap(onBus: 0)
                hasInputTap = false
            }
            if hasResponseLevelTap {
                engine.mainMixerNode.removeTap(onBus: 0)
                hasResponseLevelTap = false
            }
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    /// Runs a blocking audio-graph operation on the serial engine queue without
    /// blocking the caller's thread (in practice: the main actor).
    private func onEngineQueue(
        _ work: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func markResponseBufferScheduled(levelDBFS: Float) -> Int {
        playbackStateLock.withLock {
            scheduledResponseBufferCount += 1
            responseLevelDBFS = levelDBFS
            return playbackGeneration
        }
    }

    private func markResponseBufferFinished(generation: Int) {
        playbackStateLock.withLock {
            guard generation == playbackGeneration else { return }
            scheduledResponseBufferCount = max(0, scheduledResponseBufferCount - 1)
            if scheduledResponseBufferCount == 0 {
                responseLevelDBFS = -160
            }
        }
    }

    private func updateResponsePlaybackLevel(_ levelDBFS: Float) {
        playbackStateLock.withLock {
            guard scheduledResponseBufferCount > 0 else { return }
            responseLevelDBFS = levelDBFS
        }
    }

    private func responsePlaybackState() -> (isActive: Bool, levelDBFS: Float) {
        playbackStateLock.withLock {
            (scheduledResponseBufferCount > 0, responseLevelDBFS)
        }
    }

}

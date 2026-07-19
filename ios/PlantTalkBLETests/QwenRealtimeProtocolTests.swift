import AVFAudio
import Foundation
import XCTest
@testable import PlantTalkBLE

final class QwenRealtimeProtocolTests: XCTestCase {
    func testAudioLevelAnalyzerReportsSilence() {
        let samples = [Int16](repeating: 0, count: 1_600)
        let level = samples.withUnsafeBufferPointer { buffer in
            AudioLevelAnalyzer.levelDBFS(
                samples: buffer.baseAddress!,
                count: buffer.count
            )
        }
        XCTAssertEqual(level, -160)
    }

    func testAudioLevelAnalyzerMeasuresHalfScaleSineWave() {
        let samples = (0..<1_600).map { index in
            let phase = Double(index) / 16_000 * 220 * .pi * 2
            return Int16(sin(phase) * Double(Int16.max) * 0.5)
        }
        let level = samples.withUnsafeBufferPointer { buffer in
            AudioLevelAnalyzer.levelDBFS(
                samples: buffer.baseAddress!,
                count: buffer.count
            )
        }
        XCTAssertEqual(level, -9.03, accuracy: 0.15)
    }

    func testAudioLevelAnalyzerMeasuresFloatMixerBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_800
        ))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<Int(buffer.frameLength) {
            let phase = Double(index) / 48_000 * 220 * .pi * 2
            samples[index] = Float(sin(phase) * 0.5)
        }

        XCTAssertEqual(
            AudioLevelAnalyzer.levelDBFS(buffer: buffer),
            -9.03,
            accuracy: 0.15
        )
    }

    @MainActor
    func testAssistantUsesCompressedAudioSensitivity() throws {
        let driver = VoiceVisualDriver(randomUnit: { 0 })
        let start = Date(timeIntervalSinceReferenceDate: 900)

        driver.ingest(source: .assistant, levelDBFS: -35, at: start)
        driver.ingest(
            source: .assistant,
            levelDBFS: -23,
            at: start.addingTimeInterval(0.05)
        )

        XCTAssertEqual(try XCTUnwrap(driver.accent).kind, .strongPulse)
    }

    @MainActor
    func testVoiceVisualDriverTriggersOnSuddenRiseButHonorsCooldown() throws {
        let driver = VoiceVisualDriver(randomUnit: { 0 })
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        driver.ingest(source: .user, levelDBFS: -52, at: start)
        driver.ingest(
            source: .user,
            levelDBFS: -12,
            at: start.addingTimeInterval(0.08)
        )
        let firstAccent = try XCTUnwrap(driver.accent)
        XCTAssertEqual(firstAccent.kind, .strongPulse)
        XCTAssertTrue([5, 6, 9, 10].contains(firstAccent.meshPointIndex))

        driver.ingest(
            source: .user,
            levelDBFS: -8,
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(driver.accent?.id, firstAccent.id)
    }

    @MainActor
    func testVoiceVisualDriverDoesNotReactToSteadyBackgroundLevel() {
        let driver = VoiceVisualDriver(randomUnit: { 0 })
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        for index in 0..<20 {
            driver.ingest(
                source: .assistant,
                levelDBFS: -38,
                at: start.addingTimeInterval(Double(index) * 0.08)
            )
        }

        XCTAssertNil(driver.accent)
    }

    @MainActor
    func testVoiceVisualDriverLimitsStrongPulsesWithinFourSeconds() {
        let driver = VoiceVisualDriver(randomUnit: { 0 })
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var strongPulseCount = 0
        var lastAccentID: UUID?

        driver.ingest(source: .user, levelDBFS: -56, at: start)
        for burst in 0..<4 {
            let burstStart = Double(burst) * 0.78
            for step in 0..<6 {
                driver.ingest(
                    source: .user,
                    levelDBFS: -58,
                    at: start.addingTimeInterval(burstStart + Double(step) * 0.1)
                )
            }
            driver.ingest(
                source: .user,
                levelDBFS: -10,
                at: start.addingTimeInterval(burstStart + 0.68)
            )
            if driver.accent?.id != lastAccentID,
               driver.accent?.kind == .strongPulse {
                strongPulseCount += 1
            }
            lastAccentID = driver.accent?.id
        }

        XCTAssertEqual(strongPulseCount, 3)
    }

    func testPreparingAudioKeepsConversationActive() {
        XCTAssertTrue(RealtimeConversationState.preparingAudio.isActive)
        XCTAssertEqual(
            RealtimeConversationState.preparingAudio.title,
            "正在准备麦克风…"
        )
    }

    func testEndpointAddsModelAndPreservesExistingQuery() throws {
        let baseURL = try XCTUnwrap(URL(string: "wss://example.com/realtime?workspace=plant"))
        let endpoint = QwenRealtimeConversation.endpointURL(
            baseURL: baseURL,
            model: "qwen3.5-omni-flash-realtime"
        )
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(values["workspace"], "plant")
        XCTAssertEqual(values["model"], "qwen3.5-omni-flash-realtime")
    }

    func testDecodesAudioAndTranscriptEvents() throws {
        let created = try JSONDecoder().decode(
            QwenRealtimeServerEvent.self,
            from: Data(#"{"type":"session.created"}"#.utf8)
        )
        let audio = try JSONDecoder().decode(
            QwenRealtimeServerEvent.self,
            from: Data(#"{"type":"response.audio.delta","delta":"AQID"}"#.utf8)
        )
        let transcript = try JSONDecoder().decode(
            QwenRealtimeServerEvent.self,
            from: Data(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好"}"#.utf8)
        )

        XCTAssertEqual(created.type, "session.created")
        XCTAssertEqual(audio.type, "response.audio.delta")
        XCTAssertEqual(audio.delta, "AQID")
        XCTAssertEqual(transcript.transcript, "你好")
    }

    func testFunctionCallCompletionBecomesFunctionOutputThenResponseCreate() throws {
        let completedCall = try JSONDecoder().decode(
            QwenRealtimeServerEvent.self,
            from: Data(#"""
            {
              "type": "response.function_call_arguments.done",
              "name": "get_sensor_summary",
              "call_id": "call_sensor_summary_1",
              "arguments": "{\"period\":\"today\",\"metrics\":[\"temperature\"]}"
            }
            """#.utf8)
        )
        let call = try QwenRealtimeToolProtocol.toolCall(from: completedCall)
        let functionOutput = QwenRealtimeToolProtocol.functionCallOutputEvent(
            eventID: "event_output_1",
            callID: call.id,
            output: #"{"status":"ok","sample_count":12}"#
        )
        let responseCreate = QwenRealtimeToolProtocol.responseCreateEvent(
            eventID: "event_response_1"
        )

        XCTAssertEqual(
            [functionOutput["type"] as? String, responseCreate["type"] as? String],
            ["conversation.item.create", "response.create"]
        )
        let item = try XCTUnwrap(functionOutput["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_sensor_summary_1")
        XCTAssertEqual(item["output"] as? String, #"{"status":"ok","sample_count":12}"#)
        XCTAssertNil(responseCreate["response"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: functionOutput))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: responseCreate))
    }

    func testFunctionCallCompletionRequiresProtocolFields() throws {
        let missingCallID = try JSONDecoder().decode(
            QwenRealtimeServerEvent.self,
            from: Data(#"""
            {
              "type": "response.function_call_arguments.done",
              "name": "get_current_sensor_reading",
              "arguments": "{}"
            }
            """#.utf8)
        )

        XCTAssertThrowsError(try QwenRealtimeToolProtocol.toolCall(from: missingCallID))
    }

    func testHistoryMessagesUseRoleSpecificRealtimeContentTypes() throws {
        let conversationID = UUID()
        let userEvent = try XCTUnwrap(QwenRealtimeToolProtocol.historyMessageEvent(
            eventID: "event_history_user",
            message: ChatMessage(
                id: UUID(),
                conversationID: conversationID,
                role: .user,
                content: "之前土壤有点干",
                createdAt: Date()
            )
        ))
        let assistantEvent = try XCTUnwrap(QwenRealtimeToolProtocol.historyMessageEvent(
            eventID: "event_history_assistant",
            message: ChatMessage(
                id: UUID(),
                conversationID: conversationID,
                role: .assistant,
                content: "建议补充少量水分",
                createdAt: Date()
            )
        ))

        let userItem = try XCTUnwrap(userEvent["item"] as? [String: Any])
        let assistantItem = try XCTUnwrap(assistantEvent["item"] as? [String: Any])
        let userContent = try XCTUnwrap((userItem["content"] as? [[String: Any]])?.first)
        let assistantContent = try XCTUnwrap(
            (assistantItem["content"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(userEvent["type"] as? String, "conversation.item.create")
        XCTAssertEqual(userItem["role"] as? String, "user")
        XCTAssertEqual(userContent["type"] as? String, "input_text")
        XCTAssertEqual(userContent["text"] as? String, "之前土壤有点干")
        XCTAssertEqual(assistantItem["role"] as? String, "assistant")
        XCTAssertEqual(assistantContent["type"] as? String, "output_text")
        XCTAssertEqual(assistantContent["text"] as? String, "建议补充少量水分")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: userEvent))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: assistantEvent))
    }

    func testSystemMessagesAreNotInjectedAsConversationHistory() {
        let event = QwenRealtimeToolProtocol.historyMessageEvent(
            eventID: "event_history_system",
            message: ChatMessage(
                id: UUID(),
                conversationID: UUID(),
                role: .system,
                content: "系统指令",
                createdAt: Date()
            )
        )

        XCTAssertNil(event)
    }

    func testSessionUpdateUsesQwenNestedToolSchemaWithoutUnsupportedToolChoice() throws {
        let tools = try QwenRealtimeToolProtocol.sessionTools(
            from: PlantDataToolCatalog.definitions
        )
        let event = QwenRealtimeToolProtocol.sessionUpdateEvent(
            eventID: "event_session_1",
            voice: "Tina",
            instructions: "只在需要真实数据时调用工具。",
            tools: tools
        )

        XCTAssertEqual(event["type"] as? String, "session.update")
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let encodedTools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        let summaryTool = try XCTUnwrap(encodedTools.first { tool in
            let function = tool["function"] as? [String: Any]
            return function?["name"] as? String == "get_sensor_summary"
        })
        let function = try XCTUnwrap(summaryTool["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let immediateTool = try XCTUnwrap(encodedTools.first { tool in
            let function = tool["function"] as? [String: Any]
            return function?["name"] as? String == "refresh_current_sensor_reading"
        })
        let immediateFunction = try XCTUnwrap(immediateTool["function"] as? [String: Any])

        XCTAssertEqual(summaryTool["type"] as? String, "function")
        XCTAssertEqual(function["name"] as? String, "get_sensor_summary")
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(immediateFunction["name"] as? String, "refresh_current_sensor_reading")
        XCTAssertNil(session["tool_choice"])
        XCTAssertNil(session["parallel_tool_calls"])
    }

    func testRealtimeInstructionsCarryTheBoundPlantID() {
        let instructions = QwenRealtimeConversation.sessionInstructions(
            systemPrompt: "你是一株植物。",
            plantBinding: .bound(deviceID: "ESP32-CURRENT", source: .savedCurrentPlant),
            memoryContext: "<long_term_memory>用户希望被称为小凡</long_term_memory>",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        XCTAssertTrue(instructions.contains("ESP32-CURRENT"))
        XCTAssertTrue(instructions.contains("不要要求用户重复说明"))
        XCTAssertTrue(instructions.contains("用户希望被称为小凡"))
        XCTAssertTrue(instructions.contains("get_sensor_summary"))
    }

    func testReplacingExistingModelDoesNotDuplicateQueryItem() throws {
        let baseURL = try XCTUnwrap(URL(string: "wss://example.com/realtime?model=old"))
        let endpoint = QwenRealtimeConversation.endpointURL(baseURL: baseURL, model: "new")
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.filter { $0.name == "model" }.count, 1)
        XCTAssertEqual(components.queryItems?.first { $0.name == "model" }?.value, "new")
    }
}

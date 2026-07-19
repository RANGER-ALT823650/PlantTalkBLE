import Foundation
import XCTest
@testable import PlantTalkBLE

final class OpenAICompatibleClientTests: XCTestCase {
    func testEncodesImageMessageAsMultimodalContentParts() throws {
        let message = AIRequestMessage(
            role: .user,
            content: "这株植物怎么了？",
            imageDataURLs: ["data:image/jpeg;base64,AQID"]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
                as? [String: Any]
        )
        XCTAssertEqual(object["role"] as? String, "user")
        let parts = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "这株植物怎么了？")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,AQID")
        XCTAssertEqual(imageURL["detail"] as? String, "auto")
    }

    func testEncodesImageOnlyMessageWithoutEmptyTextPart() throws {
        let message = AIRequestMessage(
            role: .user,
            content: "",
            imageDataURLs: ["data:image/jpeg;base64,AQID"]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
                as? [String: Any]
        )
        let parts = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
    }

    func testRecognizesServerRejectionOfImageInput() {
        XCTAssertTrue(OpenAICompatibleClient.indicatesUnsupportedImageInput(
            statusCode: 400,
            message: "This model does not support image input."
        ))
        XCTAssertTrue(OpenAICompatibleClient.indicatesUnsupportedImageInput(
            statusCode: 422,
            message: "当前模型不支持图片输入"
        ))
    }

    func testDoesNotMisclassifyUnrelatedServerErrorsAsImageCapabilityErrors() {
        XCTAssertFalse(OpenAICompatibleClient.indicatesUnsupportedImageInput(
            statusCode: 401,
            message: "This model does not support image input."
        ))
        XCTAssertFalse(OpenAICompatibleClient.indicatesUnsupportedImageInput(
            statusCode: 400,
            message: "Invalid tool schema."
        ))
        XCTAssertFalse(OpenAICompatibleClient.indicatesUnsupportedImageInput(
            statusCode: 400,
            message: "Image payload is too large."
        ))
    }

    func testBuildsChatCompletionsURLFromVersionedBaseURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/v1"))
        XCTAssertEqual(
            OpenAICompatibleClient.completionURL(baseURL: baseURL).absoluteString,
            "https://example.com/v1/chat/completions"
        )
    }

    func testKeepsCompleteChatCompletionsURL() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/openai/v1/chat/completions"))
        XCTAssertEqual(OpenAICompatibleClient.completionURL(baseURL: endpoint), endpoint)
    }

    /// Verifies the complete provider-neutral protocol loop without making a
    /// network request. In particular, DeepSeek-compatible SSE streams may
    /// split one function's JSON arguments across multiple deltas.
    @MainActor
    func testAdapterExecutesFragmentedToolCallAndUsesResultForFinalReply() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 13,
            hour: 12
        )))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let firstReadingDate = try XCTUnwrap(
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)
        )

        let database = try PlantDatabase(path: temporaryDatabasePath())
        _ = try await database.saveHistoryBatch(
            [
                HistoryReading(
                    sequence: 1,
                    recordedAt: firstReadingDate,
                    timestampEstimated: false,
                    soilRaw: 1_200,
                    temperature: 22,
                    humidity: 55,
                    lightLux: 100
                ),
                HistoryReading(
                    sequence: 2,
                    recordedAt: firstReadingDate.addingTimeInterval(300),
                    timestampEstimated: false,
                    soilRaw: 1_300,
                    temperature: 26,
                    humidity: 56,
                    lightLux: 110
                )
            ],
            deviceID: "adapter-test-device",
            acknowledgedThrough: 2
        )

        let executor = PlantDataToolExecutor(
            database: database,
            deviceIDProvider: { "adapter-test-device" },
            currentReadingProvider: { nil },
            nowProvider: { now },
            calendar: calendar
        )
        let recorder = RequestRecorder()
        let client = OpenAICompatibleClient { _, messages, tools in
            AsyncThrowingStream { continuation in
                Task {
                    await recorder.append(messages: messages, tools: tools)

                    if messages.contains(where: { $0.role == .tool }) {
                        continuation.yield(.textDelta("昨天的温度平均为 24°C。"))
                        continuation.yield(.finished(reason: "stop"))
                    } else {
                        continuation.yield(.toolCallDelta(AIModelToolCallDelta(
                            index: 0,
                            id: "call_summary",
                            type: "function",
                            name: "get_sensor_summary",
                            arguments: #"{"period":"yester"#
                        )))
                        continuation.yield(.toolCallDelta(AIModelToolCallDelta(
                            index: 0,
                            id: nil,
                            type: nil,
                            name: nil,
                            arguments: #"day","metrics":["temperature"]}"#
                        )))
                        continuation.yield(.finished(reason: "tool_calls"))
                    }
                    continuation.finish()
                }
            }
        }

        var textDeltas: [String] = []
        var toolCallRounds = 0
        let invocations = try await TextModelAdapter(client: client).respond(
            configuration: testConfiguration,
            initialMessages: [
                AIRequestMessage(role: .system, content: "测试系统提示词"),
                AIRequestMessage(role: .user, content: "昨天温度平均多少？")
            ],
            executor: executor,
            onTextDelta: { textDeltas.append($0) },
            onToolCallRound: { toolCallRounds += 1 }
        )

        XCTAssertEqual(textDeltas, ["昨天的温度平均为 24°C。"])
        XCTAssertEqual(toolCallRounds, 1)
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.providerCallID, "call_summary")
        XCTAssertEqual(invocations.first?.toolName, "get_sensor_summary")
        let invocation = try XCTUnwrap(invocations.first)
        let invocationArguments = try jsonObject(invocation.argumentsJSON)
        XCTAssertEqual(invocationArguments["period"] as? String, "yesterday")
        let invocationMetrics = try XCTUnwrap(invocationArguments["metrics"] as? [String])
        XCTAssertEqual(invocationMetrics, ["temperature"])
        let invocationResult = try jsonObject(invocation.resultJSON)
        XCTAssertEqual(invocationResult["sample_count"] as? Int, 2)
        let summaryMetrics = try XCTUnwrap(invocationResult["metrics"] as? [String: Any])
        let temperatureMetrics = try XCTUnwrap(summaryMetrics["temperature"] as? [String: Any])
        XCTAssertEqual(temperatureMetrics["average"] as? Double, 24)

        let turns = await recorder.turns
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map(\.toolNames), [
            PlantDataToolCatalog.definitions.map(\.function.name),
            PlantDataToolCatalog.definitions.map(\.function.name)
        ])
        XCTAssertEqual(turns[0].messages.map(\.role), [.system, .user])

        let toolCallingAssistant = try XCTUnwrap(
            turns[1].messages.first(where: { $0.role == .assistant })
        )
        XCTAssertEqual(toolCallingAssistant.toolCalls?.map(\.id), ["call_summary"])
        XCTAssertEqual(toolCallingAssistant.toolCalls?.first?.function.arguments,
                       #"{"period":"yesterday","metrics":["temperature"]}"#)

        let toolResult = try XCTUnwrap(turns[1].messages.first(where: { $0.role == .tool }))
        XCTAssertEqual(toolResult.toolCallID, "call_summary")
        let toolResultJSON = try jsonObject(try XCTUnwrap(toolResult.content))
        XCTAssertEqual(toolResultJSON["sample_count"] as? Int, 2)
        let toolMetrics = try XCTUnwrap(toolResultJSON["metrics"] as? [String: Any])
        let toolTemperature = try XCTUnwrap(toolMetrics["temperature"] as? [String: Any])
        XCTAssertEqual(toolTemperature["average"] as? Double, 24)
    }

    private var testConfiguration: AIConfiguration {
        AIConfiguration(
            baseURL: URL(string: "https://example.com/v1")!,
            model: "offline-test-model",
            systemPrompt: "",
            apiKey: "not-used"
        )
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}

private actor RequestRecorder {
    struct Turn: Sendable {
        let messages: [AIRequestMessage]
        let toolNames: [String]
    }

    private(set) var turns: [Turn] = []

    func append(messages: [AIRequestMessage], tools: [AIModelToolDefinition]) {
        turns.append(Turn(
            messages: messages,
            toolNames: tools.map(\.function.name)
        ))
    }
}

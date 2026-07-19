import Foundation

enum AIRequestRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// A provider-neutral chat message used only on the wire. Tool-call protocol
/// messages are intentionally kept separate from user-visible `ChatMessage`s.
struct AIRequestMessage: Encodable, Equatable, Sendable {
    let role: AIRequestRole
    let content: String?
    let imageDataURLs: [String]
    let toolCalls: [AIModelToolCall]?
    let toolCallID: String?

    init(
        role: AIRequestRole,
        content: String? = nil,
        imageDataURLs: [String] = [],
        toolCalls: [AIModelToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(
        role: ChatRole,
        content: String,
        imageDataURLs: [String] = []
    ) {
        switch role {
        case .system: self.role = .system
        case .user: self.role = .user
        case .assistant: self.role = .assistant
        }
        self.content = content
        self.imageDataURLs = imageDataURLs
        toolCalls = nil
        toolCallID = nil
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if imageDataURLs.isEmpty {
            try container.encodeIfPresent(content, forKey: .content)
        } else {
            var contentContainer = container.nestedUnkeyedContainer(forKey: .content)
            if let content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try contentContainer.encode(AIRequestContentPart.text(content))
            }
            for dataURL in imageDataURLs {
                try contentContainer.encode(AIRequestContentPart.imageURL(dataURL))
            }
        }

        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

private enum AIRequestContentPart: Encodable {
    case text(String)
    case imageURL(String)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    enum ImageURLCodingKeys: String, CodingKey {
        case url, detail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let dataURL):
            try container.encode("image_url", forKey: .type)
            var imageContainer = container.nestedContainer(
                keyedBy: ImageURLCodingKeys.self,
                forKey: .imageURL
            )
            try imageContainer.encode(dataURL, forKey: .url)
            try imageContainer.encode("auto", forKey: .detail)
        }
    }
}

struct TextModelTurn: Equatable, Sendable {
    let content: String
    let toolCalls: [AIModelToolCall]
}

enum TextModelStreamEvent: Sendable {
    case textDelta(String)
    case toolCallDelta(AIModelToolCallDelta)
    case finished(reason: String?)
}

struct AIModelToolCallDelta: Equatable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let name: String?
    let arguments: String?
}

/// OpenAI-compatible transport for DeepSeek, OpenAI and other text providers.
/// It only translates HTTP/SSE; provider-independent tool policy lives in
/// `TextModelAdapter` and data access lives in `PlantDataToolExecutor`.
struct OpenAICompatibleClient: Sendable {
    var streamTurn: @Sendable (
        _ configuration: AIConfiguration,
        _ messages: [AIRequestMessage],
        _ tools: [AIModelToolDefinition]
    ) -> AsyncThrowingStream<TextModelStreamEvent, Error>

    static func live(session: URLSession = .shared) -> OpenAICompatibleClient {
        OpenAICompatibleClient { configuration, messages, tools in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let containsImageInput = messages.contains {
                            !$0.imageDataURLs.isEmpty
                        }
                        var request = URLRequest(url: completionURL(baseURL: configuration.baseURL))
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
                            model: configuration.model,
                            messages: messages,
                            stream: true,
                            tools: tools,
                            toolChoice: tools.isEmpty ? nil : "auto"
                        ))

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw AIClientError.invalidResponse
                        }
                        guard (200..<300).contains(httpResponse.statusCode) else {
                            var body = Data()
                            for try await byte in bytes {
                                body.append(byte)
                                if body.count >= 65_536 { break }
                            }
                            let message = serverErrorMessage(from: body)
                            if containsImageInput,
                               indicatesUnsupportedImageInput(
                                   statusCode: httpResponse.statusCode,
                                   message: message
                               ) {
                                throw AIClientError.unsupportedImageInput(
                                    model: configuration.model
                                )
                            }
                            throw AIClientError.http(
                                statusCode: httpResponse.statusCode,
                                message: message
                            )
                        }

                        for try await rawLine in bytes.lines {
                            try Task.checkCancellation()
                            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8) else { continue }

                            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                            if let message = chunk.error?.message {
                                if containsImageInput,
                                   indicatesUnsupportedImageInput(message: message) {
                                    throw AIClientError.unsupportedImageInput(
                                        model: configuration.model
                                    )
                                }
                                throw AIClientError.server(message)
                            }
                            for choice in chunk.choices {
                                if let content = choice.delta?.content, !content.isEmpty {
                                    continuation.yield(.textDelta(content))
                                }
                                for toolCall in choice.delta?.toolCalls ?? [] {
                                    continuation.yield(.toolCallDelta(toolCall.asModelDelta))
                                }
                                if choice.finishReason != nil {
                                    continuation.yield(.finished(reason: choice.finishReason))
                                }
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    static let preview = OpenAICompatibleClient { _, _, _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("目前的传感器数据看起来稳定。"))
            continuation.yield(.finished(reason: "stop"))
            continuation.finish()
        }
    }

    static func completionURL(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("chat/completions") {
            return baseURL
        }
        return baseURL
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
    }

    static func indicatesUnsupportedImageInput(
        statusCode: Int? = nil,
        message: String?
    ) -> Bool {
        if let statusCode, ![400, 415, 422].contains(statusCode) {
            return false
        }
        guard let message else { return false }
        let text = message.lowercased()
        let imageMarkers = [
            "image", "vision", "multimodal", "image_url",
            "图片", "图像", "视觉", "多模态"
        ]
        let unsupportedMarkers = [
            "not support", "doesn't support", "does not support",
            "unsupported", "text-only", "text only", "only text",
            "invalid content type", "不支持", "仅支持文本", "只支持文本"
        ]
        return imageMarkers.contains(where: text.contains)
            && unsupportedMarkers.contains(where: text.contains)
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        guard let rawText = String(data: data, encoding: .utf8) else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(500))
    }
}

/// The text-model adapter owns the protocol loop: model request → tool calls →
/// local execution → tool result messages → final model response. It never
/// knows how BLE or SQLite are implemented.
@MainActor
struct TextModelAdapter {
    private static let maximumToolRounds = 3

    let client: OpenAICompatibleClient

    func respond(
        configuration: AIConfiguration,
        initialMessages: [AIRequestMessage],
        executor: PlantDataToolExecutor,
        onTextDelta: (String) -> Void,
        onToolCallRound: () -> Void
    ) async throws -> [ToolInvocation] {
        var messages = initialMessages
        var invocations: [ToolInvocation] = []

        for round in 0...Self.maximumToolRounds {
            let turn = try await collectTurn(
                configuration: configuration,
                messages: messages,
                onTextDelta: onTextDelta
            )

            guard !turn.toolCalls.isEmpty else {
                guard !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIClientError.emptyResponse
                }
                return invocations
            }

            guard round < Self.maximumToolRounds else {
                throw AIClientError.toolRoundLimitExceeded
            }

            // A model normally emits no text when requesting a tool. If it did,
            // do not present that provisional content as the final answer.
            onToolCallRound()
            messages.append(AIRequestMessage(
                role: .assistant,
                content: turn.content.isEmpty ? nil : turn.content,
                toolCalls: turn.toolCalls
            ))

            for call in turn.toolCalls {
                let invocation = await executor.execute(call)
                invocations.append(invocation)
                messages.append(AIRequestMessage(
                    role: .tool,
                    content: invocation.resultJSON,
                    toolCallID: call.id
                ))
            }
        }

        throw AIClientError.toolRoundLimitExceeded
    }

    private func collectTurn(
        configuration: AIConfiguration,
        messages: [AIRequestMessage],
        onTextDelta: (String) -> Void
    ) async throws -> TextModelTurn {
        var content = ""
        var toolCalls: [Int: ToolCallAccumulator] = [:]
        for try await event in client.streamTurn(
            configuration,
            messages,
            PlantDataToolCatalog.definitions
        ) {
            switch event {
            case .textDelta(let delta):
                content += delta
                onTextDelta(delta)
            case .toolCallDelta(let delta):
                var accumulator = toolCalls[delta.index] ?? ToolCallAccumulator(index: delta.index)
                accumulator.merge(delta)
                toolCalls[delta.index] = accumulator
            case .finished:
                break
            }
        }
        return TextModelTurn(
            content: content,
            toolCalls: try toolCalls.values
                .sorted { $0.index < $1.index }
                .map { try $0.modelToolCall }
        )
    }
}

private struct ToolCallAccumulator {
    let index: Int
    var id: String?
    var type: String?
    var name: String?
    var arguments = ""

    mutating func merge(_ delta: AIModelToolCallDelta) {
        if let id = delta.id { self.id = id }
        if let type = delta.type { self.type = type }
        if let name = delta.name { self.name = name }
        if let arguments = delta.arguments { self.arguments += arguments }
    }

    var modelToolCall: AIModelToolCall {
        get throws {
            guard let id, let name else { throw AIClientError.invalidToolCall }
            return AIModelToolCall(
                id: id,
                type: type ?? "function",
                function: .init(name: name, arguments: arguments)
            )
        }
    }
}

enum AIClientError: LocalizedError {
    case invalidResponse
    case http(statusCode: Int, message: String?)
    case server(String)
    case emptyResponse
    case invalidToolCall
    case toolRoundLimitExceeded
    case unsupportedImageInput(model: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "模型服务返回了无法识别的响应。"
        case .http(let statusCode, let message):
            message.map { "模型服务错误（HTTP \(statusCode)）：\($0)" }
                ?? "模型服务请求失败（HTTP \(statusCode)）。"
        case .server(let message):
            "模型服务错误：\(message)"
        case .emptyResponse:
            "模型没有返回文本内容。"
        case .invalidToolCall:
            "模型返回了不完整的工具调用。"
        case .toolRoundLimitExceeded:
            "模型连续请求工具的次数过多，已停止本次查询。"
        case .unsupportedImageInput(let model):
            "模型服务确认“\(model)”不支持图片输入，请切换为支持视觉输入的模型后再发送。"
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [AIRequestMessage]
    let stream: Bool
    let tools: [AIModelToolDefinition]
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case toolChoice = "tool_choice"
    }
}

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }

            let index: Int
            let id: String?
            let type: String?
            let function: Function?

            var asModelDelta: AIModelToolCallDelta {
                AIModelToolCallDelta(
                    index: index,
                    id: id,
                    type: type,
                    name: function?.name,
                    arguments: function?.arguments
                )
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct ErrorPayload: Decodable {
        let message: String
    }

    let choices: [Choice]
    let error: ErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case choices
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        error = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String
    }
    let error: Payload
}

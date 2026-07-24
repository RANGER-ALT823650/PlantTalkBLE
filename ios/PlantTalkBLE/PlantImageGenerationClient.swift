import Foundation
import UIKit

/// Image-to-image generation over DashScope's synchronous multimodal-generation
/// endpoint (qwen-image-edit family). It takes the current artwork image plus a
/// prompt, uploads the image inline as a Base64 data URL, then downloads the
/// returned PNG. Networking only; configuration lives in `AISettingsStore`.
struct PlantImageGenerationClient: Sendable {
    var generate: @Sendable (
        _ configuration: ImageGenerationConfiguration,
        _ image: UIImage,
        _ prompt: String
    ) async throws -> UIImage

    static func live(session: URLSession = .shared) -> PlantImageGenerationClient {
        PlantImageGenerationClient { configuration, image, prompt in
            let dataURL = try Self.encodeInputImageDataURL(image)

            var request = URLRequest(url: configuration.baseURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = try JSONEncoder().encode(
                ImageGenerationRequest(model: configuration.model, prompt: prompt, imageDataURL: dataURL)
            )

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImageGenerationError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ImageGenerationError.http(
                    statusCode: httpResponse.statusCode,
                    message: Self.serverErrorMessage(from: data)
                )
            }

            let imageURL = try Self.parseImageURL(from: data)
            return try await Self.downloadImage(from: imageURL, session: session)
        }
    }

    static let preview = PlantImageGenerationClient { _, image, _ in
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return image
    }

    /// DashScope accepts a public URL or a Base64 data URL for the input image and
    /// recommends the longer side stay within 384–3072px and under 10MB. Downscale
    /// to at most 2048px and JPEG-encode to keep the inline payload compact.
    private static func encodeInputImageDataURL(_ image: UIImage) throws -> String {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else {
            throw ImageGenerationError.invalidInputImage
        }
        let maximumPixelDimension: CGFloat = 2_048
        let scale = min(1, maximumPixelDimension / max(originalSize.width, originalSize.height))
        let outputSize = CGSize(
            width: max(1, (originalSize.width * scale).rounded()),
            height: max(1, (originalSize.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.85) else {
            throw ImageGenerationError.invalidInputImage
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func downloadImage(
        from url: URL,
        session: URLSession
    ) async throws -> UIImage {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ImageGenerationError.downloadFailed
        }
        guard let image = UIImage(data: data) else {
            throw ImageGenerationError.downloadFailed
        }
        return image
    }

    /// The response shape differs across DashScope image models. Decode leniently
    /// and accept either the multimodal `output.choices[].message.content[].image`
    /// path or the text2image `output.results[].url` path.
    private static func parseImageURL(from data: Data) throws -> URL {
        let envelope = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
        if let message = envelope.output?.errorMessage ?? envelope.message,
           envelope.output?.imageURLString == nil {
            throw ImageGenerationError.server(message)
        }
        guard let urlString = envelope.output?.imageURLString,
              let url = URL(string: urlString) else {
            throw ImageGenerationError.missingImage
        }
        return url
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(ImageGenerationResponse.self, from: data),
           let message = envelope.output?.errorMessage ?? envelope.message {
            return message
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }
}

// MARK: - Wire format

private struct ImageGenerationRequest: Encodable {
    struct Input: Encodable {
        let messages: [Message]
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentPart]
    }

    struct ContentPart: Encodable {
        let image: String?
        let text: String?
    }

    struct Parameters: Encodable {
        let negativePrompt: String
        let promptExtend: Bool
        let watermark: Bool

        enum CodingKeys: String, CodingKey {
            case negativePrompt = "negative_prompt"
            case promptExtend = "prompt_extend"
            case watermark
        }
    }

    let model: String
    let input: Input
    let parameters: Parameters

    init(model: String, prompt: String, imageDataURL: String) {
        self.model = model
        input = Input(messages: [
            Message(role: "user", content: [
                ContentPart(image: imageDataURL, text: nil),
                ContentPart(image: nil, text: prompt)
            ])
        ])
        parameters = Parameters(
            negativePrompt: "",
            promptExtend: true,
            watermark: false
        )
    }
}

private struct ImageGenerationResponse: Decodable {
    struct Output: Decodable {
        let choices: [Choice]?
        let results: [Result]?
        let taskStatus: String?

        enum CodingKeys: String, CodingKey {
            case choices, results
            case taskStatus = "task_status"
        }

        /// First image URL found on either the multimodal or text2image path.
        var imageURLString: String? {
            if let fromChoices = choices?
                .compactMap({ $0.message.content.compactMap(\.image).first })
                .first {
                return fromChoices
            }
            return results?.compactMap(\.url).first
        }

        var errorMessage: String? {
            guard let taskStatus, taskStatus.uppercased() == "FAILED" else { return nil }
            return "生图任务失败（\(taskStatus)）。"
        }
    }

    struct Choice: Decodable {
        let message: ChoiceMessage
    }

    struct ChoiceMessage: Decodable {
        let content: [ContentPart]
    }

    struct ContentPart: Decodable {
        let image: String?
    }

    struct Result: Decodable {
        let url: String?
    }

    let output: Output?
    let code: String?
    let message: String?
}

enum ImageGenerationError: LocalizedError {
    case invalidResponse
    case invalidInputImage
    case http(statusCode: Int, message: String?)
    case server(String)
    case missingImage
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "生图服务返回了无法识别的响应。"
        case .invalidInputImage:
            "无法处理输入图片，请重新拍摄或选择。"
        case .http(let statusCode, let message):
            message.map { "生图服务错误（HTTP \(statusCode)）：\($0)" }
                ?? "生图服务请求失败（HTTP \(statusCode)）。"
        case .server(let message):
            "生图服务错误：\(message)"
        case .missingImage:
            "生图服务没有返回图片，请调整提示词后重试。"
        case .downloadFailed:
            "生成的图片下载失败，请重试。"
        }
    }
}

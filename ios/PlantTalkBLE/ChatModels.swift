import Foundation

enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

enum AIConversationKind: String, Codable, Sendable {
    case text
    case realtime
}

struct AIConversation: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let kind: AIConversationKind
    let createdAt: Date
    var updatedAt: Date
}

struct ToolInvocation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let providerCallID: String?
    let toolName: String
    let summary: String
    let argumentsJSON: String
    let resultJSON: String
    let executedAt: Date
}

struct ChatImageAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let mimeType: String
    let data: Data

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    var imageAttachments: [ChatImageAttachment] = []
    var toolInvocations: [ToolInvocation] = []
}

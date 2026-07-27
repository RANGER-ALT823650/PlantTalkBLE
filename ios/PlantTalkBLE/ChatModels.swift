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

/// A recorded deletion. Removing a row locally is not enough for cloud sync: the
/// cloud mailbox still holds it, so the next pull would resurrect it. A tombstone
/// is the durable "this was deleted" fact that gets pushed to the other clients.
struct SyncTombstone: Equatable, Sendable {
    enum EntityType: String, Codable, Sendable {
        case conversation
        case message
    }

    let type: EntityType
    let entityID: String
    let conversationID: String?
    let deletedAt: Date
    /// `true` until the cloud has accepted this tombstone.
    let pendingPush: Bool
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

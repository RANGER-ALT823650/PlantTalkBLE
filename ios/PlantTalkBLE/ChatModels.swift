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

/// 同步 ID 的规范形式：去空白 + 转小写。
///
/// `UUID.uuidString` 恒为大写，而浏览器的 `crypto.randomUUID()` 恒为小写。
/// Tablestore 主键按字节比较，SQLite 的 TEXT 默认也是大小写敏感的，于是同一条
/// 记录在云端存成了两行，一端的墓碑永远匹配不上另一端那行——删除因此传不过去。
/// 必须与 cloud/index.py 的 `canonical_id`、web 的 `canonicalId` 保持一致。
func canonicalSyncID(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

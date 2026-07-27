import Foundation

/// 阿里云 FC + Tablestore 对话记录同步服务 (iOS)
@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    @Published var isSyncing: Bool = false
    @Published var lastSyncedAt: Date? = nil
    @Published var lastError: String? = nil

    private init() {}

    struct SyncPushRequest: Codable {
        struct ConvDTO: Codable {
            let id: String
            let title: String
            let kind: String
            let deviceId: String?
            let createdAt: Int64
            let updatedAt: Int64
        }
        struct MsgDTO: Codable {
            let id: String
            let conversation_id: String
            let role: String
            let text: String
            let createdAt: Int64
        }
        let conversations: [ConvDTO]
        let messages: [MsgDTO]
    }

    struct SyncPullResponse: Codable {
        struct ConvDTO: Codable {
            let id: String
            let title: String?
            let kind: String?
            let deviceId: String?
            let createdAt: Int64?
            let updatedAt: Int64?
        }
        struct MsgDTO: Codable {
            let id: String
            let conversation_id: String?
            let conversationId: String?
            let role: String?
            let text: String?
            let content: String?
            let createdAt: Int64?
        }
        let success: Bool
        let conversations: [ConvDTO]?
        let messages: [MsgDTO]?
    }

    /// 执行云端同步（Push 本地数据 + Pull 云端数据并合并）
    func sync(database: PlantDatabase) async {
        guard let urlString = UserDefaults.standard.string(forKey: "plant_talk_cloud_sync_url"),
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let token = UserDefaults.standard.string(forKey: "plant_talk_cloud_sync_token") ?? ""

        isSyncing = true
        lastError = nil

        defer {
            isSyncing = false
        }

        do {
            // 0. 记录拉取前手机本地原有的会话集合（避免把刚从云端拉下来的数据算作“本地上传”）
            let initialConvs = try await database.allConversations()
            let initialConvIDs = Set(initialConvs.map { $0.id })

            // 1. Pull 云端消息并合并到本地数据库
            var pulledStats = (convs: 0, msgs: 0)
            var pullURL = url.appendingPathComponent("sync/pull")
            var components = URLComponents(url: pullURL, resolvingAgainstBaseURL: true)
            components?.queryItems = [URLQueryItem(name: "since", value: "0")]
            if let finalURL = components?.url {
                var request = URLRequest(url: finalURL)
                request.httpMethod = "GET"
                if !token.isEmpty {
                    request.setValue(token, forHTTPHeaderField: "x-auth-token")
                }

                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse {
                    guard httpResp.statusCode == 200 else {
                        let errStr = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResp.statusCode)"
                        throw NSError(domain: "CloudSync", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "拉取失败: \(errStr)"])
                    }
                    let decoded = try JSONDecoder().decode(SyncPullResponse.self, from: data)
                    if decoded.success {
                        pulledStats = try await mergeRemoteData(decoded, into: database)
                    }
                }
            }

            // 2. Push 本地原有的新增/修改会话和消息上云
            let currentConvs = try await database.allConversations()
            var pushConvs: [SyncPushRequest.ConvDTO] = []
            var pushMsgs: [SyncPushRequest.MsgDTO] = []

            for conv in currentConvs {
                // 仅推送拉取前本地就已存在的会话（真正的本地数据）
                if initialConvIDs.contains(conv.id) {
                    pushConvs.append(SyncPushRequest.ConvDTO(
                        id: conv.id.uuidString,
                        title: conv.title,
                        kind: conv.kind.rawValue,
                        deviceId: nil,
                        createdAt: Int64(conv.createdAt.timeIntervalSince1970 * 1000),
                        updatedAt: Int64(conv.updatedAt.timeIntervalSince1970 * 1000)
                    ))

                    let msgs = try await database.chatMessages(conversationID: conv.id)
                    for msg in msgs {
                        pushMsgs.append(SyncPushRequest.MsgDTO(
                            id: msg.id.uuidString,
                            conversation_id: conv.id.uuidString,
                            role: msg.role.rawValue,
                            text: msg.content,
                            createdAt: Int64(msg.createdAt.timeIntervalSince1970 * 1000)
                        ))
                    }
                }
            }

            if !pushConvs.isEmpty {
                let pushBody = SyncPushRequest(conversations: pushConvs, messages: pushMsgs)
                let pushURL = url.appendingPathComponent("sync/push")
                var pushRequest = URLRequest(url: pushURL)
                pushRequest.httpMethod = "POST"
                pushRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !token.isEmpty {
                    pushRequest.setValue(token, forHTTPHeaderField: "x-auth-token")
                }
                pushRequest.httpBody = try JSONEncoder().encode(pushBody)

                let (_, pushResp) = try await URLSession.shared.data(for: pushRequest)
                if let httpResp = pushResp as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                    print("[CloudSyncService] Push Warning: HTTP \(httpResp.statusCode)")
                }
            }

            lastSyncedAt = Date()
            if pushConvs.isEmpty && pushMsgs.isEmpty {
                lastSyncSummary = "拉取 \(pulledStats.convs) 条会话 / \(pulledStats.msgs) 条消息"
            } else {
                lastSyncSummary = "上传 \(pushConvs.count) 条会话 / \(pushMsgs.count) 条消息，拉取 \(pulledStats.convs) 条会话 / \(pulledStats.msgs) 条消息"
            }
            NotificationCenter.default.post(name: Notification.Name("CloudSyncDidComplete"), object: nil)
        } catch {
            lastError = error.localizedDescription
            print("[CloudSyncService] Error: \(error)")
        }
    }

    @Published var lastSyncSummary: String? = nil

    private func parseOrMakeUUID(_ string: String) -> UUID {
        if let uuid = UUID(uuidString: string) {
            return uuid
        }
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(string.utf8)
        for (i, byte) in bytes.enumerated() {
            hash[i % 16] ^= byte
        }
        hash[6] = (hash[6] & 0x0f) | 0x40
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

    private func mergeRemoteData(_ response: SyncPullResponse, into database: PlantDatabase) async throws -> (convs: Int, msgs: Int) {
        guard let convs = response.conversations, let msgs = response.messages else { return (0, 0) }

        // 按会话 ID 组织消息
        var msgGroup: [String: [SyncPullResponse.MsgDTO]] = [:]
        for msg in msgs {
            let cId = msg.conversation_id ?? msg.conversationId ?? ""
            if !cId.isEmpty {
                msgGroup[cId, default: []].append(msg)
            }
        }

        var convCount = 0
        var msgCount = 0

        for convDTO in convs {
            let convUUID = parseOrMakeUUID(convDTO.id)
            let rawKind = convDTO.kind ?? "text"
            let kind: AIConversationKind = (rawKind == "voice" || rawKind == "realtime") ? .realtime : .text
            let title = convDTO.title ?? "云端对话"
            let createdAt = Date(timeIntervalSince1970: Double(convDTO.createdAt ?? 0) / 1000.0)

            // 保存或创建本地会话
            _ = try await database.ensureConversation(id: convUUID, kind: kind, defaultTitle: title, createdAt: createdAt)
            convCount += 1

            // 合并消息
            if let remoteMsgs = msgGroup[convDTO.id] {
                for mDTO in remoteMsgs {
                    let msgUUID = parseOrMakeUUID(mDTO.id)
                    let role = ChatRole(rawValue: mDTO.role ?? "user") ?? .user
                    let content = mDTO.text ?? mDTO.content ?? ""
                    let msgDate = Date(timeIntervalSince1970: Double(mDTO.createdAt ?? 0) / 1000.0)

                    try await database.insertMessageIfNotExist(
                        id: msgUUID,
                        conversationID: convUUID,
                        role: role,
                        content: content,
                        createdAt: msgDate
                    )
                    msgCount += 1
                }
            }
        }

        return (convCount, msgCount)
    }
}

import Foundation

/// 阿里云 FC + Tablestore 对话记录同步服务 (iOS)
@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    @Published var isSyncing: Bool = false
    @Published var lastSyncedAt: Date? = nil
    @Published var lastError: String? = nil
    @Published var lastSyncSummary: String? = nil
    /// 云端墓碑表缺失等"能同步但删除传不过去"的情况在此提示
    @Published var lastWarning: String? = nil

    private init() {}

    struct SyncPushRequest: Encodable {
        struct ConvDTO: Encodable {
            let id: String
            let title: String
            let kind: String
            let deviceId: String?
            let createdAt: Int64
            let updatedAt: Int64
        }
        struct MsgDTO: Encodable {
            let id: String
            let conversation_id: String
            let role: String
            let text: String
            let createdAt: Int64
        }
        struct DeletionDTO: Encodable {
            let type: String
            let id: String
            let conversationId: String?
            let deletedAt: Int64
        }
        let conversations: [ConvDTO]
        let messages: [MsgDTO]
        let deletions: [DeletionDTO]
        let sensorReadings: [PlantDatabase.SyncSensorReading]?
        let sensor_readings: [PlantDatabase.SyncSensorReading]?
    }

    struct SyncPushResponse: Decodable {
        let success: Bool?
        let deletions_supported: Bool?
        let deletions_hint: String?
        let error: String?
    }

    struct SyncPullResponse: Decodable {
        struct ConvDTO: Decodable {
            let id: String
            let title: String?
            let kind: String?
            let deviceId: String?
            let createdAt: Int64?
            let updatedAt: Int64?
        }
        struct MsgDTO: Decodable {
            let id: String
            let conversation_id: String?
            let conversationId: String?
            let role: String?
            let text: String?
            let content: String?
            let createdAt: Int64?
        }
        struct DeletionDTO: Decodable {
            let type: String?
            let id: String?
            let conversationId: String?
            let deletedAt: Int64?
        }
        let success: Bool
        let conversations: [ConvDTO]?
        let messages: [MsgDTO]?
        let deletions: [DeletionDTO]?
        let sensorReadings: [PlantDatabase.SyncSensorReading]?
        let sensor_readings: [PlantDatabase.SyncSensorReading]?
        let deletions_supported: Bool?
        let deletions_hint: String?
        let error: String?
    }

    private struct PullOutcome {
        var conversations = 0
        var messages = 0
        var sensorReadings = 0
        var removedConversations = 0
        var removedMessages = 0
        var warning: String?
    }

    /// 执行云端同步（先 Pull 并应用远端删除，再 Push 本地新增与删除意图）
    func sync(database: PlantDatabase) async {
        guard let urlString = UserDefaults.standard.string(forKey: "plant_talk_cloud_sync_url"),
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let token = UserDefaults.standard.string(forKey: "plant_talk_cloud_sync_token") ?? ""

        isSyncing = true
        lastError = nil
        lastWarning = nil

        defer {
            isSyncing = false
        }

        do {
            // 0. 记录拉取前手机本地原有的会话集合（避免把刚从云端拉下来的数据算作“本地上传”）
            let initialConvs = try await database.allConversations()
            let initialConvIDs = Set(initialConvs.map { $0.id })

            // 1. Pull 云端数据：先应用远端删除，再合并新增
            let pulled = try await pull(url: url, token: token, database: database)

            // 2. Push 本地删除意图 + 拉取前本地就已存在的会话
            let pendingTombstones = try await database.pendingTombstones()
            let locallyDeletedConvIDs = Set(
                pendingTombstones
                    .filter { $0.type == .conversation }
                    .compactMap { UUID(uuidString: $0.entityID) }
            )

            let currentConvs = try await database.allConversations()
            var pushConvs: [SyncPushRequest.ConvDTO] = []
            var pushMsgs: [SyncPushRequest.MsgDTO] = []

            for conv in currentConvs {
                // 仅推送拉取前本地就已存在、且未被本地删除的会话（真正的本地数据）
                guard initialConvIDs.contains(conv.id), !locallyDeletedConvIDs.contains(conv.id) else {
                    continue
                }
                pushConvs.append(SyncPushRequest.ConvDTO(
                    id: conv.id.uuidString,
                    title: conv.title,
                    kind: conv.kind.rawValue,
                    deviceId: nil,
                    createdAt: Self.milliseconds(conv.createdAt),
                    updatedAt: Self.milliseconds(conv.updatedAt)
                ))

                let msgs = try await database.chatMessages(conversationID: conv.id)
                for msg in msgs {
                    pushMsgs.append(SyncPushRequest.MsgDTO(
                        id: msg.id.uuidString,
                        conversation_id: conv.id.uuidString,
                        role: msg.role.rawValue,
                        text: msg.content,
                        createdAt: Self.milliseconds(msg.createdAt)
                    ))
                }
            }

            let localReadings = (try? await database.allSensorReadingsForSync()) ?? []

            var pushedDeletions = 0
            var pushWarning: String?
            if !pushConvs.isEmpty || !pushMsgs.isEmpty || !pendingTombstones.isEmpty || !localReadings.isEmpty {
                let accepted = try await push(
                    url: url,
                    token: token,
                    conversations: pushConvs,
                    messages: pushMsgs,
                    tombstones: pendingTombstones,
                    sensorReadings: localReadings
                )
                pushWarning = accepted.warning
                if accepted.deletionsAccepted {
                    // 只有云端确实收下了墓碑才清 pending，否则下次继续重试
                    try await database.markTombstonesPushed(pendingTombstones)
                    pushedDeletions = pendingTombstones.count
                }
            }

            lastSyncedAt = Date()
            lastWarning = pushWarning ?? pulled.warning

            var parts: [String] = []
            if !pushConvs.isEmpty || !pushMsgs.isEmpty {
                parts.append("上传 \(pushConvs.count) 条会话 / \(pushMsgs.count) 条消息")
            }
            if pushedDeletions > 0 {
                parts.append("同步 \(pushedDeletions) 条删除")
            }
            parts.append("拉取 \(pulled.conversations) 条会话 / \(pulled.messages) 条消息 / \(pulled.sensorReadings) 条传感器读数")
            let removed = pulled.removedConversations + pulled.removedMessages
            if removed > 0 {
                parts.append("本地移除 \(removed) 条已删除记录")
            }
            lastSyncSummary = parts.joined(separator: "，")

            NotificationCenter.default.post(name: Notification.Name("CloudSyncDidComplete"), object: nil)
        } catch {
            lastError = error.localizedDescription
            print("[CloudSyncService] Error: \(error)")
        }
    }

    private func pull(url: URL, token: String, database: PlantDatabase) async throws -> PullOutcome {
        let pullURL = url.appendingPathComponent("sync/pull")
        var components = URLComponents(url: pullURL, resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "since", value: "0")]
        guard let finalURL = components?.url else {
            throw NSError(
                domain: "CloudSync",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法拼接拉取地址，请检查云同步 URL 是否正确。"]
            )
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-auth-token")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        // 原实现在拿不到 HTTPURLResponse 时静默跳过整个拉取，失败会被当成成功。
        guard let httpResp = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CloudSync",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "拉取失败: 未收到有效的 HTTP 响应。"]
            )
        }
        guard httpResp.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResp.statusCode)"
            throw NSError(
                domain: "CloudSync",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "拉取失败: \(errStr)"]
            )
        }

        let decoded = try JSONDecoder().decode(SyncPullResponse.self, from: data)
        guard decoded.success else {
            throw NSError(
                domain: "CloudSync",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "拉取失败: \(decoded.error ?? "云端返回 success=false")"]
            )
        }

        var outcome = try await mergeRemoteData(decoded, into: database)
        if decoded.deletions_supported == false {
            outcome.warning = decoded.deletions_hint
        }
        return outcome
    }

    private func push(
        url: URL,
        token: String,
        conversations: [SyncPushRequest.ConvDTO],
        messages: [SyncPushRequest.MsgDTO],
        tombstones: [SyncTombstone],
        sensorReadings: [PlantDatabase.SyncSensorReading] = []
    ) async throws -> (deletionsAccepted: Bool, warning: String?) {
        let pushURL = url.appendingPathComponent("sync/push")
        var pushRequest = URLRequest(url: pushURL)
        pushRequest.httpMethod = "POST"
        pushRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            pushRequest.setValue(token, forHTTPHeaderField: "x-auth-token")
        }

        let deletionDTOs = tombstones.map {
            SyncPushRequest.DeletionDTO(
                type: $0.type.rawValue,
                id: $0.entityID,
                conversationId: $0.conversationID,
                deletedAt: Self.milliseconds($0.deletedAt)
            )
        }
        
        let pushBody = SyncPushRequest(
            conversations: conversations,
            messages: messages,
            deletions: deletionDTOs,
            sensorReadings: sensorReadings,
            sensor_readings: sensorReadings
        )
        
        pushRequest.httpBody = try JSONEncoder().encode(pushBody)

        let (data, response) = try await URLSession.shared.data(for: pushRequest)
        // 推送失败必须抛错：静默忽略会让"已同步删除"的提示与事实不符。
        guard let httpResp = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CloudSync",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "推送失败: 未收到有效的 HTTP 响应。"]
            )
        }
        guard (200...299).contains(httpResp.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResp.statusCode)"
            throw NSError(
                domain: "CloudSync",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "推送失败: \(errStr)"]
            )
        }

        let decoded = try? JSONDecoder().decode(SyncPushResponse.self, from: data)
        if let error = decoded?.error {
            throw NSError(
                domain: "CloudSync",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "推送失败: \(error)"]
            )
        }
        let deletionsAccepted = decoded?.deletions_supported != false
        return (deletionsAccepted, deletionsAccepted ? nil : decoded?.deletions_hint)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

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

    private func mergeRemoteData(_ response: SyncPullResponse, into database: PlantDatabase) async throws -> PullOutcome {
        var outcome = PullOutcome()

        // 1. 先应用远端删除，避免刚拉下来的记录又被本地当成新数据推回去
        let remoteDeletions: [SyncTombstone] = (response.deletions ?? []).compactMap { dto in
            guard let rawType = dto.type,
                  let type = SyncTombstone.EntityType(rawValue: rawType),
                  let id = dto.id, !id.isEmpty else {
                return nil
            }
            return SyncTombstone(
                type: type,
                entityID: id,
                conversationID: dto.conversationId,
                deletedAt: Date(timeIntervalSince1970: Double(dto.deletedAt ?? 0) / 1000.0),
                pendingPush: false
            )
        }
        if !remoteDeletions.isEmpty {
            let removed = try await database.applyRemoteDeletions(remoteDeletions)
            outcome.removedConversations = removed.conversations
            outcome.removedMessages = removed.messages
        }

        guard let convs = response.conversations, let msgs = response.messages else { return outcome }

        // 2. 本地墓碑同样要拦住云端数据：离线删除时云端还不知道这些删除
        let localTombstones = try await database.allTombstones()
        let deletedConvIDs = Set(localTombstones.filter { $0.type == .conversation }.map(\.entityID))
        let deletedMsgIDs = Set(localTombstones.filter { $0.type == .message }.map(\.entityID))

        // 按会话 ID 组织消息
        var msgGroup: [String: [SyncPullResponse.MsgDTO]] = [:]
        for msg in msgs {
            guard !deletedMsgIDs.contains(msg.id) else { continue }
            let cId = msg.conversation_id ?? msg.conversationId ?? ""
            if !cId.isEmpty, !deletedConvIDs.contains(cId) {
                msgGroup[cId, default: []].append(msg)
            }
        }

        for convDTO in convs {
            guard !deletedConvIDs.contains(convDTO.id) else { continue }
            let convUUID = parseOrMakeUUID(convDTO.id)
            let rawKind = convDTO.kind ?? "text"
            let kind: AIConversationKind = (rawKind == "voice" || rawKind == "realtime") ? .realtime : .text
            let title = convDTO.title ?? "云端对话"
            let createdAt = Date(timeIntervalSince1970: Double(convDTO.createdAt ?? 0) / 1000.0)

            let remoteMsgs = msgGroup[convDTO.id] ?? []
            // 整段消息都被别端删掉的会话不值得重建
            if remoteMsgs.isEmpty, deletedMsgIDs.count > 0, msgs.contains(where: {
                ($0.conversation_id ?? $0.conversationId) == convDTO.id
            }) {
                continue
            }

            // 保存或创建本地会话
            _ = try await database.ensureConversation(id: convUUID, kind: kind, defaultTitle: title, createdAt: createdAt)
            outcome.conversations += 1

            // 合并消息
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
                outcome.messages += 1
            }
        }

        let remoteReadings = response.sensorReadings ?? response.sensor_readings ?? []
        if !remoteReadings.isEmpty {
            let inserted = try await database.insertRemoteSensorReadings(remoteReadings)
            outcome.sensorReadings = inserted
        }

        return outcome
    }
}

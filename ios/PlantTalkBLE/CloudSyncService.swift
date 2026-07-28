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
        let sensorReadings: [SyncSensorReading]?
        let sensor_readings: [SyncSensorReading]?
    }

    struct SyncPushResponse: Decodable {
        let success: Bool?
        /// 云端实际写入的读数条数。缺表时为 0，摘要要按它报而不是按发送量报。
        let sensor_readings_count: Int?
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
        let sensorReadings: [SyncSensorReading]?
        let sensor_readings: [SyncSensorReading]?
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
        /// 云端此刻持有的记录清单（规范小写 ID），供随后的推送算增量。
        var conversationIDs: Set<String> = []
        var messageIDs: Set<String> = []
        var readingKeys: Set<String> = []
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
                let msgs = try await database.chatMessages(conversationID: conv.id)
                let newMsgs = msgs.filter { !pulled.messageIDs.contains(Self.syncID($0.id)) }
                // 云端已有这条会话、且名下消息一条不缺时，本次没有增量可传。
                // 整表重传会让"上传 115 条会话"每次都出现，用户无从判断真实变化。
                if newMsgs.isEmpty, pulled.conversationIDs.contains(Self.syncID(conv.id)) {
                    continue
                }

                pushConvs.append(SyncPushRequest.ConvDTO(
                    id: Self.syncID(conv.id),
                    title: conv.title,
                    kind: conv.kind.rawValue,
                    deviceId: nil,
                    createdAt: Self.milliseconds(conv.createdAt),
                    updatedAt: Self.milliseconds(conv.updatedAt)
                ))

                for msg in newMsgs {
                    pushMsgs.append(SyncPushRequest.MsgDTO(
                        id: Self.syncID(msg.id),
                        conversation_id: Self.syncID(conv.id),
                        role: msg.role.rawValue,
                        text: msg.content,
                        createdAt: Self.milliseconds(msg.createdAt)
                    ))
                }
            }

            // 读不出本地读数是真实故障，不能用 try? 咽掉：那样摘要会显示
            // "上传 0 条读数"，看起来像没有数据而不是同步出了问题。
            // 只发云端还没有的那些：整表重传会让"上传 1067 条"每次都出现。
            let localReadings = try await database.allSensorReadingsForSync().filter {
                !pulled.readingKeys.contains("\($0.deviceId):\($0.sequence)")
            }

            var pushedDeletions = 0
            var pushedReadings = 0
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
                pushedReadings = accepted.storedReadings
                if accepted.deletionsAccepted {
                    // 只有云端确实收下了墓碑才清 pending，否则下次继续重试
                    try await database.markTombstonesPushed(pendingTombstones)
                    pushedDeletions = pendingTombstones.count
                }
            }

            lastSyncedAt = Date()
            lastWarning = pushWarning ?? pulled.warning

            // 摘要只讲真正发生的变化。云端每次回放整张表，把响应长度当成
            // "同步了多少"会让同一批数字每次都出现，用户无法判断这次动了什么。
            var parts: [String] = []
            if !pushConvs.isEmpty || !pushMsgs.isEmpty {
                parts.append("上传 \(pushConvs.count) 条会话 / \(pushMsgs.count) 条消息")
            }
            if pushedReadings > 0 {
                parts.append("上传 \(pushedReadings) 条传感器读数")
            }
            if pushedDeletions > 0 {
                parts.append("同步 \(pushedDeletions) 条删除")
            }
            if pulled.conversations > 0 || pulled.messages > 0 {
                parts.append("新增 \(pulled.conversations) 条会话 / \(pulled.messages) 条消息")
            }
            if pulled.sensorReadings > 0 {
                parts.append("新增 \(pulled.sensorReadings) 条传感器读数")
            }
            let removed = pulled.removedConversations + pulled.removedMessages
            if removed > 0 {
                parts.append("本地移除 \(removed) 条已删除记录")
            }
            if parts.isEmpty {
                parts.append("已是最新，无变化")
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
        // 缺表提示在同步成功时也要显示：否则用户只看到"同步成功"，
        // 却不知道某类数据其实一条都没进云端。
        outcome.warning = decoded.deletions_hint
        return outcome
    }

    private func push(
        url: URL,
        token: String,
        conversations: [SyncPushRequest.ConvDTO],
        messages: [SyncPushRequest.MsgDTO],
        tombstones: [SyncTombstone],
        sensorReadings: [SyncSensorReading] = []
    ) async throws -> (deletionsAccepted: Bool, storedReadings: Int, warning: String?) {
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
                // 墓碑写库时已折叠成小写，这里再兜一层，防止老库残留的大写写法上传。
                id: canonicalSyncID($0.entityID),
                conversationId: $0.conversationID.map(canonicalSyncID),
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
        // 提示与 deletionsAccepted 解耦：读数表缺失时删除照样能同步，
        // 但缺表这件事仍要告诉用户。
        return (
            deletionsAccepted,
            decoded?.sensor_readings_count ?? sensorReadings.count,
            decoded?.deletions_hint
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 把 UUID 编码成云端认可的规范写法（小写）。`UUID.uuidString` 恒为大写，
    /// 直接上传会和 Web 生成的小写 ID 在云端分裂成两条记录。
    private static func syncID(_ uuid: UUID) -> String {
        canonicalSyncID(uuid.uuidString)
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
                  let id = dto.id, !canonicalSyncID(id).isEmpty else {
                return nil
            }
            return SyncTombstone(
                type: type,
                entityID: canonicalSyncID(id),
                conversationID: dto.conversationId.map(canonicalSyncID),
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
        let deletedConvIDs = Set(
            localTombstones.filter { $0.type == .conversation }.map { canonicalSyncID($0.entityID) }
        )
        let deletedMsgIDs = Set(
            localTombstones.filter { $0.type == .message }.map { canonicalSyncID($0.entityID) }
        )

        // 按会话 ID 组织消息。ID 一律折叠成小写：未升级的云端仍可能回传大写写法。
        var msgGroup: [String: [SyncPullResponse.MsgDTO]] = [:]
        for msg in msgs {
            let mId = canonicalSyncID(msg.id)
            outcome.messageIDs.insert(mId)
            guard !deletedMsgIDs.contains(mId) else { continue }
            let cId = canonicalSyncID(msg.conversation_id ?? msg.conversationId ?? "")
            if !cId.isEmpty, !deletedConvIDs.contains(cId) {
                msgGroup[cId, default: []].append(msg)
            }
        }

        for convDTO in convs {
            let convID = canonicalSyncID(convDTO.id)
            outcome.conversationIDs.insert(convID)
            guard !deletedConvIDs.contains(convID) else { continue }
            let convUUID = parseOrMakeUUID(convDTO.id)
            let rawKind = convDTO.kind ?? "text"
            let kind: AIConversationKind = (rawKind == "voice" || rawKind == "realtime") ? .realtime : .text
            let title = convDTO.title ?? "云端对话"
            let createdAt = Date(timeIntervalSince1970: Double(convDTO.createdAt ?? 0) / 1000.0)

            let remoteMsgs = msgGroup[convID] ?? []
            // 整段消息都被别端删掉的会话不值得重建
            if remoteMsgs.isEmpty, deletedMsgIDs.count > 0, msgs.contains(where: {
                canonicalSyncID($0.conversation_id ?? $0.conversationId ?? "") == convID
            }) {
                continue
            }

            // 保存或创建本地会话。云端每次回放整张表，只有"真的建了新会话"
            // 才算拉取到的增量，否则摘要里那串数字会一直不变。
            let ensured = try await database.ensureConversation(
                id: convUUID,
                kind: kind,
                defaultTitle: title,
                createdAt: createdAt
            )
            if ensured.created {
                outcome.conversations += 1
            }

            // 合并消息
            for mDTO in remoteMsgs {
                let msgUUID = parseOrMakeUUID(mDTO.id)
                let role = ChatRole(rawValue: mDTO.role ?? "user") ?? .user
                let content = mDTO.text ?? mDTO.content ?? ""
                let msgDate = Date(timeIntervalSince1970: Double(mDTO.createdAt ?? 0) / 1000.0)

                let inserted = try await database.insertMessageIfNotExist(
                    id: msgUUID,
                    conversationID: ensured.conversation.id,
                    role: role,
                    content: content,
                    createdAt: msgDate
                )
                if inserted {
                    outcome.messages += 1
                }
            }
        }

        let remoteReadings = response.sensorReadings ?? response.sensor_readings ?? []
        for reading in remoteReadings {
            outcome.readingKeys.insert("\(reading.deviceId):\(reading.sequence)")
        }
        if !remoteReadings.isEmpty {
            let inserted = try await database.insertRemoteSensorReadings(remoteReadings)
            outcome.sensorReadings = inserted
        }

        return outcome
    }
}

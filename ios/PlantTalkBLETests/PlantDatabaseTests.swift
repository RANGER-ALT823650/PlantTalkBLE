import Foundation
import GRDB
import XCTest
@testable import PlantTalkBLE

final class PlantDatabaseTests: XCTestCase {
    func testMemorySequenceReadsTextAndRealtimeWithoutRepeating() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let textConversation = try await database.createConversation(
            title: "文字",
            kind: .text
        )
        let realtimeConversation = try await database.createConversation(
            title: "语音",
            kind: .realtime
        )
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: textConversation.id,
            role: .user,
            content: "我喜欢简洁回答",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: realtimeConversation.id,
            role: .user,
            content: "这株植物叫小绿",
            createdAt: Date(timeIntervalSince1970: 1_750_000_001)
        ))

        let firstBatch = try await database.memoryHistoryMessages(
            afterSequence: 0,
            limit: 1
        )
        let first = try XCTUnwrap(firstBatch.first)
        let secondBatch = try await database.memoryHistoryMessages(
            afterSequence: first.sequence,
            limit: 10
        )

        XCTAssertEqual(firstBatch.count, 1)
        XCTAssertEqual(first.conversationKind, .text)
        XCTAssertEqual(first.content, "我喜欢简洁回答")
        XCTAssertEqual(secondBatch.map(\.conversationKind), [.realtime])
        XCTAssertEqual(secondBatch.map(\.content), ["这株植物叫小绿"])
        XCTAssertTrue(secondBatch.allSatisfy { $0.sequence > first.sequence })
    }

    func testMemorySequenceDoesNotReuseAfterDeletingNewestConversation() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let deletedConversation = try await database.createConversation(title: "将删除")
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: deletedConversation.id,
            role: .user,
            content: "已经整理的内容",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
        let initialHistory = try await database.memoryHistoryMessages(
            afterSequence: 0,
            limit: 10
        )
        let processed = try XCTUnwrap(initialHistory.last)

        try await database.deleteConversation(id: deletedConversation.id)
        let newConversation = try await database.createConversation(title: "新会话")
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: newConversation.id,
            role: .user,
            content: "删除会话后的新内容",
            createdAt: Date(timeIntervalSince1970: 1_750_000_001)
        ))

        let newHistory = try await database.memoryHistoryMessages(
            afterSequence: processed.sequence,
            limit: 10
        )

        XCTAssertEqual(newHistory.map(\.content), ["删除会话后的新内容"])
        XCTAssertTrue(newHistory.allSatisfy { $0.sequence > processed.sequence })
    }

    func testLegacyMemoryCursorConvertsAfterItsHighestMessageWasDeleted() async throws {
        let database = try PlantDatabase(path: legacyDatabasePathWithDeletedHighWaterMessage())
        let converted = try await database.memorySequence(forLegacyRowID: 2)
        let newConversation = try await database.createConversation(title: "新会话")
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: newConversation.id,
            role: .user,
            content: "迁移后的新消息",
            createdAt: Date(timeIntervalSince1970: 1_750_000_002)
        ))

        let newHistory = try await database.memoryHistoryMessages(
            afterSequence: converted,
            limit: 10
        )

        XCTAssertEqual(converted, 1)
        XCTAssertEqual(newHistory.map(\.content), ["迁移后的新消息"])
    }

    func testMemoryStoreKeepsOneFileAndTracksManualUpdateTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("plant-memory.json")
        let store = PlantMemoryStore(fileURL: fileURL)
        let id = UUID()
        let originalDate = Date(timeIntervalSince1970: 1_750_000_000)
        let updatedDate = originalDate.addingTimeInterval(300)
        var document = PlantMemoryDocument()
        document.userProfile = [PlantMemoryRecord(
            id: id,
            content: "用户喜欢简洁回答",
            updatedAt: originalDate
        )]
        try await store.replace(with: document)

        let updated = try await store.update(
            section: .userProfile,
            recordID: id,
            content: "用户希望回答先给结论",
            now: updatedDate
        )
        let loaded = try await store.load()
        let prompt = try await store.promptContext()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["plant-memory.json"])
        XCTAssertEqual(updated.updatedAt, updatedDate)
        XCTAssertEqual(loaded.userProfile, [updated])
        XCTAssertTrue(prompt.contains("## 用户画像"))
        XCTAssertTrue(prompt.contains("用户希望回答先给结论"))
        XCTAssertTrue(prompt.contains("更新于"))
    }

    func testMemoryStorePreservesLegacyCursorUntilDatabaseConversion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("plant-memory.json")
        let legacyJSON = """
            {
              "schema_version": 1,
              "last_processed_message_row_id": 42,
              "user_profile": [],
              "plant_profile": [],
              "important_events": [],
              "follow_ups": []
            }
            """
        try Data(legacyJSON.utf8).write(to: fileURL)
        let store = PlantMemoryStore(fileURL: fileURL)

        var document = try await store.load()

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.lastProcessedMessageSequence, 42)

        document.schemaVersion = PlantMemoryDocument.currentSchemaVersion
        try await store.replace(with: document)
        let upgradedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(upgradedJSON.contains("last_processed_message_sequence"))
        XCTAssertFalse(upgradedJSON.contains("last_processed_message_row_id"))
    }

    func testMemoryReconciliationAddsUpdatesDeletesAndDeduplicates() {
        let oldDate = Date(timeIntervalSince1970: 1_750_000_000)
        let now = oldDate.addingTimeInterval(600)
        let userID = UUID()
        let plantID = UUID()
        var current = PlantMemoryDocument()
        current.lastProcessedMessageSequence = 42
        current.userProfile = [PlantMemoryRecord(
            id: userID,
            content: "用户喜欢简洁回答",
            updatedAt: oldDate
        )]
        current.plantProfile = [PlantMemoryRecord(
            id: plantID,
            content: "植物叫小绿",
            updatedAt: oldDate
        )]
        current.importantEvents = [PlantMemoryRecord(
            id: UUID(),
            content: "已经过时的临时事件",
            updatedAt: oldDate
        )]

        let proposal = MemoryOrganizationProposal(
            userProfile: [MemoryOrganizationCandidate(
                id: userID.uuidString,
                content: "用户希望回答先给结论"
            )],
            plantProfile: [MemoryOrganizationCandidate(
                id: nil,
                content: "植物叫小绿"
            )],
            importantEvents: [],
            followUps: [
                MemoryOrganizationCandidate(id: nil, content: "三天后检查叶片"),
                MemoryOrganizationCandidate(id: nil, content: "  三天后检查叶片  ")
            ]
        )

        let result = PlantMemoryLaunchOrganizer.reconcile(
            current: current,
            proposal: proposal,
            now: now
        )

        XCTAssertEqual(result.lastProcessedMessageSequence, 42)
        XCTAssertEqual(result.userProfile.first?.id, userID)
        XCTAssertEqual(result.userProfile.first?.content, "用户希望回答先给结论")
        XCTAssertEqual(result.userProfile.first?.updatedAt, now)
        XCTAssertEqual(result.plantProfile.first?.id, plantID)
        XCTAssertEqual(result.plantProfile.first?.updatedAt, oldDate)
        XCTAssertTrue(result.importantEvents.isEmpty)
        XCTAssertEqual(result.followUps.map(\.content), ["三天后检查叶片"])
        XCTAssertEqual(result.followUps.first?.updatedAt, now)
    }

    func testConversationAndMessagesPersistInOrder() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let conversation = try await database.createConversation(title: "测试植物对话")
        let firstDate = Date(timeIntervalSince1970: 1_750_000_000)
        let secondDate = firstDate.addingTimeInterval(1)
        let invocation = ToolInvocation(
            id: UUID(),
            providerCallID: "call_test",
            toolName: "get_sensor_summary",
            summary: "温度 · 昨天",
            argumentsJSON: #"{"period":"yesterday","metrics":["temperature"]}"#,
            resultJSON: #"{"temperature":{"average":24.6}}"#,
            executedAt: secondDate
        )
        let imageAttachment = ChatImageAttachment(
            id: "persisted-image",
            mimeType: "image/jpeg",
            data: Data([0x01, 0x02, 0x03])
        )

        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            role: .user,
            content: "现在感觉怎么样？",
            createdAt: firstDate,
            imageAttachments: [imageAttachment]
        ))
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            role: .assistant,
            content: "空气湿度目前比较稳定。",
            createdAt: secondDate,
            toolInvocations: [invocation]
        ))

        let conversations = try await database.allConversations()
        let messages = try await database.chatMessages(conversationID: conversation.id)

        XCTAssertEqual(conversations.map(\.id), [conversation.id])
        XCTAssertEqual(conversations.first?.kind, .text)
        XCTAssertEqual(conversations.first?.updatedAt, secondDate)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["现在感觉怎么样？", "空气湿度目前比较稳定。"])
        XCTAssertEqual(messages.first?.imageAttachments, [imageAttachment])
        XCTAssertTrue(messages.last?.imageAttachments.isEmpty == true)
        XCTAssertEqual(messages.last?.toolInvocations, [invocation])

        try await database.deleteConversation(id: conversation.id)
        let remainingConversations = try await database.allConversations()
        let remainingMessages = try await database.chatMessages(conversationID: conversation.id)
        XCTAssertTrue(remainingConversations.isEmpty)
        XCTAssertTrue(remainingMessages.isEmpty)
    }

    func testLegacyDataURLImageSchemaRepairsWithoutLosingHistory() async throws {
        let path = temporaryDatabasePath()
        _ = try PlantDatabase(path: path)

        let conversationID = UUID()
        let legacyMessageID = UUID()
        let legacyImageData = Data([0x01, 0x02, 0x03, 0x04])
        let legacyDataURL = "data:image/png;base64,\(legacyImageData.base64EncodedString())"
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "DROP INDEX ai_message_images_message_position")
            try db.execute(sql: "DROP TABLE ai_message_images")
            try db.create(table: "ai_message_images") { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text)
                    .notNull()
                    .references("ai_messages", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("data_url", .text).notNull()
                table.uniqueKey(["message_id", "position"])
            }
            try db.create(
                index: "ai_message_images_message_position",
                on: "ai_message_images",
                columns: ["message_id", "position"]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_conversations (
                        id, title, created_at, updated_at, kind
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conversationID.uuidString,
                    "旧版图片对话",
                    baseDate,
                    baseDate,
                    AIConversationKind.text.rawValue
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_messages (
                        id, conversation_id, role, content, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    legacyMessageID.uuidString,
                    conversationID.uuidString,
                    ChatRole.user.rawValue,
                    "旧版图片",
                    baseDate
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_memory_message_sequences (message_id)
                    VALUES (?)
                    """,
                arguments: [legacyMessageID.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_message_images (
                        id, message_id, position, data_url
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    "legacy-image",
                    legacyMessageID.uuidString,
                    0,
                    legacyDataURL
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM grdb_migrations
                    WHERE identifier = 'repair legacy ai message image storage'
                    """
            )
        }

        let repairedDatabase = try PlantDatabase(path: path)
        var messages = try await repairedDatabase.chatMessages(
            conversationID: conversationID
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "旧版图片")
        XCTAssertEqual(messages.first?.imageAttachments, [ChatImageAttachment(
            id: "legacy-image",
            mimeType: "image/png",
            data: legacyImageData
        )])

        let newImage = ChatImageAttachment(
            id: "new-image",
            mimeType: "image/jpeg",
            data: Data([0x05, 0x06, 0x07])
        )
        try await repairedDatabase.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: "迁移后的新图片",
            createdAt: baseDate.addingTimeInterval(1),
            imageAttachments: [newImage]
        ))

        messages = try await repairedDatabase.chatMessages(
            conversationID: conversationID
        )
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.imageAttachments, [newImage])
    }

    // MARK: - 跨端删除：ID 大小写

    /// Web 生成的 ID 是小写，`UUID.uuidString` 是大写，SQLite 的 = 对 TEXT 大小写
    /// 敏感。删除意图因此匹配不到本地行——记录看着"删不掉"。
    func testLowercaseRemoteTombstoneDeletesLocalConversation() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let conversation = try await database.createConversation(title: "网页建的对话", kind: .text)
        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            role: .user,
            content: "你好",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))

        let removed = try await database.applyRemoteDeletions([
            SyncTombstone(
                type: .conversation,
                entityID: conversation.id.uuidString.lowercased(),
                conversationID: nil,
                deletedAt: Date(),
                pendingPush: false
            )
        ])

        XCTAssertEqual(removed.conversations, 1, "小写墓碑没能删掉本地大写主键的那一行")
        let survivors = try await database.allConversations()
        XCTAssertTrue(survivors.isEmpty)
    }

    func testLowercaseRemoteTombstoneDeletesSingleMessage() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let conversation = try await database.createConversation(title: "对话", kind: .text)
        let doomed = UUID()
        for (index, id) in [doomed, UUID()].enumerated() {
            try await database.saveChatMessage(ChatMessage(
                id: id,
                conversationID: conversation.id,
                role: .user,
                content: "第 \(index) 条",
                createdAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(index))
            ))
        }

        let removed = try await database.applyRemoteDeletions([
            SyncTombstone(
                type: .message,
                entityID: doomed.uuidString.lowercased(),
                conversationID: nil,
                deletedAt: Date(),
                pendingPush: false
            )
        ])

        XCTAssertEqual(removed.messages, 1)
        let remaining = try await database.chatMessages(conversationID: conversation.id)
        XCTAssertEqual(remaining.count, 1, "删一条消息不应带走整个会话")
    }

    /// 本地删除要以规范小写记入墓碑，否则推到云端也匹配不上对方那一行。
    func testLocalDeletionRecordsCanonicalLowercaseTombstone() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let conversation = try await database.createConversation(title: "对话", kind: .text)
        try await database.deleteConversation(id: conversation.id)

        let tombstones = try await database.pendingTombstones()
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertEqual(tombstones.first?.entityID, conversation.id.uuidString.lowercased())
    }

    /// 云端回传大写 ID 时不能建出第二条会话，也不能重复插消息。
    func testEnsureConversationMatchesExistingRowIgnoringCase() async throws {
        let database = try PlantDatabase(path: temporaryDatabasePath())
        let conversation = try await database.createConversation(title: "本地对话", kind: .text)
        let messageID = UUID()
        try await database.saveChatMessage(ChatMessage(
            id: messageID,
            conversationID: conversation.id,
            role: .user,
            content: "你好",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))

        // 用小写 ID 走一遍拉取路径：UUID 本身大小写无关，验证的是"不算新增"。
        let ensured = try await database.ensureConversation(id: conversation.id, kind: .text)
        XCTAssertFalse(ensured.created, "已存在的会话不能报成新增")

        let inserted = try await database.insertMessageIfNotExist(
            id: messageID,
            conversationID: conversation.id,
            role: .user,
            content: "你好",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertFalse(inserted, "已存在的消息不能报成新增，否则摘要每次都显示同一批数字")
        let conversations = try await database.allConversations()
        XCTAssertEqual(conversations.count, 1)
    }

    /// 老库里的大写墓碑要在迁移时折叠成小写，且未推送状态不能丢。
    func testMigrationCanonicalizesLegacyUppercaseTombstones() async throws {
        let uppercase = UUID().uuidString
        let path = try legacyDatabasePathWithUppercaseTombstone(uppercase)

        let migrated = try PlantDatabase(path: path)
        let tombstones = try await migrated.allTombstones()

        XCTAssertEqual(tombstones.map(\.entityID), [uppercase.lowercased()])
        XCTAssertTrue(tombstones.first?.pendingPush ?? false, "还没推送成功的删除不能被标记为已同步")
    }

    /// 同一条记录留下大小写两条墓碑时，合并后仍需推送，删除时间取更早的那次。
    func testMigrationMergesTombstonePairKeepingPendingPush() async throws {
        let uppercase = UUID().uuidString
        let path = try legacyDatabasePathWithUppercaseTombstone(
            uppercase,
            alsoLowercase: (deletedAt: 1_750_000_000, pendingPush: false),
            uppercaseDeletedAt: 1_750_000_500,
            uppercasePendingPush: true
        )

        let migrated = try PlantDatabase(path: path)
        let tombstones = try await migrated.allTombstones()

        XCTAssertEqual(tombstones.count, 1, "两种写法指向同一条记录，只该留一条墓碑")
        XCTAssertTrue(tombstones.first?.pendingPush ?? false)
        XCTAssertEqual(
            tombstones.first?.deletedAt,
            Date(timeIntervalSince1970: 1_750_000_000),
            "删除时间应取更早的那次"
        )
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
    }

    /// 造一个跑到"track sync deletions"为止的库，里面存着大写写法的墓碑，
    /// 用来验证后续的规范化迁移。
    private func legacyDatabasePathWithUppercaseTombstone(
        _ uppercaseID: String,
        alsoLowercase lowercase: (deletedAt: Double, pendingPush: Bool)? = nil,
        uppercaseDeletedAt: Double = 1_750_000_000,
        uppercasePendingPush: Bool = true
    ) throws -> String {
        let path = temporaryDatabasePath()
        let queue = try DatabaseQueue(path: path)
        // 先用真实迁移器把库建到"墓碑表刚建好"的状态：规范化迁移还没跑，
        // 正式打开这个库时才会执行，正是要验证的场景。
        try PlantDatabase.migratorForTests.migrate(queue, upTo: "track sync deletions")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_tombstones (
                        entity_type, entity_id, conversation_id, deleted_at, pending_push
                    ) VALUES ('conversation', ?, NULL, ?, ?)
                    """,
                arguments: [
                    uppercaseID,
                    Date(timeIntervalSince1970: uppercaseDeletedAt),
                    uppercasePendingPush
                ]
            )
            if let lowercase {
                try db.execute(
                    sql: """
                        INSERT INTO sync_tombstones (
                            entity_type, entity_id, conversation_id, deleted_at, pending_push
                        ) VALUES ('conversation', ?, NULL, ?, ?)
                        """,
                    arguments: [
                        uppercaseID.lowercased(),
                        Date(timeIntervalSince1970: lowercase.deletedAt),
                        lowercase.pendingPush
                    ]
                )
            }
        }
        return path
    }

    private func legacyDatabasePathWithDeletedHighWaterMessage() throws -> String {
        let path = temporaryDatabasePath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            for identifier in [
                "create sensor history",
                "add timestamp quality",
                "create ai conversations",
                "classify ai conversations",
                "store ai tool invocations"
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
            try db.execute(sql: """
                CREATE TABLE ai_conversations (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'text'
                )
                """)
            try db.execute(sql: """
                CREATE TABLE ai_messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL
                        REFERENCES ai_conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO ai_conversations (
                    id, title, created_at, updated_at, kind
                ) VALUES
                    ('retained', '保留', 1, 1, 'text'),
                    ('deleted', '删除', 2, 2, 'text')
                """)
            try db.execute(sql: """
                INSERT INTO ai_messages (
                    id, conversation_id, role, content, created_at
                ) VALUES
                    ('legacy-1', 'retained', 'user', '旧消息一', 1),
                    ('legacy-2', 'deleted', 'user', '旧消息二', 2)
                """)
            try db.execute(sql: "DELETE FROM ai_conversations WHERE id = 'deleted'")
        }
        return path
    }

    func testConversationsCanBeFilteredByKind() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let text = try await database.createConversation(title: "文字对话")
        let realtime = try await database.createConversation(
            title: "实时语音对话",
            kind: .realtime
        )

        let textConversations = try await database.allConversations(kind: .text)
        let realtimeConversations = try await database.allConversations(kind: .realtime)

        XCTAssertEqual(textConversations.map(\.id), [text.id])
        XCTAssertEqual(realtimeConversations.map(\.id), [realtime.id])
    }

    func testDeletingInterruptedTurnRemovesBothMessagesAndEmptyConversation() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let conversation = try await database.createConversation(title: "会被停止的对话")
        let userID = UUID()
        let assistantID = UUID()

        try await database.saveChatMessage(ChatMessage(
            id: userID,
            conversationID: conversation.id,
            role: .user,
            content: "这个问题不要保留",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
        try await database.saveChatMessage(ChatMessage(
            id: assistantID,
            conversationID: conversation.id,
            role: .assistant,
            content: "未完成的回答",
            createdAt: Date(timeIntervalSince1970: 1_750_000_001)
        ))

        let deletedConversation = try await database.deleteChatTurn(
            conversationID: conversation.id,
            messageIDs: [userID, assistantID]
        )
        let remainingConversations = try await database.allConversations()
        let remainingMessages = try await database.chatMessages(conversationID: conversation.id)

        XCTAssertTrue(deletedConversation)
        XCTAssertTrue(remainingConversations.isEmpty)
        XCTAssertTrue(remainingMessages.isEmpty)
    }

    func testDeletingInterruptedTurnKeepsEarlierMessagesAndRestoresUpdatedDate() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let conversation = try await database.createConversation(title: "保留较早轮次")
        let retainedID = UUID()
        let stoppedID = UUID()
        let retainedDate = Date(timeIntervalSince1970: 1_750_000_000)

        try await database.saveChatMessage(ChatMessage(
            id: retainedID,
            conversationID: conversation.id,
            role: .user,
            content: "保留我",
            createdAt: retainedDate
        ))
        try await database.saveChatMessage(ChatMessage(
            id: stoppedID,
            conversationID: conversation.id,
            role: .user,
            content: "删除我",
            createdAt: retainedDate.addingTimeInterval(1)
        ))

        let deletedConversation = try await database.deleteChatTurn(
            conversationID: conversation.id,
            messageIDs: [stoppedID]
        )
        let messages = try await database.chatMessages(conversationID: conversation.id)
        let conversations = try await database.allConversations()
        let storedConversation = try XCTUnwrap(
            conversations.first(where: { $0.id == conversation.id })
        )

        XCTAssertFalse(deletedConversation)
        XCTAssertEqual(messages.map(\.id), [retainedID])
        XCTAssertEqual(storedConversation.updatedAt, retainedDate)
    }

    func testHistoryObservationPublishesCommittedWrites() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let observation = await database.historyReadingsObservation()
        var iterator = observation.makeAsyncIterator()

        let initial = try await iterator.next()
        XCTAssertEqual(initial, [])
        let now = Date()

        _ = try await database.saveHistoryBatch(
            [HistoryReading(
                sequence: 1,
                recordedAt: now,
                timestampEstimated: false,
                soilRaw: 2000,
                temperature: 25,
                humidity: 60,
                lightLux: nil
            )],
            deviceID: "observed-device",
            acknowledgedThrough: 1
        )

        let updated = try await iterator.next()
        XCTAssertEqual(updated?.map(\.sequence), [1])
    }

    func testBatchSaveIsIdempotentAndAdvancesCursor() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let readings = [
            HistoryReading(
                sequence: 10,
                recordedAt: Date(timeIntervalSince1970: 1_750_000_000),
                timestampEstimated: false,
                soilRaw: 2000,
                temperature: 25.5,
                humidity: 61,
                lightLux: nil
            ),
            HistoryReading(
                sequence: 11,
                recordedAt: Date(timeIntervalSince1970: 1_750_000_300),
                timestampEstimated: false,
                soilRaw: 2010,
                temperature: 25.6,
                humidity: 60.8,
                lightLux: 500
            )
        ]

        let first = try await database.saveHistoryBatch(
            readings,
            deviceID: "test-device",
            acknowledgedThrough: 11
        )
        let second = try await database.saveHistoryBatch(
            readings,
            deviceID: "test-device",
            acknowledgedThrough: 11
        )

        XCTAssertEqual(first.insertedCount, 2)
        XCTAssertEqual(second.insertedCount, 0)
        let count = try await database.readingCount(for: "test-device")
        let sequence = try await database.lastSequence(for: "test-device")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(sequence, 11)

        let storedReadings = try await database.allHistoryReadings()
        XCTAssertEqual(storedReadings.map(\.sequence), [11, 10])

        let dayStart = Calendar.current.startOfDay(for: readings[0].recordedAt)
        let dailyReadings = try await database.historyReadings(for: dayStart)
        XCTAssertEqual(dailyReadings.map(\.sequence), [11, 10])
        XCTAssertEqual(storedReadings.first?.lightLux, 500)
    }

    func testHistoryDeletionSupportsSingleReadingDayAndClearAll() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let calendar = Calendar.current
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2025,
            month: 7,
            day: 18,
            hour: 8
        )))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let readings = [
            HistoryReading(
                sequence: 1,
                recordedAt: firstDay,
                timestampEstimated: false,
                soilRaw: 1_900,
                temperature: 24,
                humidity: 60,
                lightLux: 400
            ),
            HistoryReading(
                sequence: 2,
                recordedAt: firstDay.addingTimeInterval(300),
                timestampEstimated: false,
                soilRaw: 1_910,
                temperature: 24.2,
                humidity: 59,
                lightLux: 420
            ),
            HistoryReading(
                sequence: 3,
                recordedAt: secondDay,
                timestampEstimated: false,
                soilRaw: 1_920,
                temperature: 24.4,
                humidity: 58,
                lightLux: 440
            )
        ]
        _ = try await database.saveHistoryBatch(
            readings,
            deviceID: "deletion-device",
            acknowledgedThrough: 3
        )

        let firstDayStart = calendar.startOfDay(for: firstDay)
        var firstDayReadings = try await database.historyReadings(for: firstDayStart)
        let newestID = try XCTUnwrap(firstDayReadings.first?.databaseID)
        try await database.deleteHistoryReading(id: newestID)
        firstDayReadings = try await database.historyReadings(for: firstDayStart)
        XCTAssertEqual(firstDayReadings.map(\.sequence), [1])

        try await database.deleteHistoryReadings(for: firstDayStart)
        let deletedDayReadings = try await database.historyReadings(for: firstDayStart)
        let remainingReadings = try await database.allHistoryReadings()
        XCTAssertTrue(deletedDayReadings.isEmpty)
        XCTAssertEqual(remainingReadings.map(\.sequence), [3])

        _ = try await database.createConversation(title: "文字", kind: .text)
        _ = try await database.createConversation(title: "语音", kind: .realtime)
        try await database.deleteAllHistory()

        let clearedReadings = try await database.allHistoryReadings()
        let clearedConversations = try await database.allConversations()
        let retainedCursor = try await database.lastSequence(for: "deletion-device")
        XCTAssertTrue(clearedReadings.isEmpty)
        XCTAssertTrue(clearedConversations.isEmpty)
        XCTAssertEqual(retainedCursor, 3)
    }

    func testDeviceScopedHistoricalQueryInterfaces() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let firstDate = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2025,
            month: 6,
            day: 15,
            hour: 10
        )))
        let secondDate = firstDate.addingTimeInterval(3_600)
        let endDate = secondDate.addingTimeInterval(3_600)

        _ = try await database.saveHistoryBatch(
            [
                HistoryReading(
                    sequence: 1,
                    recordedAt: firstDate,
                    timestampEstimated: false,
                    soilRaw: 1_000,
                    temperature: 20,
                    humidity: 50,
                    lightLux: nil
                ),
                HistoryReading(
                    sequence: 2,
                    recordedAt: secondDate,
                    timestampEstimated: true,
                    soilRaw: 2_000,
                    temperature: 26,
                    humidity: 70,
                    lightLux: 600
                )
            ],
            deviceID: "plant-a",
            acknowledgedThrough: 2
        )
        _ = try await database.saveHistoryBatch(
            [HistoryReading(
                sequence: 1,
                recordedAt: firstDate.addingTimeInterval(1_800),
                timestampEstimated: false,
                soilRaw: 3_000,
                temperature: 99,
                humidity: 1,
                lightLux: 1_000
            )],
            deviceID: "plant-b",
            acknowledgedThrough: 1
        )

        let latest = try await database.latestHistoricalReading(for: "plant-a")
        let summary = try await database.sensorSummary(
            for: "plant-a",
            from: firstDate,
            to: endDate
        )
        let hourly = try await database.sensorSeries(
            for: "plant-a",
            from: firstDate,
            to: endDate,
            granularity: .hour
        )
        let fiveMinutes = try await database.sensorSeries(
            for: "plant-a",
            from: firstDate,
            to: endDate,
            granularity: .fiveMinutes
        )
        let daily = try await database.sensorSeries(
            for: "plant-a",
            from: firstDate,
            to: endDate,
            granularity: .day
        )
        let emptySummary = try await database.sensorSummary(
            for: "missing-plant",
            from: firstDate,
            to: endDate
        )
        let missingLatest = try await database.latestHistoricalReading(for: "missing-plant")

        XCTAssertEqual(latest?.sequence, 2)
        XCTAssertEqual(summary.readingCount, 2)
        XCTAssertEqual(summary.estimatedTimestampCount, 1)
        XCTAssertEqual(summary.firstReading?.sequence, 1)
        XCTAssertEqual(summary.lastReading?.sequence, 2)
        XCTAssertEqual(summary.temperature.average, 23)
        XCTAssertEqual(summary.temperature.minimum, 20)
        XCTAssertEqual(summary.temperature.maximum, 26)
        XCTAssertEqual(summary.soilRaw.average, 1_500)
        XCTAssertEqual(summary.lightLux.average, 600)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertEqual(hourly.map(\.temperature.average), [20, 26])
        XCTAssertEqual(hourly.map(\.readingCount), [1, 1])
        XCTAssertEqual(fiveMinutes.count, 2)
        XCTAssertEqual(fiveMinutes.map(\.temperature.average), [20, 26])
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.readingCount, 2)
        XCTAssertEqual(daily.first?.temperature.average, 23)
        XCTAssertEqual(emptySummary.readingCount, 0)
        XCTAssertNil(emptySummary.firstReading)
        XCTAssertNil(emptySummary.temperature.average)
        XCTAssertNil(missingLatest)
    }

    func testFiveMinuteSeriesFloorsLocalFiveMinuteBuckets() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 13,
            hour: 10
        )))
        let sampleOffsets: [(TimeInterval, UInt32, Double)] = [
            (2 * 60, 1, 20),
            (4 * 60, 2, 24),
            (5 * 60, 3, 30),
            (9 * 60, 4, 34)
        ]
        let samples: [HistoryReading] = sampleOffsets.map { offset, sequence, temperature in
            HistoryReading(
                sequence: sequence,
                recordedAt: start.addingTimeInterval(offset),
                timestampEstimated: false,
                soilRaw: 1_000,
                temperature: temperature,
                humidity: 60,
                lightLux: 100
            )
        }
        _ = try await database.saveHistoryBatch(
            samples,
            deviceID: "five-minute-device",
            acknowledgedThrough: 4
        )

        let series = try await database.sensorSeries(
            for: "five-minute-device",
            from: start,
            to: start.addingTimeInterval(10 * 60),
            granularity: .fiveMinutes
        )

        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.map(\.readingCount), [2, 2])
        XCTAssertEqual(series.map { $0.temperature.average }, [22, 32])
        XCTAssertEqual(
            series.map { calendar.component(.minute, from: $0.bucketStart) },
            [0, 5]
        )
    }

    @MainActor
    func testToolExecutorReturnsDeviceScopedNormalizedData() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 13,
            hour: 12
        )))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let firstReadingDate = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday))
        let secondReadingDate = firstReadingDate.addingTimeInterval(300)
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
                    recordedAt: secondReadingDate,
                    timestampEstimated: false,
                    soilRaw: 1_300,
                    temperature: 26,
                    humidity: 56,
                    lightLux: 110
                )
            ],
            deviceID: "tool-device",
            acknowledgedThrough: 2
        )
        let executor = PlantDataToolExecutor(
            database: database,
            deviceIDProvider: { "tool-device" },
            currentReadingProvider: {
                PlantReading(
                    temperature: 25,
                    humidity: 60,
                    soilRaw: 1_250,
                    lightLux: 300,
                    receivedAt: now
                )
            },
            nowProvider: { now },
            calendar: calendar
        )

        let summary = await executor.execute(AIModelToolCall(
            id: "summary-call",
            type: "function",
            function: .init(
                name: "get_sensor_summary",
                arguments: #"{"period":"yesterday","metrics":["temperature"]}"#
            )
        ))
        let series = await executor.execute(AIModelToolCall(
            id: "series-call",
            type: "function",
            function: .init(
                name: "get_sensor_series",
                arguments: #"{"period":"yesterday","metrics":["temperature"],"granularity":"five_minutes"}"#
            )
        ))
        let live = await executor.execute(AIModelToolCall(
            id: "live-call",
            type: "function",
            function: .init(name: "get_current_sensor_reading", arguments: "{}")
        ))

        XCTAssertEqual(summary.toolName, "get_sensor_summary")
        XCTAssertTrue(summary.summary.contains("温度"))
        XCTAssertTrue(summary.resultJSON.contains("\"average\" : 24"))
        XCTAssertEqual(series.toolName, "get_sensor_series")
        XCTAssertTrue(series.summary.contains("5 分钟趋势"))
        XCTAssertTrue(series.resultJSON.contains("\"bucket_count\" : 2"))
        XCTAssertTrue(series.resultJSON.contains("\"bucket_start_local\""))
        XCTAssertTrue(series.resultJSON.contains("\"is_partial_bucket\""))
        XCTAssertEqual(live.toolName, "get_current_sensor_reading")
        XCTAssertTrue(live.resultJSON.contains("\"source\" : \"live_bluetooth\""))
    }

    @MainActor
    func testImmediateSamplingToolReturnsFreshExtraSampleMetadata() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let requestedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let sampledAt = requestedAt.addingTimeInterval(0.4)
        let freshReading = PlantReading(
            temperature: 24.8,
            humidity: 58.2,
            soilRaw: 1_480,
            lightLux: 412,
            receivedAt: sampledAt
        )
        let executor = PlantDataToolExecutor(
            database: database,
            deviceIDProvider: { "tool-device" },
            currentReadingProvider: { nil },
            immediateReadingRequester: { freshReading },
            nowProvider: { requestedAt }
        )

        let invocation = await executor.execute(AIModelToolCall(
            id: "immediate-sample-call",
            type: "function",
            function: .init(name: "refresh_current_sensor_reading", arguments: "{}")
        ))

        XCTAssertEqual(invocation.toolName, "refresh_current_sensor_reading")
        XCTAssertTrue(invocation.summary.contains("立即采样"))
        XCTAssertTrue(invocation.resultJSON.contains("\"source\" : \"on_demand_bluetooth\""))
        XCTAssertTrue(invocation.resultJSON.contains("\"acquisition\" : \"manual_extra_sample\""))
        XCTAssertTrue(invocation.resultJSON.contains("\"sampling_schedule\" : \"unchanged_five_minute_cadence\""))
        XCTAssertTrue(invocation.resultJSON.contains("\"soil_adc_raw\" : 1480"))
    }
}

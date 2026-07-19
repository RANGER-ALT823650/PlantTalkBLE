import Foundation
import GRDB

struct HistoryReading: Equatable, Sendable {
    let sequence: UInt32
    let recordedAt: Date
    let timestampEstimated: Bool
    let soilRaw: UInt16
    let temperature: Double?
    let humidity: Double?
    let lightLux: Double?
    let databaseID: Int64?

    init(
        sequence: UInt32,
        recordedAt: Date,
        timestampEstimated: Bool,
        soilRaw: UInt16,
        temperature: Double?,
        humidity: Double?,
        lightLux: Double?,
        databaseID: Int64? = nil
    ) {
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.timestampEstimated = timestampEstimated
        self.soilRaw = soilRaw
        self.temperature = temperature
        self.humidity = humidity
        self.lightLux = lightLux
        self.databaseID = databaseID
    }
}

struct HistorySaveResult: Equatable, Sendable {
    let receivedCount: Int
    let insertedCount: Int
    let durableSequence: UInt32
}

struct DailySummary: Equatable, Sendable, Identifiable {
    let date: Date            // start-of-day in local calendar
    let readingCount: Int
    let avgTemperature: Double?
    let avgHumidity: Double?
    let avgSoilRaw: Double?
    let avgLightLux: Double?

    var id: Date { date }
}

/// One persisted text or realtime transcript message waiting to be considered
/// by the launch-time memory organizer. `sequence` comes from a dedicated
/// AUTOINCREMENT table, so deleting recent chats can never make the cursor move
/// backward or cause a future message to reuse an already-processed position.
struct AIMemoryHistoryMessage: Equatable, Sendable {
    let sequence: Int64
    let conversationKind: AIConversationKind
    let role: ChatRole
    let content: String
    let createdAt: Date
}

/// Aggregate values for one sensor metric. A nil value means no valid samples
/// were recorded for that metric in the requested time range.
struct SensorMetricStatistics: Equatable, Sendable {
    let average: Double?
    let minimum: Double?
    let maximum: Double?
}

/// A device-scoped, bounded summary intended for history views and AI tools.
/// `end` is exclusive, matching the SQL range used to create the summary.
struct SensorHistorySummary: Equatable, Sendable {
    let deviceID: String
    let start: Date
    let end: Date
    let readingCount: Int
    let estimatedTimestampCount: Int
    let firstReading: HistoryReading?
    let lastReading: HistoryReading?
    let temperature: SensorMetricStatistics
    let humidity: SensorMetricStatistics
    let soilRaw: SensorMetricStatistics
    let lightLux: SensorMetricStatistics
}

enum SensorSeriesGranularity: String, CaseIterable, Codable, Equatable, Sendable {
    case fiveMinutes = "five_minutes"
    case hour
    case day

    fileprivate var sqliteBucketExpression: String {
        switch self {
        case .fiveMinutes:
            "datetime((CAST(strftime('%s', recorded_at) AS INTEGER) / 300) * 300, 'unixepoch', 'localtime')"
        case .hour:
            "strftime('%Y-%m-%d %H:00:00', recorded_at, 'localtime')"
        case .day:
            "strftime('%Y-%m-%d 00:00:00', recorded_at, 'localtime')"
        }
    }

    fileprivate var dateFormat: String {
        switch self {
        case .fiveMinutes: "yyyy-MM-dd HH:mm:ss"
        case .hour: "yyyy-MM-dd HH:mm:ss"
        case .day: "yyyy-MM-dd HH:mm:ss"
        }
    }
}

/// One local-calendar bucket in a device-scoped sensor trend.
struct SensorSeriesPoint: Equatable, Sendable, Identifiable {
    let bucketStart: Date
    let readingCount: Int
    let estimatedTimestampCount: Int
    let temperature: SensorMetricStatistics
    let humidity: SensorMetricStatistics
    let soilRaw: SensorMetricStatistics
    let lightLux: SensorMetricStatistics

    var id: Date { bucketStart }
}

enum PlantDatabaseError: LocalizedError, Equatable {
    case invalidHistoryRange
    case invalidSeriesBucket

    var errorDescription: String? {
        switch self {
        case .invalidHistoryRange:
            "传感器历史查询的结束时间必须晚于开始时间。"
        case .invalidSeriesBucket:
            "无法解析传感器趋势的时间分桶。"
        }
    }
}

/// Owns all SQLite access. Calls enter GRDB's asynchronous writer and never run
/// SQLite work on CoreBluetooth's main-actor callbacks.
actor PlantDatabase {
    private let writer: DatabasePool

    init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        writer = try DatabasePool(path: path, configuration: configuration)
        try Self.makeMigrator().migrate(writer)
    }

    static func makeDefault() throws -> PlantDatabase {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PlantTalk", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try PlantDatabase(path: directory.appendingPathComponent("plant-talk.sqlite").path)
    }

    func lastSequence(for deviceID: String) async throws -> UInt32 {
        try await writer.read { db in
            let value = try Int64.fetchOne(
                db,
                sql: "SELECT last_sequence FROM device_sync_state WHERE device_id = ?",
                arguments: [deviceID]
            ) ?? 0
            return UInt32(clamping: value)
        }
    }

    func readingCount(for deviceID: String) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sensor_readings WHERE device_id = ?",
                arguments: [deviceID]
            ) ?? 0
        }
    }

    /// Returns each device that has persisted history, newest reading first.
    /// Conversation binding uses this only as the single-plant fallback; it
    /// deliberately refuses to guess once the database contains several plants.
    func historyDeviceIDs() async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT device_id
                    FROM sensor_readings
                    GROUP BY device_id
                    ORDER BY MAX(recorded_at) DESC, device_id ASC
                    """
            )
        }
    }

    func allHistoryReadings() async throws -> [HistoryReading] {
        try await writer.read { db in
            try Self.fetchHistoryReadings(db)
        }
    }

    /// Returns the most recently recorded persisted reading for one device.
    /// This is historical data, not a substitute for a live BLE reading.
    func latestHistoricalReading(for deviceID: String) async throws -> HistoryReading? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, sequence, recorded_at, timestamp_estimated,
                           soil_raw, temperature, humidity, light_lux
                    FROM sensor_readings
                    WHERE device_id = ?
                    ORDER BY recorded_at DESC, sequence DESC
                    LIMIT 1
                    """,
                arguments: [deviceID]
            ) else {
                return nil
            }
            return try Self.makeHistoryReading(from: row)
        }
    }

    /// Returns a bounded, device-scoped aggregate. `end` is exclusive.
    func sensorSummary(
        for deviceID: String,
        from start: Date,
        to end: Date
    ) async throws -> SensorHistorySummary {
        try Self.validateHistoryRange(from: start, to: end)
        return try await writer.read { db in
            let aggregate = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS reading_count,
                           COALESCE(SUM(CASE WHEN timestamp_estimated THEN 1 ELSE 0 END), 0)
                               AS estimated_timestamp_count,
                           AVG(temperature) AS temperature_average,
                           MIN(temperature) AS temperature_minimum,
                           MAX(temperature) AS temperature_maximum,
                           AVG(humidity) AS humidity_average,
                           MIN(humidity) AS humidity_minimum,
                           MAX(humidity) AS humidity_maximum,
                           AVG(soil_raw) AS soil_average,
                           MIN(soil_raw) AS soil_minimum,
                           MAX(soil_raw) AS soil_maximum,
                           AVG(light_lux) AS light_average,
                           MIN(light_lux) AS light_minimum,
                           MAX(light_lux) AS light_maximum
                    FROM sensor_readings
                    WHERE device_id = ? AND recorded_at >= ? AND recorded_at < ?
                    """,
                arguments: [deviceID, start, end]
            )!

            let firstReading = try Self.historyReading(
                in: db,
                deviceID: deviceID,
                start: start,
                end: end,
                descending: false
            )
            let lastReading = try Self.historyReading(
                in: db,
                deviceID: deviceID,
                start: start,
                end: end,
                descending: true
            )

            return SensorHistorySummary(
                deviceID: deviceID,
                start: start,
                end: end,
                readingCount: aggregate["reading_count"],
                estimatedTimestampCount: aggregate["estimated_timestamp_count"],
                firstReading: firstReading,
                lastReading: lastReading,
                temperature: Self.metricStatistics(
                    from: aggregate,
                    average: "temperature_average",
                    minimum: "temperature_minimum",
                    maximum: "temperature_maximum"
                ),
                humidity: Self.metricStatistics(
                    from: aggregate,
                    average: "humidity_average",
                    minimum: "humidity_minimum",
                    maximum: "humidity_maximum"
                ),
                soilRaw: Self.metricStatistics(
                    from: aggregate,
                    average: "soil_average",
                    minimum: "soil_minimum",
                    maximum: "soil_maximum"
                ),
                lightLux: Self.metricStatistics(
                    from: aggregate,
                    average: "light_average",
                    minimum: "light_minimum",
                    maximum: "light_maximum"
                )
            )
        }
    }

    /// Returns hourly or daily local-calendar aggregates for one bounded range.
    /// `end` is exclusive.
    func sensorSeries(
        for deviceID: String,
        from start: Date,
        to end: Date,
        granularity: SensorSeriesGranularity
    ) async throws -> [SensorSeriesPoint] {
        try Self.validateHistoryRange(from: start, to: end)
        return try await writer.read { db in
            let bucket = granularity.sqliteBucketExpression
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(bucket) AS bucket,
                           COUNT(*) AS reading_count,
                           COALESCE(SUM(CASE WHEN timestamp_estimated THEN 1 ELSE 0 END), 0)
                               AS estimated_timestamp_count,
                           AVG(temperature) AS temperature_average,
                           MIN(temperature) AS temperature_minimum,
                           MAX(temperature) AS temperature_maximum,
                           AVG(humidity) AS humidity_average,
                           MIN(humidity) AS humidity_minimum,
                           MAX(humidity) AS humidity_maximum,
                           AVG(soil_raw) AS soil_average,
                           MIN(soil_raw) AS soil_minimum,
                           MAX(soil_raw) AS soil_maximum,
                           AVG(light_lux) AS light_average,
                           MIN(light_lux) AS light_minimum,
                           MAX(light_lux) AS light_maximum
                    FROM sensor_readings
                    WHERE device_id = ? AND recorded_at >= ? AND recorded_at < ?
                    GROUP BY bucket
                    ORDER BY bucket ASC
                    """,
                arguments: [deviceID, start, end]
            )

            return try rows.map { row in
                let bucketText: String = row["bucket"]
                guard let bucketStart = Self.seriesBucketDate(
                    from: bucketText,
                    granularity: granularity
                ) else {
                    throw PlantDatabaseError.invalidSeriesBucket
                }
                return SensorSeriesPoint(
                    bucketStart: bucketStart,
                    readingCount: row["reading_count"],
                    estimatedTimestampCount: row["estimated_timestamp_count"],
                    temperature: Self.metricStatistics(
                        from: row,
                        average: "temperature_average",
                        minimum: "temperature_minimum",
                        maximum: "temperature_maximum"
                    ),
                    humidity: Self.metricStatistics(
                        from: row,
                        average: "humidity_average",
                        minimum: "humidity_minimum",
                        maximum: "humidity_maximum"
                    ),
                    soilRaw: Self.metricStatistics(
                        from: row,
                        average: "soil_average",
                        minimum: "soil_minimum",
                        maximum: "soil_maximum"
                    ),
                    lightLux: Self.metricStatistics(
                        from: row,
                        average: "light_average",
                        minimum: "light_minimum",
                        maximum: "light_maximum"
                    )
                )
            }
        }
    }

    /// Returns per-day aggregates for all days **before** today, newest first.
    func historySummaryByDate() async throws -> [DailySummary] {
        let todayStart = Calendar.current.startOfDay(for: Date())
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DATE(recorded_at, 'localtime') AS day,
                           COUNT(*)          AS cnt,
                           AVG(temperature)  AS avg_temp,
                           AVG(humidity)     AS avg_hum,
                           AVG(soil_raw)     AS avg_soil,
                           AVG(light_lux)    AS avg_lux
                    FROM sensor_readings
                    WHERE recorded_at < ?
                    GROUP BY day
                    ORDER BY day DESC
                    """,
                arguments: [todayStart]
            )
            let calendar = Calendar.current
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = calendar.timeZone
            return rows.compactMap { row -> DailySummary? in
                let dayString: String = row["day"]
                guard let dayDate = formatter.date(from: dayString) else { return nil }
                return DailySummary(
                    date: dayDate,
                    readingCount: row["cnt"],
                    avgTemperature: row["avg_temp"],
                    avgHumidity: row["avg_hum"],
                    avgSoilRaw: row["avg_soil"],
                    avgLightLux: row["avg_lux"]
                )
            }
        }
    }

    /// Returns all readings for a specific calendar day (local time), newest first.
    func historyReadings(for dayStart: Date) async throws -> [HistoryReading] {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, sequence, recorded_at, timestamp_estimated,
                           soil_raw, temperature, humidity, light_lux
                    FROM sensor_readings
                    WHERE recorded_at >= ? AND recorded_at < ?
                    ORDER BY recorded_at DESC, sequence DESC
                    """,
                arguments: [dayStart, dayEnd]
            )
            return rows.map { row in
                let sequence: Int64 = row["sequence"]
                let soilRaw: Int = row["soil_raw"]
                return HistoryReading(
                    sequence: UInt32(clamping: sequence),
                    recordedAt: row["recorded_at"],
                    timestampEstimated: row["timestamp_estimated"],
                    soilRaw: UInt16(clamping: soilRaw),
                    temperature: row["temperature"],
                    humidity: row["humidity"],
                    lightLux: row["light_lux"],
                    databaseID: row["id"]
                )
            }
        }
    }

    func historyReadings(since date: Date) async throws -> [HistoryReading] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, sequence, recorded_at, timestamp_estimated,
                           soil_raw, temperature, humidity, light_lux
                    FROM sensor_readings
                    WHERE recorded_at >= ?
                    ORDER BY recorded_at ASC
                    """,
                arguments: [date]
            )
            return rows.map { row in
                let sequence: Int64 = row["sequence"]
                let soilRaw: Int = row["soil_raw"]
                return HistoryReading(
                    sequence: UInt32(clamping: sequence),
                    recordedAt: row["recorded_at"],
                    timestampEstimated: row["timestamp_estimated"],
                    soilRaw: UInt16(clamping: soilRaw),
                    temperature: row["temperature"],
                    humidity: row["humidity"],
                    lightLux: row["light_lux"],
                    databaseID: row["id"]
                )
            }
        }
    }

    func createConversation(
        title: String,
        kind: AIConversationKind = .text
    ) async throws -> AIConversation {
        let now = Date()
        let conversation = AIConversation(
            id: UUID(),
            title: title,
            kind: kind,
            createdAt: now,
            updatedAt: now
        )
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_conversations (id, title, kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    conversation.id.uuidString,
                    conversation.title,
                    conversation.kind.rawValue,
                    conversation.createdAt,
                    conversation.updatedAt
                ]
            )
        }
        return conversation
    }

    func allConversations(kind: AIConversationKind? = nil) async throws -> [AIConversation] {
        try await writer.read { db in
            let rows: [Row]
            if let kind {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, title, kind, created_at, updated_at
                        FROM ai_conversations
                        WHERE kind = ?
                        ORDER BY updated_at DESC
                        """,
                    arguments: [kind.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, title, kind, created_at, updated_at
                        FROM ai_conversations
                        ORDER BY updated_at DESC
                        """
                )
            }
            return rows.compactMap(Self.makeConversation)
        }
    }

    func chatMessages(conversationID: UUID) async throws -> [ChatMessage] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, conversation_id, role, content, created_at
                    FROM ai_messages
                    WHERE conversation_id = ?
                    ORDER BY created_at ASC, rowid ASC
                    """,
                arguments: [conversationID.uuidString]
            )
            let invocationRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT invocations.id, invocations.message_id, invocations.provider_call_id,
                           invocations.tool_name, invocations.summary,
                           invocations.arguments_json, invocations.result_json,
                           invocations.executed_at
                    FROM ai_message_tool_invocations AS invocations
                    INNER JOIN ai_messages AS messages ON messages.id = invocations.message_id
                    WHERE messages.conversation_id = ?
                    ORDER BY messages.created_at ASC, messages.rowid ASC, invocations.position ASC
                    """,
                arguments: [conversationID.uuidString]
            )
            let imageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT images.id, images.message_id, images.mime_type, images.data
                    FROM ai_message_images AS images
                    INNER JOIN ai_messages AS messages ON messages.id = images.message_id
                    WHERE messages.conversation_id = ?
                    ORDER BY messages.created_at ASC, messages.rowid ASC, images.position ASC
                    """,
                arguments: [conversationID.uuidString]
            )
            let invocationsByMessageID = Dictionary(
                grouping: invocationRows.compactMap { Self.makeToolInvocation($0) },
                by: \.messageID
            ).mapValues { $0.map(\.invocation) }
            let imagesByMessageID = Dictionary(
                grouping: imageRows.compactMap { Self.makeChatImageAttachment($0) },
                by: \.messageID
            ).mapValues { $0.map(\.attachment) }
            return rows.compactMap { row in
                let messageID: String = row["id"]
                guard let id = UUID(uuidString: messageID) else { return nil }
                return Self.makeChatMessage(
                    row,
                    imageAttachments: imagesByMessageID[id] ?? [],
                    toolInvocations: invocationsByMessageID[id] ?? []
                )
            }
        }
    }

    func memoryHistoryMessages(
        afterSequence: Int64,
        limit: Int
    ) async throws -> [AIMemoryHistoryMessage] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT memory_order.sequence AS memory_sequence,
                           conversations.kind AS conversation_kind,
                           messages.role, messages.content, messages.created_at
                    FROM ai_memory_message_sequences AS memory_order
                    INNER JOIN ai_messages AS messages
                        ON messages.id = memory_order.message_id
                    INNER JOIN ai_conversations AS conversations
                        ON conversations.id = messages.conversation_id
                    WHERE memory_order.sequence > ?
                    ORDER BY memory_order.sequence ASC
                    LIMIT ?
                    """,
                arguments: [afterSequence, max(1, limit)]
            )
            return rows.compactMap { row in
                let roleText: String = row["role"]
                let kindText: String = row["conversation_kind"]
                guard let role = ChatRole(rawValue: roleText),
                      let kind = AIConversationKind(rawValue: kindText) else {
                    return nil
                }
                return AIMemoryHistoryMessage(
                    sequence: row["memory_sequence"],
                    conversationKind: kind,
                    role: role,
                    content: row["content"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    /// Converts the cursor used by schema-v1 memory files. During migration,
    /// existing message row ids are copied into both sequence columns, so the
    /// greatest surviving row at or below the old cursor is the exact durable
    /// position from which incremental organization should resume.
    func memorySequence(forLegacyRowID rowID: Int64) async throws -> Int64 {
        try await writer.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(sequence)
                    FROM ai_memory_message_sequences
                    WHERE legacy_row_id <= ?
                    """,
                arguments: [rowID]
            ) ?? 0
        }
    }

    func saveChatMessage(_ message: ChatMessage) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_messages (
                        id, conversation_id, role, content, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    message.id.uuidString,
                    message.conversationID.uuidString,
                    message.role.rawValue,
                    message.content,
                    message.createdAt
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_memory_message_sequences (message_id)
                    VALUES (?)
                    """,
                arguments: [message.id.uuidString]
            )
            for (position, attachment) in message.imageAttachments.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO ai_message_images (
                            id, message_id, position, mime_type, data
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        attachment.id,
                        message.id.uuidString,
                        position,
                        attachment.mimeType,
                        attachment.data
                    ]
                )
            }
            for (position, invocation) in message.toolInvocations.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO ai_message_tool_invocations (
                            id, message_id, position, provider_call_id, tool_name,
                            summary, arguments_json, result_json, executed_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        invocation.id.uuidString,
                        message.id.uuidString,
                        position,
                        invocation.providerCallID,
                        invocation.toolName,
                        invocation.summary,
                        invocation.argumentsJSON,
                        invocation.resultJSON,
                        invocation.executedAt
                    ]
                )
            }
            try db.execute(
                sql: "UPDATE ai_conversations SET updated_at = ? WHERE id = ?",
                arguments: [message.createdAt, message.conversationID.uuidString]
            )
        }
    }

    /// Removes one interrupted text turn atomically. Returns `true` when the
    /// conversation became empty and was deleted with it.
    func deleteChatTurn(
        conversationID: UUID,
        messageIDs: [UUID]
    ) async throws -> Bool {
        try await writer.write { db in
            for messageID in Set(messageIDs) {
                try db.execute(
                    sql: "DELETE FROM ai_messages WHERE id = ? AND conversation_id = ?",
                    arguments: [messageID.uuidString, conversationID.uuidString]
                )
            }

            let latestMessageDate = try Date.fetchOne(
                db,
                sql: "SELECT MAX(created_at) FROM ai_messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            )
            guard let latestMessageDate else {
                try db.execute(
                    sql: "DELETE FROM ai_conversations WHERE id = ?",
                    arguments: [conversationID.uuidString]
                )
                return true
            }

            try db.execute(
                sql: "UPDATE ai_conversations SET updated_at = ? WHERE id = ?",
                arguments: [latestMessageDate, conversationID.uuidString]
            )
            return false
        }
    }

    func deleteConversation(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM ai_conversations WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func deleteHistoryReading(id: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM sensor_readings WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func deleteHistoryReadings(for dayStart: Date) async throws {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM sensor_readings WHERE recorded_at >= ? AND recorded_at < ?",
                arguments: [dayStart, dayEnd]
            )
        }
    }

    /// Clears user-visible sensor and conversation history while preserving BLE
    /// sync cursors so records intentionally deleted here are not downloaded again.
    func deleteAllHistory() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM sensor_readings")
            try db.execute(sql: "DELETE FROM ai_conversations")
        }
    }

    /// Emits an initial snapshot and then a fresh array after every committed write.
    /// Only includes readings from **today** (local calendar) to keep the live list compact.
    func historyReadingsObservation() -> AsyncValueObservation<[HistoryReading]> {
        ValueObservation
            .tracking { db in
                let todayStart = Calendar.current.startOfDay(for: Date())
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, sequence, recorded_at, timestamp_estimated,
                               soil_raw, temperature, humidity, light_lux
                        FROM sensor_readings
                        WHERE recorded_at >= ?
                        ORDER BY sequence DESC
                        """,
                    arguments: [todayStart]
                )
                return rows.map { row in
                    let sequence: Int64 = row["sequence"]
                    let soilRaw: Int = row["soil_raw"]
                    return HistoryReading(
                        sequence: UInt32(clamping: sequence),
                        recordedAt: row["recorded_at"],
                        timestampEstimated: row["timestamp_estimated"],
                        soilRaw: UInt16(clamping: soilRaw),
                        temperature: row["temperature"],
                        humidity: row["humidity"],
                        lightLux: row["light_lux"],
                        databaseID: row["id"]
                    )
                }
            }
            .values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    /// Inserts one BLE batch and advances the durable cursor in the same transaction.
    /// The unique key makes reconnect/retry idempotent.
    func saveHistoryBatch(
        _ readings: [HistoryReading],
        deviceID: String,
        acknowledgedThrough sequence: UInt32
    ) async throws -> HistorySaveResult {
        try await writer.write { db in
            var insertedCount = 0
            let statement = try db.makeStatement(sql: """
                INSERT INTO sensor_readings (
                    device_id, sequence, recorded_at, received_at,
                    timestamp_estimated, soil_raw, temperature, humidity, light_lux
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id, sequence) DO NOTHING
                """)
            let receivedAt = Date()

            for reading in readings {
                try statement.execute(arguments: [
                    deviceID,
                    Int64(reading.sequence),
                    reading.recordedAt,
                    receivedAt,
                    reading.timestampEstimated,
                    Int(reading.soilRaw),
                    reading.temperature,
                    reading.humidity,
                    reading.lightLux
                ])
                insertedCount += db.changesCount
            }

            try db.execute(
                sql: """
                    INSERT INTO device_sync_state (device_id, last_sequence, last_sync_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(device_id) DO UPDATE SET
                        last_sequence = MAX(last_sequence, excluded.last_sequence),
                        last_sync_at = excluded.last_sync_at
                    """,
                arguments: [deviceID, Int64(sequence), receivedAt]
            )

            let durable = try Int64.fetchOne(
                db,
                sql: "SELECT last_sequence FROM device_sync_state WHERE device_id = ?",
                arguments: [deviceID]
            ) ?? 0
            return HistorySaveResult(
                receivedCount: readings.count,
                insertedCount: insertedCount,
                durableSequence: UInt32(clamping: durable)
            )
        }
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create sensor history") { db in
            try db.create(table: "sensor_readings") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("device_id", .text).notNull()
                table.column("sequence", .integer).notNull()
                table.column("recorded_at", .datetime).notNull()
                table.column("received_at", .datetime).notNull()
                table.column("soil_raw", .integer).notNull()
                table.column("temperature", .double)
                table.column("humidity", .double)
                table.column("light_lux", .double)
                table.uniqueKey(["device_id", "sequence"])
            }
            try db.create(
                index: "sensor_readings_device_time",
                on: "sensor_readings",
                columns: ["device_id", "recorded_at"]
            )
            try db.create(table: "device_sync_state") { table in
                table.column("device_id", .text).primaryKey()
                table.column("last_sequence", .integer).notNull()
                table.column("last_sync_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("add timestamp quality") { db in
            try db.alter(table: "sensor_readings") { table in
                table.add(column: "timestamp_estimated", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
        }
        migrator.registerMigration("create ai conversations") { db in
            try db.create(table: "ai_conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "ai_conversations_updated_at",
                on: "ai_conversations",
                columns: ["updated_at"]
            )

            try db.create(table: "ai_messages") { table in
                table.column("id", .text).primaryKey()
                table.column("conversation_id", .text)
                    .notNull()
                    .references("ai_conversations", onDelete: .cascade)
                table.column("role", .text).notNull()
                table.column("content", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "ai_messages_conversation_time",
                on: "ai_messages",
                columns: ["conversation_id", "created_at"]
            )
        }
        migrator.registerMigration("classify ai conversations") { db in
            try db.alter(table: "ai_conversations") { table in
                table.add(column: "kind", .text)
                    .notNull()
                    .defaults(to: AIConversationKind.text.rawValue)
            }
            try db.create(
                index: "ai_conversations_kind_updated_at",
                on: "ai_conversations",
                columns: ["kind", "updated_at"]
            )
        }
        migrator.registerMigration("store ai tool invocations") { db in
            try db.create(table: "ai_message_tool_invocations") { table in
                table.column("id", .text).primaryKey()
                table.column("message_id", .text)
                    .notNull()
                    .references("ai_messages", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("provider_call_id", .text)
                table.column("tool_name", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("arguments_json", .text).notNull()
                table.column("result_json", .text).notNull()
                table.column("executed_at", .datetime).notNull()
                table.uniqueKey(["message_id", "position"])
            }
            try db.create(
                index: "ai_message_tool_invocations_message_position",
                on: "ai_message_tool_invocations",
                columns: ["message_id", "position"]
            )
        }
        migrator.registerMigration("add stable ai memory message sequence") { db in
            try db.create(table: "ai_memory_message_sequences") { table in
                table.autoIncrementedPrimaryKey("sequence")
                table.column("message_id", .text)
                    .notNull()
                    .unique()
                    .references("ai_messages", onDelete: .cascade)
                table.column("legacy_row_id", .integer)
            }

            // Preserve the old rowid coordinate system for the one-time cursor
            // conversion while future inserts use a non-reusable sequence.
            try db.execute(sql: """
                INSERT INTO ai_memory_message_sequences (
                    sequence, message_id, legacy_row_id
                )
                SELECT rowid, id, rowid
                FROM ai_messages
                ORDER BY rowid ASC
                """)
        }
        migrator.registerMigration("store ai message images") { db in
            try Self.createAIMessageImagesTable(db)
            try Self.createAIMessageImagesIndex(db)
        }
        migrator.registerMigration("repair legacy ai message image storage") { db in
            guard try db.tableExists("ai_message_images") else {
                try Self.createAIMessageImagesTable(db)
                try Self.createAIMessageImagesIndex(db)
                return
            }

            let columns = Set(try db.columns(in: "ai_message_images").map(\.name))
            guard !columns.isSuperset(of: ["mime_type", "data"]) else { return }

            // An early development build stored the complete data URL in one
            // TEXT column. GRDB records migration identifiers, so changing the
            // old migration body cannot repair devices that already ran it.
            // Rebuild the table under a new migration and preserve every valid
            // legacy image while converting its base64 payload to a BLOB.
            let legacyRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM ai_message_images ORDER BY message_id, position"
            )
            let legacyTable = "ai_message_images_before_blob_storage"
            try db.rename(table: "ai_message_images", to: legacyTable)
            try Self.createAIMessageImagesTable(db)

            for row in legacyRows {
                guard let attachment = Self.makeLegacyChatImageAttachment(row) else {
                    continue
                }
                let messageID: String = row["message_id"]
                let position: Int = row["position"]
                try db.execute(
                    sql: """
                        INSERT INTO ai_message_images (
                            id, message_id, position, mime_type, data
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        attachment.id,
                        messageID,
                        position,
                        attachment.mimeType,
                        attachment.data
                    ]
                )
            }

            try db.drop(table: legacyTable)
            try Self.createAIMessageImagesIndex(db)
        }
        return migrator
    }

    private static func createAIMessageImagesTable(_ db: Database) throws {
        try db.create(table: "ai_message_images") { table in
            table.column("id", .text).primaryKey()
            table.column("message_id", .text)
                .notNull()
                .references("ai_messages", onDelete: .cascade)
            table.column("position", .integer).notNull()
            table.column("mime_type", .text).notNull()
            table.column("data", .blob).notNull()
            table.uniqueKey(["message_id", "position"])
        }
    }

    private static func createAIMessageImagesIndex(_ db: Database) throws {
        try db.create(
            index: "ai_message_images_message_position",
            on: "ai_message_images",
            columns: ["message_id", "position"]
        )
    }

    private static func makeLegacyChatImageAttachment(
        _ row: Row
    ) -> ChatImageAttachment? {
        let id: String = row["id"]
        if row.hasColumn("data"), let data: Data = row["data"] {
            let mimeType: String = row.hasColumn("mime_type")
                ? (row["mime_type"] ?? "image/jpeg")
                : "image/jpeg"
            return ChatImageAttachment(id: id, mimeType: mimeType, data: data)
        }

        guard row.hasColumn("data_url"),
              let dataURL: String = row["data_url"],
              dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let metadataStart = dataURL.index(dataURL.startIndex, offsetBy: 5)
        let metadata = String(dataURL[metadataStart..<commaIndex])
        guard metadata.lowercased().contains(";base64") else { return nil }
        let mimeType = metadata
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "image/jpeg"
        let payloadStart = dataURL.index(after: commaIndex)
        guard let data = Data(
            base64Encoded: String(dataURL[payloadStart...]),
            options: .ignoreUnknownCharacters
        ) else {
            return nil
        }
        return ChatImageAttachment(id: id, mimeType: mimeType, data: data)
    }

    private static func fetchHistoryReadings(_ db: Database) throws -> [HistoryReading] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, sequence, recorded_at, timestamp_estimated,
                       soil_raw, temperature, humidity, light_lux
                FROM sensor_readings
                ORDER BY sequence DESC
                """
        )

        return rows.map { row in
            let sequence: Int64 = row["sequence"]
            let soilRaw: Int = row["soil_raw"]
            return HistoryReading(
                sequence: UInt32(clamping: sequence),
                recordedAt: row["recorded_at"],
                timestampEstimated: row["timestamp_estimated"],
                soilRaw: UInt16(clamping: soilRaw),
                temperature: row["temperature"],
                humidity: row["humidity"],
                lightLux: row["light_lux"],
                databaseID: row["id"]
            )
        }
    }

    private static func historyReading(
        in db: Database,
        deviceID: String,
        start: Date,
        end: Date,
        descending: Bool
    ) throws -> HistoryReading? {
        let direction = descending ? "DESC" : "ASC"
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, sequence, recorded_at, timestamp_estimated,
                       soil_raw, temperature, humidity, light_lux
                FROM sensor_readings
                WHERE device_id = ? AND recorded_at >= ? AND recorded_at < ?
                ORDER BY recorded_at \(direction), sequence \(direction)
                LIMIT 1
                """,
            arguments: [deviceID, start, end]
        ) else {
            return nil
        }
        return try makeHistoryReading(from: row)
    }

    private static func makeHistoryReading(from row: Row) throws -> HistoryReading {
        let sequence: Int64 = row["sequence"]
        let soilRaw: Int = row["soil_raw"]
        return HistoryReading(
            sequence: UInt32(clamping: sequence),
            recordedAt: row["recorded_at"],
            timestampEstimated: row["timestamp_estimated"],
            soilRaw: UInt16(clamping: soilRaw),
            temperature: row["temperature"],
            humidity: row["humidity"],
            lightLux: row["light_lux"],
            databaseID: row["id"]
        )
    }

    private static func metricStatistics(
        from row: Row,
        average: String,
        minimum: String,
        maximum: String
    ) -> SensorMetricStatistics {
        SensorMetricStatistics(
            average: row[average],
            minimum: row[minimum],
            maximum: row[maximum]
        )
    }

    private static func seriesBucketDate(
        from bucket: String,
        granularity: SensorSeriesGranularity
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = granularity.dateFormat
        return formatter.date(from: bucket)
    }

    private static func validateHistoryRange(from start: Date, to end: Date) throws {
        guard start < end else { throw PlantDatabaseError.invalidHistoryRange }
    }

    private static func makeConversation(_ row: Row) -> AIConversation? {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else { return nil }
        return AIConversation(
            id: id,
            title: row["title"],
            kind: AIConversationKind(rawValue: row["kind"]) ?? .text,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func makeChatMessage(
        _ row: Row,
        imageAttachments: [ChatImageAttachment] = [],
        toolInvocations: [ToolInvocation] = []
    ) -> ChatMessage? {
        let idText: String = row["id"]
        let conversationIDText: String = row["conversation_id"]
        let roleText: String = row["role"]
        guard let id = UUID(uuidString: idText),
              let conversationID = UUID(uuidString: conversationIDText),
              let role = ChatRole(rawValue: roleText) else {
            return nil
        }
        return ChatMessage(
            id: id,
            conversationID: conversationID,
            role: role,
            content: row["content"],
            createdAt: row["created_at"],
            imageAttachments: imageAttachments,
            toolInvocations: toolInvocations
        )
    }

    private struct StoredChatImageAttachment {
        let messageID: UUID
        let attachment: ChatImageAttachment
    }

    private static func makeChatImageAttachment(
        _ row: Row
    ) -> StoredChatImageAttachment? {
        let messageIDText: String = row["message_id"]
        guard let messageID = UUID(uuidString: messageIDText) else { return nil }
        return StoredChatImageAttachment(
            messageID: messageID,
            attachment: ChatImageAttachment(
                id: row["id"],
                mimeType: row["mime_type"],
                data: row["data"]
            )
        )
    }

    private struct StoredToolInvocation {
        let messageID: UUID
        let invocation: ToolInvocation
    }

    private static func makeToolInvocation(_ row: Row) -> StoredToolInvocation? {
        let idText: String = row["id"]
        let messageIDText: String = row["message_id"]
        guard let id = UUID(uuidString: idText),
              let messageID = UUID(uuidString: messageIDText) else {
            return nil
        }
        return StoredToolInvocation(
            messageID: messageID,
            invocation: ToolInvocation(
                id: id,
                providerCallID: row["provider_call_id"],
                toolName: row["tool_name"],
                summary: row["summary"],
                argumentsJSON: row["arguments_json"],
                resultJSON: row["result_json"],
                executedAt: row["executed_at"]
            )
        )
    }
}

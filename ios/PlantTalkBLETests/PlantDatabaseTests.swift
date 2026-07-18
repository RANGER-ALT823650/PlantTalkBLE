import Foundation
import XCTest
@testable import PlantTalkBLE

final class PlantDatabaseTests: XCTestCase {
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

        try await database.saveChatMessage(ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            role: .user,
            content: "现在感觉怎么样？",
            createdAt: firstDate
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
        XCTAssertEqual(messages.last?.toolInvocations, [invocation])

        try await database.deleteConversation(id: conversation.id)
        let remainingConversations = try await database.allConversations()
        let remainingMessages = try await database.chatMessages(conversationID: conversation.id)
        XCTAssertTrue(remainingConversations.isEmpty)
        XCTAssertTrue(remainingMessages.isEmpty)
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

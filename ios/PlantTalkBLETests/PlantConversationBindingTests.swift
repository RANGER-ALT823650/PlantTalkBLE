import Foundation
import XCTest
@testable import PlantTalkBLE

@MainActor
final class PlantConversationBindingTests: XCTestCase {
    func testSingleHistoricalPlantIsBoundAndPersistedAcrossConversationStarts() async throws {
        let database = try makeDatabase()
        _ = try await database.saveHistoryBatch(
            [makeReading(sequence: 1, at: Date(timeIntervalSince1970: 1_700_000_000))],
            deviceID: "ESP32-ONE",
            acknowledgedThrough: 1
        )
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let resolver = PlantConversationBindingResolver(
            database: database,
            currentDeviceIDProvider: { nil },
            preferences: preferences
        )
        let first = try await resolver.bindCurrentPlant()
        let second = try await PlantConversationBindingResolver(
            database: database,
            currentDeviceIDProvider: { nil },
            preferences: preferences
        ).bindCurrentPlant()

        XCTAssertEqual(first.deviceID, "ESP32-ONE")
        XCTAssertEqual(first.source, .onlyHistoricalPlant)
        XCTAssertEqual(second.deviceID, "ESP32-ONE")
        XCTAssertEqual(second.source, .savedCurrentPlant)
        XCTAssertTrue(first.modelInstructions.contains("ESP32-ONE"))
        XCTAssertTrue(first.modelInstructions.contains("不要要求用户重复说明"))
    }

    func testLiveESP32OverridesPreviousPlantSelection() async throws {
        let database = try makeDatabase()
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("OLD-ESP32", forKey: "plantTalk.currentPlantDeviceID")

        let binding = try await PlantConversationBindingResolver(
            database: database,
            currentDeviceIDProvider: { "LIVE-ESP32" },
            preferences: preferences
        ).bindCurrentPlant()

        XCTAssertEqual(binding.deviceID, "LIVE-ESP32")
        XCTAssertEqual(binding.source, .connectedBluetooth)
        XCTAssertEqual(preferences.string(forKey: "plantTalk.currentPlantDeviceID"), "LIVE-ESP32")
    }

    func testSeveralHistoricalPlantsDoNotGetSilentlyMixed() async throws {
        let database = try makeDatabase()
        _ = try await database.saveHistoryBatch(
            [makeReading(sequence: 1, at: Date(timeIntervalSince1970: 1_700_000_000))],
            deviceID: "ESP32-A",
            acknowledgedThrough: 1
        )
        _ = try await database.saveHistoryBatch(
            [makeReading(sequence: 1, at: Date(timeIntervalSince1970: 1_700_000_300))],
            deviceID: "ESP32-B",
            acknowledgedThrough: 1
        )
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let binding = try await PlantConversationBindingResolver(
            database: database,
            currentDeviceIDProvider: { nil },
            preferences: preferences
        ).bindCurrentPlant()

        XCTAssertNil(binding.deviceID)
        XCTAssertEqual(binding.source, .multipleHistoricalPlantsNeedSelection)
        XCTAssertTrue(binding.modelInstructions.contains("多株植物"))
    }

    private func makeDatabase() throws -> PlantDatabase {
        try PlantDatabase(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("plant-binding-\(UUID().uuidString).sqlite")
            .path)
    }

    private func makePreferences() -> (preferences: UserDefaults, suiteName: String) {
        let suiteName = "PlantConversationBindingTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeReading(sequence: UInt32, at date: Date) -> HistoryReading {
        HistoryReading(
            sequence: sequence,
            recordedAt: date,
            timestampEstimated: false,
            soilRaw: 1_000,
            temperature: 24,
            humidity: 60,
            lightLux: 300
        )
    }
}

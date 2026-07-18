import Foundation
import XCTest
@testable import PlantTalkBLE

final class HistoryTransferProtocolTests: XCTestCase {
    @MainActor
    func testLiveESP32HistorySyncWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PLANT_TALK_RUN_BLE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set PLANT_TALK_RUN_BLE_INTEGRATION=1 to run the live ESP32 history sync.")
        }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
            .path
        let database = try PlantDatabase(path: path)
        let manager = PlantBluetoothManager(database: database)
        manager.connect()
        defer { manager.disconnect() }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            switch manager.historySyncState {
            case .completed(let totalStored):
                let storedCount = try await database.readingCount(
                    for: try XCTUnwrap(manager.connectedDeviceID)
                )
                XCTAssertEqual(totalStored, storedCount)
                XCTAssertGreaterThan(storedCount, 0)
                return
            case .error(let message):
                XCTFail("Live ESP32 history sync failed: \(message)")
                return
            default:
                break
            }

            if case .error(let message) = manager.state {
                XCTFail("Live ESP32 connection failed: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Live ESP32 history sync did not complete within 90 seconds.")
    }

    func testDecodesHistoryRecord() throws {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 1
        bytes[1] = 1
        bytes[2] = 0x03
        put(UInt32(42), into: &bytes, at: 4)
        put(UInt32(1_750_000_000), into: &bytes, at: 8)
        put(UInt16(2310), into: &bytes, at: 12)
        put(UInt16(bitPattern: Int16(2_645)), into: &bytes, at: 14)
        put(UInt16(6_210), into: &bytes, at: 16)
        put(UInt16(780), into: &bytes, at: 18)
        bytes[3] = HistoryTransferProtocol.checksum(Data(bytes))

        guard case .record(let reading) = try HistoryTransferProtocol.decode(Data(bytes)) else {
            return XCTFail("Expected a record")
        }
        XCTAssertEqual(reading.sequence, 42)
        XCTAssertFalse(reading.timestampEstimated)
        XCTAssertEqual(reading.soilRaw, 2310)
        XCTAssertEqual(reading.temperature, 26.45)
        XCTAssertEqual(reading.humidity, 62.10)
        XCTAssertEqual(reading.lightLux, 780)
    }

    func testEncodesTimeSyncCommand() {
        let data = HistoryTransferProtocol.makeSetUnixTime(
            Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertEqual(Array(data), [1, 0x12, 0x80, 0xE1, 0x4E, 0x68])
    }

    func testEncodesImmediateSampleCommand() {
        XCTAssertEqual(
            Array(HistoryTransferProtocol.makeImmediateSampleRequest()),
            [1, 0x13]
        )
    }

    func testDecodesBatchEndIntegrityMetadata() throws {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 1
        bytes[1] = 2
        bytes[2] = 64
        put(UInt32(164), into: &bytes, at: 4)
        put(UInt32(36), into: &bytes, at: 8)
        put(UInt32(200), into: &bytes, at: 12)
        put(UInt32(101), into: &bytes, at: 16)
        bytes[3] = HistoryTransferProtocol.checksum(Data(bytes))

        guard case .batchEnd(let end) = try HistoryTransferProtocol.decode(Data(bytes)) else {
            return XCTFail("Expected a batch end")
        }
        XCTAssertEqual(end.recordCount, 64)
        XCTAssertEqual(end.firstSequence, 101)
        XCTAssertEqual(end.lastSequence, 164)
        XCTAssertEqual(end.remainingCount, 36)
        XCTAssertEqual(end.newestSequence, 200)
    }

    func testAcceptsCompleteDeclaredBatch() throws {
        let readings = (101...164).map(makeReading(sequence:))
        let end = makeBatchEnd(first: 101, last: 164, count: 64, newest: 200)

        XCTAssertNoThrow(try HistoryTransferProtocol.validateBatch(
            readings,
            requestedAfterSequence: 100,
            endedBy: end
        ))
    }

    func testRejectsBatchWhenLeadingNotificationsWereLost() {
        let readings = (106...164).map(makeReading(sequence:))
        let end = makeBatchEnd(first: 101, last: 164, count: 64, newest: 200)

        XCTAssertThrowsError(try HistoryTransferProtocol.validateBatch(
            readings,
            requestedAfterSequence: 100,
            endedBy: end
        )) { error in
            XCTAssertEqual(error as? HistoryTransferProtocol.DecodeError, .incompleteBatch)
        }
    }

    func testRejectsBatchWhenMiddleNotificationWasLost() {
        let readings = (101...164)
            .filter { $0 != 120 }
            .map(makeReading(sequence:))
        let end = makeBatchEnd(first: 101, last: 164, count: 64, newest: 200)

        XCTAssertThrowsError(try HistoryTransferProtocol.validateBatch(
            readings,
            requestedAfterSequence: 100,
            endedBy: end
        )) { error in
            XCTAssertEqual(error as? HistoryTransferProtocol.DecodeError, .incompleteBatch)
        }
    }

    func testAcceptsSourceDeclaredSequenceGapAfterFlashRollover() throws {
        let readings = (500...563).map(makeReading(sequence:))
        let end = makeBatchEnd(first: 500, last: 563, count: 64, newest: 600)

        XCTAssertNoThrow(try HistoryTransferProtocol.validateBatch(
            readings,
            requestedAfterSequence: 100,
            endedBy: end
        ))
    }

    func testAcceptsEmptyBatchAtRequestedCursor() throws {
        let end = makeBatchEnd(first: 0, last: 815, count: 0, newest: 815)

        XCTAssertNoThrow(try HistoryTransferProtocol.validateBatch(
            [],
            requestedAfterSequence: 815,
            endedBy: end
        ))
    }

    func testRejectsLegacyBatchWithoutIntegrityMetadata() {
        let readings = (101...164).map(makeReading(sequence:))
        let end = makeBatchEnd(first: 0, last: 164, count: 0, newest: 200)

        XCTAssertThrowsError(try HistoryTransferProtocol.validateBatch(
            readings,
            requestedAfterSequence: 100,
            endedBy: end
        )) { error in
            XCTAssertEqual(error as? HistoryTransferProtocol.DecodeError, .outdatedBatchMetadata)
        }
    }

    func testRejectsCorruptPacket() {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 1
        bytes[1] = 1
        XCTAssertThrowsError(try HistoryTransferProtocol.decode(Data(bytes))) { error in
            XCTAssertEqual(error as? HistoryTransferProtocol.DecodeError, .checksumMismatch)
        }
    }

    private func put(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func makeReading(sequence: Int) -> HistoryReading {
        HistoryReading(
            sequence: UInt32(sequence),
            recordedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(sequence * 300)),
            timestampEstimated: false,
            soilRaw: 2_000,
            temperature: 25,
            humidity: 60,
            lightLux: nil
        )
    }

    private func makeBatchEnd(
        first: UInt32,
        last: UInt32,
        count: UInt8,
        newest: UInt32
    ) -> HistoryTransferProtocol.BatchEnd {
        HistoryTransferProtocol.BatchEnd(
            recordCount: count,
            firstSequence: first,
            lastSequence: last,
            remainingCount: newest - last,
            newestSequence: newest
        )
    }
}

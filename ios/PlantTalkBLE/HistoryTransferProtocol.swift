import Foundation

/// The history transport deliberately stays within the default 20-byte BLE payload.
/// Firmware and app must use this layout byte-for-byte.
enum HistoryTransferProtocol {
    static let version: UInt8 = 1
    static let packetLength = 20
    static let requestedBatchSize: UInt16 = 64

    enum PacketType: UInt8 {
        case record = 0x01
        case batchEnd = 0x02
        case failure = 0x03
    }

    enum CommandType: UInt8 {
        case requestAfterSequence = 0x10
        case acknowledgeThroughSequence = 0x11
        case setUnixTime = 0x12
        case requestImmediateSample = 0x13
    }

    struct BatchEnd: Equatable, Sendable {
        let recordCount: UInt8
        let firstSequence: UInt32
        let lastSequence: UInt32
        let remainingCount: UInt32
        let newestSequence: UInt32
    }

    enum IncomingPacket: Equatable, Sendable {
        case record(HistoryReading)
        case batchEnd(BatchEnd)
        case failure(code: UInt16)
    }

    enum DecodeError: LocalizedError, Equatable {
        case invalidLength
        case unsupportedVersion(UInt8)
        case checksumMismatch
        case unknownPacketType(UInt8)
        case invalidTimestamp(UInt32)
        case invalidSequence
        case incompleteBatch
        case outdatedBatchMetadata

        var errorDescription: String? {
            switch self {
            case .invalidLength: "历史数据包长度错误"
            case .unsupportedVersion(let version): "不支持的历史协议版本：\(version)"
            case .checksumMismatch: "历史数据包校验失败"
            case .unknownPacketType(let type): "未知历史数据包类型：\(type)"
            case .invalidTimestamp: "历史记录时间戳无效"
            case .invalidSequence: "历史记录序号无效"
            case .incompleteBatch: "历史数据批次不完整，将在下次同步时重传"
            case .outdatedBatchMetadata: "ESP32 固件缺少批次完整性信息，请先更新固件"
            }
        }
    }

    /// Record packet (20 bytes):
    /// version, type, validity flags, CRC-8, sequence, Unix time,
    /// soil ADC, temperature*100, humidity*100, light lux.
    static func decode(_ data: Data) throws -> IncomingPacket {
        guard data.count == packetLength else { throw DecodeError.invalidLength }
        guard data[0] == version else { throw DecodeError.unsupportedVersion(data[0]) }
        guard checksum(data) == data[3] else { throw DecodeError.checksumMismatch }
        guard let type = PacketType(rawValue: data[1]) else {
            throw DecodeError.unknownPacketType(data[1])
        }

        switch type {
        case .record:
            let flags = data[2]
            let timestamp = uint32LE(data, offset: 8)
            guard timestamp > 0 else { throw DecodeError.invalidTimestamp(timestamp) }

            return .record(HistoryReading(
                sequence: uint32LE(data, offset: 4),
                recordedAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                timestampEstimated: flags & 0x04 != 0,
                soilRaw: uint16LE(data, offset: 12),
                temperature: flags & 0x01 != 0
                    ? Double(int16LE(data, offset: 14)) / 100
                    : nil,
                humidity: flags & 0x01 != 0
                    ? Double(uint16LE(data, offset: 16)) / 100
                    : nil,
                lightLux: flags & 0x02 != 0
                    ? Double(uint16LE(data, offset: 18))
                    : nil
            ))

        case .batchEnd:
            return .batchEnd(BatchEnd(
                recordCount: data[2],
                firstSequence: uint32LE(data, offset: 16),
                lastSequence: uint32LE(data, offset: 4),
                remainingCount: uint32LE(data, offset: 8),
                newestSequence: uint32LE(data, offset: 12)
            ))

        case .failure:
            return .failure(code: uint16LE(data, offset: 4))
        }
    }

    /// Confirms that the notifications received by iOS exactly match the range
    /// the ESP32 says it sent. `firstSequence` may legitimately be greater than
    /// `requestedAfterSequence + 1` after ring-buffer rollover or Flash damage;
    /// matching the declared range distinguishes that source-side gap from a
    /// BLE notification lost at the start of the batch.
    static func validateBatch(
        _ readings: [HistoryReading],
        requestedAfterSequence: UInt32,
        endedBy end: BatchEnd
    ) throws {
        guard end.recordCount <= UInt8(requestedBatchSize) else {
            throw DecodeError.incompleteBatch
        }

        if end.recordCount == 0 {
            guard readings.isEmpty,
                  end.firstSequence == 0,
                  end.lastSequence == requestedAfterSequence else {
                if end.firstSequence == 0, !readings.isEmpty {
                    throw DecodeError.outdatedBatchMetadata
                }
                throw DecodeError.incompleteBatch
            }
            return
        }

        guard end.firstSequence > requestedAfterSequence else {
            throw DecodeError.incompleteBatch
        }
        guard readings.count == Int(end.recordCount),
              readings.first?.sequence == end.firstSequence,
              readings.last?.sequence == end.lastSequence else {
            if end.firstSequence == 0 {
                throw DecodeError.outdatedBatchMetadata
            }
            throw DecodeError.incompleteBatch
        }

        for (previous, current) in zip(readings, readings.dropFirst()) {
            guard previous.sequence < UInt32.max,
                  current.sequence == previous.sequence + 1 else {
                throw DecodeError.incompleteBatch
            }
        }
    }

    /// Request packet: version, command, last durable sequence, requested record count.
    static func makeRequest(after sequence: UInt32, limit: UInt16 = requestedBatchSize) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = version
        bytes[1] = CommandType.requestAfterSequence.rawValue
        writeUInt32LE(sequence, into: &bytes, offset: 2)
        writeUInt16LE(limit, into: &bytes, offset: 6)
        return Data(bytes)
    }

    /// ACK is sent only after the corresponding SQLite transaction commits.
    static func makeAcknowledgement(through sequence: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes[0] = version
        bytes[1] = CommandType.acknowledgeThroughSequence.rawValue
        writeUInt32LE(sequence, into: &bytes, offset: 2)
        return Data(bytes)
    }

    /// ESP32 has no battery-backed wall clock, so the phone provides UTC time on connect.
    static func makeSetUnixTime(_ date: Date = .now) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes[0] = version
        bytes[1] = CommandType.setUnixTime.rawValue
        let timestamp = UInt32(clamping: Int64(date.timeIntervalSince1970))
        writeUInt32LE(timestamp, into: &bytes, offset: 2)
        return Data(bytes)
    }

    /// Requests one extra sensor read. The firmware persists it as a normal
    /// history record and emits a new live notification without changing its
    /// regular five-minute schedule.
    static func makeImmediateSampleRequest() -> Data {
        Data([version, CommandType.requestImmediateSample.rawValue])
    }

    /// CRC-8/ATM, polynomial 0x07, initial value 0. Byte 3 is excluded.
    static func checksum(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for (index, byte) in data.enumerated() where index != 3 {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 == 0 ? crc << 1 : (crc << 1) ^ 0x07
            }
        }
        return crc
    }

    private static func uint16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func int16LE(_ data: Data, offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(data, offset: offset))
    }

    private static func uint32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt16LE(_ value: UInt16, into bytes: inout [UInt8], offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeUInt32LE(_ value: UInt32, into bytes: inout [UInt8], offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

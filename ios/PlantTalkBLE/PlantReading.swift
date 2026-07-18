import Foundation

struct PlantReading: Equatable, Sendable {
    let temperature: Float?
    let humidity: Float?
    let soilRaw: UInt16
    let lightLux: Float?
    let receivedAt: Date
}

enum PlantPacketDecoder {
    static let packetLength = 16

    static func decode(_ data: Data, receivedAt: Date = .now) -> PlantReading? {
        guard data.count == packetLength, data[0] == 1 else { return nil }

        let flags = data[1]
        let soilRaw = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let rawTemperature = float32LE(data, offset: 4)
        let rawHumidity = float32LE(data, offset: 8)
        let rawLight = float32LE(data, offset: 12)

        return PlantReading(
            temperature: flags & 0x01 != 0 ? rawTemperature : nil,
            humidity: flags & 0x01 != 0 ? rawHumidity : nil,
            soilRaw: soilRaw,
            lightLux: flags & 0x02 != 0 ? rawLight : nil,
            receivedAt: receivedAt
        )
    }

    private static func float32LE(_ data: Data, offset: Int) -> Float {
        let bits = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }
}

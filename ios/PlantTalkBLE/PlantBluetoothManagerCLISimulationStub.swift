import Foundation

/// This target-local stand-in lets the macOS integration runner compile the
/// production PlantDataToolExecutor without initializing CoreBluetooth.
/// The iOS Xcode target does not include this file.
@MainActor
final class PlantBluetoothManager {
    enum ConnectionState: Equatable {
        case idle
        case connected
    }

    var currentOrLastKnownDeviceID: String?
    var connectedDeviceID: String?
    var reading: PlantReading?
    var state: ConnectionState = .idle

    func requestImmediateReading(timeout: TimeInterval = 8) async throws -> PlantReading {
        guard state == .connected, let reading else {
            throw ImmediateSampleError.notReady
        }
        return reading
    }

    enum ImmediateSampleError: LocalizedError {
        case notReady

        var errorDescription: String? {
            "模拟运行器没有已连接的 BLE 植物设备。"
        }
    }
}

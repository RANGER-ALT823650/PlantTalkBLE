import Foundation

/// The plant scope fixed when a text or realtime conversation begins.
///
/// A binding is intentionally independent of a live BLE connection: historical
/// data remains queryable after the sensor goes out of range or the app relaunches.
struct PlantConversationBinding: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case connectedBluetooth
        case savedCurrentPlant
        case onlyHistoricalPlant
        case noKnownPlant
        case multipleHistoricalPlantsNeedSelection
    }

    static let currentPlantDisplayName = "当前植物"

    let plantDisplayName: String
    let deviceID: String?
    let source: Source

    static func bound(deviceID: String, source: Source) -> PlantConversationBinding {
        PlantConversationBinding(
            plantDisplayName: currentPlantDisplayName,
            deviceID: deviceID,
            source: source
        )
    }

    static func unbound(source: Source) -> PlantConversationBinding {
        PlantConversationBinding(
            plantDisplayName: currentPlantDisplayName,
            deviceID: nil,
            source: source
        )
    }

    /// Injected into both text and realtime model instructions. The actual tool
    /// executor is also fixed to `deviceID`, so this is context, not an access
    /// control boundary by itself.
    var modelInstructions: String {
        if let deviceID {
            return """
                会话范围：本次会话已绑定到“\(plantDisplayName)”（ESP32 设备 ID：\(deviceID)）。
                除非用户明确指定其他对象，所有“它、这株、温度、湿度、土壤、光照、历史记录”等描述都指这株植物；不要要求用户重复说明在问哪株植物。
                本地传感器工具已经固定到这个 ESP32 设备 ID。数据类问题按需调用工具，不能猜测、替换或混入其他设备的数据。
                工具返回 `error` 或 `unavailable` 时，必须准确说明其限制；尤其不能把“未绑定设备”改写成“没有历史数据”。
                """
        }

        let reason: String
        switch source {
        case .multipleHistoricalPlantsNeedSelection:
            reason = "本机存在多株植物的历史记录，但尚未选择当前植物。"
        default:
            reason = "尚未发现或保存可绑定的 ESP32 设备 ID。"
        }
        return """
            会话范围：用户正在与“\(plantDisplayName)”对话。\(reason)
            不要假定数据库为空；若涉及传感器数据，请按需调用工具并如实说明工具结果。未来需要用户选择植物时，再请求明确选择。
            """
    }
}

/// Resolves the plant selected by the current app entry point. A live BLE
/// device wins; otherwise the last selected device survives an app relaunch.
/// During the current single-plant product phase, exactly one historical device
/// is adopted automatically. Once several plants exist, an explicit entry-point
/// selection can replace that last fallback without changing the model adapters.
@MainActor
final class PlantConversationBindingResolver {
    private static let savedCurrentPlantDeviceIDKey = "plantTalk.currentPlantDeviceID"

    private let database: PlantDatabase
    private let currentDeviceIDProvider: () -> String?
    private let preferences: UserDefaults

    init(
        database: PlantDatabase,
        currentDeviceIDProvider: @escaping () -> String?,
        preferences: UserDefaults = .standard
    ) {
        self.database = database
        self.currentDeviceIDProvider = currentDeviceIDProvider
        self.preferences = preferences
    }

    func bindCurrentPlant() async throws -> PlantConversationBinding {
        if let liveDeviceID = normalizedDeviceID(currentDeviceIDProvider()) {
            saveCurrentPlantDeviceID(liveDeviceID)
            return .bound(deviceID: liveDeviceID, source: .connectedBluetooth)
        }

        if let savedDeviceID = normalizedDeviceID(
            preferences.string(forKey: Self.savedCurrentPlantDeviceIDKey)
        ) {
            return .bound(deviceID: savedDeviceID, source: .savedCurrentPlant)
        }

        let historicalDeviceIDs = try await database.historyDeviceIDs()
        if let onlyDeviceID = historicalDeviceIDs.only {
            saveCurrentPlantDeviceID(onlyDeviceID)
            return .bound(deviceID: onlyDeviceID, source: .onlyHistoricalPlant)
        }

        return .unbound(source: historicalDeviceIDs.isEmpty
            ? .noKnownPlant
            : .multipleHistoricalPlantsNeedSelection)
    }

    private func saveCurrentPlantDeviceID(_ deviceID: String) {
        preferences.set(deviceID, forKey: Self.savedCurrentPlantDeviceIDKey)
    }

    private func normalizedDeviceID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

import Foundation
import Security

struct AIConfiguration: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let systemPrompt: String
    let apiKey: String
}

struct QwenRealtimeConfiguration: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let voice: String
    let systemPrompt: String
    let apiKey: String
}

enum AIConfigurationError: LocalizedError {
    case invalidBaseURL
    case invalidRealtimeURL
    case missingModel
    case missingRealtimeModel
    case missingVoice
    case missingChatAPIKey
    case missingRealtimeAPIKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "API 地址无效，请填写包含 http:// 或 https:// 的地址。"
        case .invalidRealtimeURL:
            "实时对话地址无效，请填写包含 wss:// 或 ws:// 的 WebSocket 地址。"
        case .missingModel:
            "请填写模型名称。"
        case .missingRealtimeModel:
            "请填写实时对话模型名称。"
        case .missingVoice:
            "请填写实时对话音色。"
        case .missingChatAPIKey:
            "请先在设置中保存文本分析 API Key。"
        case .missingRealtimeAPIKey:
            "请先在设置中保存实时语音 API Key。"
        case .keychain(let status):
            "无法访问 Keychain：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
        }
    }
}

enum AISettingsStore {
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4.1-mini"
    static let defaultRealtimeURL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    static let defaultRealtimeModel = "qwen3.5-omni-flash-realtime"
    static let defaultRealtimeVoice = "Tina"
    static let defaultSystemPrompt = """
        你是一株通过传感器感知周围环境的植物。请使用第一人称、自然且简洁地与照料者交流。\
        你可以根据温度、空气湿度、土壤湿度 ADC 原始值和光照数据分析当前状态，但不要把未经校准的 ADC 原始值当成准确百分比。\
        数据不足时明确说明，不要虚构传感器读数或植物品种。
        """

    private static let baseURLKey = "ai.baseURL"
    private static let modelKey = "ai.model"
    private static let systemPromptKey = "ai.systemPrompt"
    private static let realtimeURLKey = "ai.realtimeURL"
    private static let realtimeModelKey = "ai.realtimeModel"
    private static let realtimeVoiceKey = "ai.realtimeVoice"
    private static let keychainService = "com.example.PlantTalkBLE.ai"
    private static let legacySharedKeychainAccount = "openai-compatible-api-key"
    private static let chatKeychainAccount = "openai-compatible-chat-api-key"
    private static let realtimeKeychainAccount = "qwen-realtime-api-key"

    static var baseURLString: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
    }

    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
    }

    static var systemPrompt: String {
        UserDefaults.standard.string(forKey: systemPromptKey) ?? defaultSystemPrompt
    }

    static var realtimeURLString: String {
        UserDefaults.standard.string(forKey: realtimeURLKey) ?? defaultRealtimeURL
    }

    static var realtimeModel: String {
        UserDefaults.standard.string(forKey: realtimeModelKey) ?? defaultRealtimeModel
    }

    static var realtimeVoice: String {
        UserDefaults.standard.string(forKey: realtimeVoiceKey) ?? defaultRealtimeVoice
    }

    static func savePreferences(
        baseURL: String,
        model: String,
        systemPrompt: String,
        realtimeURL: String,
        realtimeModel: String,
        realtimeVoice: String
    ) {
        UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey)
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey)
        UserDefaults.standard.set(systemPrompt, forKey: systemPromptKey)
        UserDefaults.standard.set(realtimeURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: realtimeURLKey)
        UserDefaults.standard.set(realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: realtimeModelKey)
        UserDefaults.standard.set(realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines), forKey: realtimeVoiceKey)
    }

    static func configuration() throws -> AIConfiguration {
        let baseURLText = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            throw AIConfigurationError.invalidBaseURL
        }

        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw AIConfigurationError.missingModel
        }

        guard let apiKey = try readChatAPIKey(), !apiKey.isEmpty else {
            throw AIConfigurationError.missingChatAPIKey
        }

        return AIConfiguration(
            baseURL: baseURL,
            model: modelName,
            systemPrompt: systemPrompt,
            apiKey: apiKey
        )
    }

    static func realtimeConfiguration() throws -> QwenRealtimeConfiguration {
        let urlText = realtimeURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: urlText),
              let scheme = baseURL.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              baseURL.host != nil else {
            throw AIConfigurationError.invalidRealtimeURL
        }

        let modelName = realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw AIConfigurationError.missingRealtimeModel
        }
        let voiceName = realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceName.isEmpty else {
            throw AIConfigurationError.missingVoice
        }
        guard let apiKey = try readRealtimeAPIKey(), !apiKey.isEmpty else {
            throw AIConfigurationError.missingRealtimeAPIKey
        }

        return QwenRealtimeConfiguration(
            baseURL: baseURL,
            model: modelName,
            voice: voiceName,
            systemPrompt: systemPrompt,
            apiKey: apiKey
        )
    }

    static func hasChatAPIKey() -> Bool {
        guard let apiKey = try? readChatAPIKey() else { return false }
        return !apiKey.isEmpty
    }

    static func hasRealtimeAPIKey() -> Bool {
        guard let apiKey = try? readRealtimeAPIKey() else { return false }
        return !apiKey.isEmpty
    }

    static func hasLegacySharedAPIKey() -> Bool {
        guard let apiKey = try? readAPIKey(account: legacySharedKeychainAccount) else { return false }
        return !apiKey.isEmpty
    }

    static func saveChatAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, account: chatKeychainAccount)
    }

    static func saveRealtimeAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, account: realtimeKeychainAccount)
    }

    static func deleteChatAPIKey() throws {
        try deleteAPIKey(account: chatKeychainAccount)
    }

    static func deleteRealtimeAPIKey() throws {
        try deleteAPIKey(account: realtimeKeychainAccount)
    }

    static func deleteLegacySharedAPIKey() throws {
        try deleteAPIKey(account: legacySharedKeychainAccount)
    }

    private static func readChatAPIKey() throws -> String? {
        try readAPIKey(account: chatKeychainAccount)
    }

    private static func readRealtimeAPIKey() throws -> String? {
        try readAPIKey(account: realtimeKeychainAccount)
    }

    private static func saveAPIKey(_ apiKey: String, account: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let data = Data(value.utf8)
        let lookup = keychainQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AIConfigurationError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw AIConfigurationError.keychain(status)
        }
    }

    private static func deleteAPIKey(account: String) throws {
        let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIConfigurationError.keychain(status)
        }
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private static func readAPIKey(account: String) throws -> String? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AIConfigurationError.keychain(status)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

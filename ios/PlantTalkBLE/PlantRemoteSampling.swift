import Foundation

/// 远程采样（云端指令信箱，方案 A）的客户端。
///
/// 链路：App 写指令 → ESP32 轮询取走 → ESP32 采样并回填 → App 读结果。
/// 蓝牙不可用时由 `PlantDataToolExecutor` 降级到这里，让"现在去测一下"
/// 这类请求在人不在家、手机没连蓝牙时依然可用。
enum PlantRemoteSampling {

    // MARK: - 配置

    static let urlDefaultsKey = "plant_talk_cloud_sync_url"
    static let tokenDefaultsKey = "plant_talk_cloud_sync_token"
    static let deviceIDDefaultsKey = "plant_talk_remote_sampling_device_id"

    /// 与固件 CloudConfig.example.h 里 PLANT_CLOUD_DEVICE_ID 的默认值一致。
    static let fallbackDeviceID = "default_device"

    /// 指令送达 + 采样 + 回填的总预算。
    ///
    /// 固件每 3 秒轮询一次，取到指令后还要读传感器并上传，逼近 8 秒的旧预算
    /// 会在设备一切正常时也偶发超时。云端的指令有效期是 60 秒，这里取 20 秒：
    /// 足够覆盖一次轮询 + 采样 + 上传，又不会让用户对着转圈等太久。
    static let totalTimeout: TimeInterval = 20

    /// 轮询结果的间隔。比固件的轮询周期短，避免结果已就绪却还在等下一次查询。
    static let pollInterval: TimeInterval = 1

    // MARK: - 错误

    enum Failure: LocalizedError {
        case notConfigured
        case unauthorized
        case serverUnavailable(String)
        case createFailed(String)
        case deviceDidNotRespond
        case expired(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "未配置云同步地址，无法远程采样。请在【AI 设置 → 云同步】里填写 FC 地址与密钥。"
            case .unauthorized:
                "云同步密钥不正确，云端拒绝了远程采样请求。"
            case .serverUnavailable(let reason):
                "云端暂时不可用：\(reason)"
            case .createFailed(let reason):
                "远程采样指令创建失败：\(reason)"
            case .deviceDidNotRespond:
                "传感器已收到采样指令但没有回传读数，可能正在重试。"
            case .expired(let reason):
                reason
            case .timedOut:
                "远程采样超时：传感器没在 \(Int(PlantRemoteSampling.totalTimeout)) 秒内回传读数，请确认 ESP32 已接入 Wi-Fi。"
            }
        }
    }

    // MARK: - 解析（纯函数，便于测试）

    struct Configuration {
        let baseURL: URL
        let token: String
        let deviceID: String
    }

    /// 从 UserDefaults 读取配置。地址或密钥缺失时返回 nil —— 云端强制校验
    /// AUTH_TOKEN，没有密钥的请求一定被拒，不如在这里就说清楚。
    static func loadConfiguration(
        from defaults: UserDefaults = .standard
    ) -> Configuration? {
        guard let rawURL = defaults.string(forKey: urlDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let baseURL = URL(string: rawURL) else {
            return nil
        }
        let token = (defaults.string(forKey: tokenDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        let configured = (defaults.string(forKey: deviceIDDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Configuration(
            baseURL: baseURL,
            token: token,
            deviceID: configured.isEmpty ? fallbackDeviceID : configured
        )
    }

    /// 云端 /command/status 的判定结果。
    enum StatusOutcome: Equatable {
        /// 仍在等设备取走或回传。
        case pending
        /// 设备已回填读数。
        case completed(PlantReading)
        /// 指令在有效期内没被取走，云端已作废。
        case expired(String)
        /// 指令不存在（例如云端数据被清空）。
        case notFound
    }

    /// 解析 /command/status 的响应体。
    ///
    /// 抽成纯函数是因为这里的分支最容易出错：把 `expired` 当成 `pending`
    /// 会让用户白等满超时；把缺 `reading` 的 `completed` 当成成功会抛出
    /// 一条毫无信息的错误。
    static func parseStatus(_ object: [String: Any]) -> StatusOutcome {
        let status = (object["status"] as? String) ?? "pending"
        switch status {
        case "completed":
            guard let readingDict = object["reading"] as? [String: Any],
                  let reading = parseReading(readingDict) else {
                // 云端标了 completed 却没有可用读数。当作仍在进行，让调用方
                // 继续等到超时——比立刻报一个说不清缘由的错更有机会拿到数据。
                return .pending
            }
            return .completed(reading)
        case "expired":
            let reason = (object["error"] as? String)
                ?? "传感器未在有效期内取走采样指令，请确认 ESP32 已接入 Wi-Fi。"
            return .expired(reason)
        case "not_found":
            return .notFound
        default:
            return .pending
        }
    }

    /// 把云端回填的读数字典转成 `PlantReading`。
    ///
    /// 数值字段一律走 `NSNumber`：固件上传的 `soilRaw` 是整数、`temperature`
    /// 是小数，而 `JSONSerialization` 会把它们分别解成 Int 和 Double。
    /// 直接 `as? Int` 会让小数变 nil，`as? Double` 会让整数变 nil。
    static func parseReading(_ dict: [String: Any]) -> PlantReading? {
        guard let recordedAtMs = number(in: dict, "recordedAt", "recorded_at")?.doubleValue else {
            return nil
        }
        let soil = number(in: dict, "soilRaw", "soil_raw")?.intValue ?? 0
        return PlantReading(
            temperature: number(in: dict, "temperature").map { Float(truncating: $0) },
            humidity: number(in: dict, "humidity").map { Float(truncating: $0) },
            soilRaw: UInt16(clamping: soil),
            lightLux: number(in: dict, "lightLux", "light_lux").map { Float(truncating: $0) },
            receivedAt: Date(timeIntervalSince1970: recordedAtMs / 1000)
        )
    }

    private static func number(in dict: [String: Any], _ keys: String...) -> NSNumber? {
        for key in keys {
            // NSNull 要显式排除：云端对不可用的传感器写 null，
            // 而 NSNull 不是 NSNumber，转换会失败但不该被当成"键不存在"。
            if let value = dict[key] as? NSNumber { return value }
        }
        return nil
    }

    /// 解析 /command/create 的响应，取出 commandId。
    static func parseCommandID(_ object: [String: Any]) -> String? {
        let raw = (object["commandId"] as? String) ?? (object["command_id"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - 请求

    /// 发起一次远程采样并等待读数。
    static func requestReading(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) async throws -> PlantReading {
        guard let config = loadConfiguration(from: defaults) else {
            throw Failure.notConfigured
        }

        let commandID = try await createCommand(config: config, session: session)
        let deadline = Date().addingTimeInterval(totalTimeout)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            switch try await fetchStatus(commandID: commandID, config: config, session: session) {
            case .completed(let reading):
                return reading
            case .expired(let reason):
                throw Failure.expired(reason)
            case .notFound:
                throw Failure.deviceDidNotRespond
            case .pending:
                continue
            }
        }
        throw Failure.timedOut
    }

    private static func createCommand(
        config: Configuration,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("command/create"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.token, forHTTPHeaderField: "x-auth-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": "refresh_sensor",
            "deviceId": config.deviceID
        ])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let commandID = parseCommandID(object) else {
            let reason = (object["error"] as? String) ?? "云端未返回 commandId"
            throw Failure.createFailed(reason)
        }
        return commandID
    }

    private static func fetchStatus(
        commandID: String,
        config: Configuration,
        session: URLSession
    ) async throws -> StatusOutcome {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("command/status"),
            resolvingAgainstBaseURL: true
        )
        components?.queryItems = [URLQueryItem(name: "commandId", value: commandID)]
        guard let url = components?.url else { return .pending }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.token, forHTTPHeaderField: "x-auth-token")

        // 单次查询失败不该终止整轮等待：网络抖一下，下一次轮询很可能就成功了。
        guard let (data, response) = try? await session.data(for: request) else {
            return .pending
        }
        // 鉴权和服务不可用是配置问题，重试到超时也不会好，直接抛出去。
        try validate(response: response, data: data)

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .pending
        }
        return parseStatus(object)
    }

    /// 把 HTTP 层的失败翻译成可执行的提示。
    ///
    /// 旧实现完全不看状态码，401（密钥错）和 503（云端没配 AUTH_TOKEN）
    /// 都会被当成"设备没回应"，用户按提示去查 ESP32 的 Wi-Fi，方向完全错了。
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw Failure.unauthorized
        default:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reason = (object?["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw Failure.serverUnavailable(reason)
        }
    }
}

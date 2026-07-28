import Foundation

/// The provider-neutral description of a function that an AI model may call.
/// Both the text and Realtime adapters send these same definitions to their
/// respective model APIs.
struct AIModelToolDefinition: Encodable, Equatable, Sendable {
    struct Function: Encodable, Equatable, Sendable {
        let name: String
        let description: String
        let parameters: Parameters
    }

    struct Parameters: Encodable, Equatable, Sendable {
        let type: String
        let properties: [String: Property]
        let required: [String]
        let additionalProperties: Bool

        init(
            properties: [String: Property] = [:],
            required: [String] = [],
            additionalProperties: Bool = false
        ) {
            type = "object"
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
        }
    }

    struct Property: Encodable, Equatable, Sendable {
        let type: String
        let description: String
        let enumValues: [String]?
        let items: Items?

        enum CodingKeys: String, CodingKey {
            case type, description, items
            case enumValues = "enum"
        }

        init(
            type: String,
            description: String,
            enumValues: [String]? = nil,
            items: Items? = nil
        ) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
            self.items = items
        }
    }

    struct Items: Encodable, Equatable, Sendable {
        let type: String
        let enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type
            case enumValues = "enum"
        }

        init(type: String, enumValues: [String]? = nil) {
            self.type = type
            self.enumValues = enumValues
        }
    }

    let type: String
    let function: Function

    init(name: String, description: String, parameters: Parameters) {
        type = "function"
        function = Function(name: name, description: description, parameters: parameters)
    }
}

/// The model's protocol-level function call. It intentionally contains no
/// database access or provider-specific networking behavior.
struct AIModelToolCall: Codable, Equatable, Sendable, Identifiable {
    struct Function: Codable, Equatable, Sendable {
        let name: String
        let arguments: String
    }

    let id: String
    let type: String
    let function: Function
}

enum PlantToolName: String, CaseIterable, Sendable {
    case currentSensorReading = "get_current_sensor_reading"
    case refreshCurrentSensorReading = "refresh_current_sensor_reading"
    case latestHistoricalReading = "get_latest_historical_reading"
    case sensorSummary = "get_sensor_summary"
    case sensorSeries = "get_sensor_series"

    var displayTitle: String {
        switch self {
        case .currentSensorReading: "当前传感器读数"
        case .refreshCurrentSensorReading: "立即采样"
        case .latestHistoricalReading: "最近历史记录"
        case .sensorSummary: "历史汇总"
        case .sensorSeries: "历史趋势"
        }
    }
}

enum PlantToolPeriod: String, CaseIterable, Codable, Sendable {
    case today
    case yesterday
    case last24Hours = "last_24_hours"
    case last7Days = "last_7_days"
    case custom

    var displayTitle: String {
        switch self {
        case .today: "今天"
        case .yesterday: "昨天"
        case .last24Hours: "最近 24 小时"
        case .last7Days: "最近 7 天"
        case .custom: "指定时段"
        }
    }
}

enum PlantToolMetric: String, CaseIterable, Codable, Sendable {
    case temperature
    case humidity
    case soilRaw = "soil_raw"
    case lightLux = "light_lux"

    var displayTitle: String {
        switch self {
        case .temperature: "温度"
        case .humidity: "空气湿度"
        case .soilRaw: "土壤 ADC"
        case .lightLux: "光照"
        }
    }
}

/// The single source of truth for data tools exposed to all model providers.
enum PlantDataToolCatalog {
    static let definitions: [AIModelToolDefinition] = [
        AIModelToolDefinition(
            name: PlantToolName.currentSensorReading.rawValue,
            description: "当用户询问现在、当前或此刻的植物环境时使用。只返回已连接 BLE 设备的实时读数和采集时间；没有实时读数时会明确返回不可用。",
            parameters: .init()
        ),
        AIModelToolDefinition(
            name: PlantToolName.refreshCurrentSensorReading.rawValue,
            description: "仅当用户明确要求“立即测一次”“马上采集”“刷新/重新读取传感器”时使用。会通过 BLE 请求 ESP32 立刻额外采样，等待新的实时读数；该样本也会由固件作为额外历史记录保存，但不会改变原有每五分钟的定时采样节拍。需要当前植物设备已连接。普通的“现在/当前”问题不能调用此工具。",
            parameters: .init()
        ),
        AIModelToolDefinition(
            name: PlantToolName.latestHistoricalReading.rawValue,
            description: "当用户询问最近一次已保存的历史传感器记录时使用。它不是实时读数，结果会包含记录时间。",
            parameters: .init()
        ),
        AIModelToolDefinition(
            name: PlantToolName.sensorSummary.rawValue,
            description: "当用户询问某一时段的平均值、最低值、最高值或总体情况时使用。选择最小足以回答问题的时间范围和相关指标；不要把土壤 ADC 原始值描述为湿度百分比，也不要在没有校准与传感器极性信息时把 ADC 的升降解释为实际含水量升降。",
            parameters: rangeParameters(includeGranularity: false)
        ),
        AIModelToolDefinition(
            name: PlantToolName.sensorSeries.rawValue,
            description: "当用户明确询问变化趋势、按小时或按五分钟的变化时使用。优先使用较粗粒度；五分钟粒度只用于短时间范围的细节分析。结果中 bucket_start_local 和 bucket_end_exclusive_local 是唯一权威的本地时间标签，必须原样使用，不要根据 UTC bucket_start 自行换算或挪动日期；is_partial_bucket 为 true 时不可当作完整时段。",
            parameters: rangeParameters(includeGranularity: true)
        )
    ]

    /// Appended to each provider's system instructions. The tool definitions
    /// convey the capability; this text conveys the decision policy.
    static let usageInstructions = """
        可用工具能读取当前 BLE 传感器、最近历史记录、历史汇总和历史趋势；另有一个明确授权才可使用的“立即采样”动作。
        工具选择对应关系：当前读数用 get_current_sensor_reading，最近一条历史用 get_latest_historical_reading，汇总用 get_sensor_summary，趋势序列用 get_sensor_series；明确授权的立即采样才用 refresh_current_sensor_reading。
        只有当用户的问题依赖真实传感器读数、指定时间段或变化趋势时才调用工具；闲聊和通用养护知识不调用。
        优先查询满足问题的最小时间范围，并优先使用历史汇总而非趋势序列。
        “当前”只能使用当前 BLE 读数，不能因此触发采样；只有用户明确说“立即测一次”“马上采集”“重新采集”或“刷新读取”时，才调用 refresh_current_sensor_reading。该动作会生成一个额外样本，但不会改变原有五分钟定时节拍；如果设备未连接或结果不可用，必须如实说明，不能改用旧读数冒充新采样。历史记录必须说明其记录时间。回答任意历史范围前先检查 status、sample_count 和 data_coverage；请求区间不等于实际样本覆盖，估算时间戳不能表述为精确采样时间。
        对趋势点，bucket_start_local 和 bucket_end_exclusive_local 是唯一可展示的本地时间标签，严禁根据 UTC bucket_start 重算、改写或移动日期；is_partial_bucket 为 true 时必须说明它不是完整桶。土壤 ADC 只能报告未经校准的原始数值及其数值变化；没有校准曲线和传感器极性时，不能换算百分比，也不能断言 ADC 增减代表含水量的增减。
        工具结果是唯一可信的数据来源，数据缺失时必须说明，不得编造读数。
        """

    private static func rangeParameters(includeGranularity: Bool) -> AIModelToolDefinition.Parameters {
        var properties: [String: AIModelToolDefinition.Property] = [
            "period": .init(
                type: "string",
                description: "相对时间范围。若用户指定了任意日期或精确时段，选择 custom 并同时提供 start 和 end。",
                enumValues: PlantToolPeriod.allCases.map(\.rawValue)
            ),
            "start": .init(
                type: "string",
                description: "仅在 period 为 custom 时使用。本地时区 ISO 8601 起始时间，例如 2026-07-12T00:00:00+08:00。"
            ),
            "end": .init(
                type: "string",
                description: "仅在 period 为 custom 时使用。本地时区 ISO 8601 结束时间，且为排他上界。"
            ),
            "metrics": .init(
                type: "array",
                description: "只选择回答问题所需的指标。",
                items: .init(type: "string", enumValues: PlantToolMetric.allCases.map(\.rawValue))
            )
        ]
        if includeGranularity {
            properties["granularity"] = .init(
                type: "string",
                description: "趋势分桶粒度。五分钟粒度仅适用于短时间范围。",
                enumValues: SensorSeriesGranularity.allCases.map(\.rawValue)
            )
        }
        var required = ["period", "metrics"]
        if includeGranularity { required.append("granularity") }
        return .init(properties: properties, required: required)
    }
}

@MainActor
final class PlantDataToolExecutor {
    /// The firmware reports a fresh reading every five minutes.  A connected
    /// peripheral alone is not enough to call an older cached value "current".
    private static let maximumLiveReadingAge: TimeInterval = 10 * 60
    private static let maximumSummaryRange: TimeInterval = 366 * 24 * 60 * 60
    private static let maximumSeriesRange: [SensorSeriesGranularity: TimeInterval] = [
        .fiveMinutes: 24 * 60 * 60,
        .hour: 31 * 24 * 60 * 60,
        .day: 366 * 24 * 60 * 60
    ]

    private let database: PlantDatabase
    private let deviceIDProvider: () -> String?
    private let currentReadingProvider: () -> PlantReading?
    private let immediateReadingRequester: () async throws -> PlantReading
    private let nowProvider: () -> Date
    private let calendar: Calendar

    convenience init(database: PlantDatabase, bluetooth: PlantBluetoothManager) {
        self.init(
            database: database,
            deviceIDProvider: { bluetooth.currentOrLastKnownDeviceID },
            currentReadingProvider: {
                guard bluetooth.state == .connected else { return nil }
                return bluetooth.reading
            },
            immediateReadingRequester: {
                try await bluetooth.requestImmediateReading()
            }
        )
    }

    /// Creates a tool executor fixed to the plant selected when a conversation
    /// started. This keeps history queries stable across BLE disconnects and
    /// prevents a later connection to another sensor from changing the meaning
    /// of an in-progress conversation.
    convenience init(
        database: PlantDatabase,
        bluetooth: PlantBluetoothManager,
        boundDeviceID: String?
    ) {
        self.init(
            database: database,
            deviceIDProvider: { boundDeviceID },
            currentReadingProvider: {
                guard let boundDeviceID,
                      bluetooth.connectedDeviceID == boundDeviceID,
                      bluetooth.state == .connected else { return nil }
                return bluetooth.reading
            },
            immediateReadingRequester: {
                guard let boundDeviceID,
                      bluetooth.connectedDeviceID == boundDeviceID,
                      bluetooth.state == .connected else {
                    throw PlantToolExecutionError.noActiveLiveDevice
                }
                return try await bluetooth.requestImmediateReading()
            }
        )
    }

    init(
        database: PlantDatabase,
        deviceIDProvider: @escaping () -> String?,
        currentReadingProvider: @escaping () -> PlantReading?,
        immediateReadingRequester: @escaping () async throws -> PlantReading = {
            throw PlantToolExecutionError.immediateSamplingUnavailable
        },
        nowProvider: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.database = database
        self.deviceIDProvider = deviceIDProvider
        self.currentReadingProvider = currentReadingProvider
        self.immediateReadingRequester = immediateReadingRequester
        self.nowProvider = nowProvider
        self.calendar = calendar
    }

    /// Executes catalogued local data operations. All are read-only except the
    /// explicitly named immediate-sampling action, whose hardware side effect
    /// is exposed in both its definition and result payload.
    func execute(_ call: AIModelToolCall) async -> ToolInvocation {
        let executedAt = nowProvider()
        guard let tool = PlantToolName(rawValue: call.function.name) else {
            return makeInvocation(
                providerCallID: call.id,
                toolName: call.function.name,
                summary: "未支持的数据查询",
                argumentsJSON: call.function.arguments,
                payload: [
                    "status": "error",
                    "error": "未知工具：\(call.function.name)"
                ],
                executedAt: executedAt
            )
        }

        do {
            switch tool {
            case .currentSensorReading:
                return executeCurrentReading(call, executedAt: executedAt)
            case .refreshCurrentSensorReading:
                return try await executeImmediateCurrentReading(call, executedAt: executedAt)
            case .latestHistoricalReading:
                return try await executeLatestHistoricalReading(call, executedAt: executedAt)
            case .sensorSummary:
                return try await executeSummary(call, executedAt: executedAt)
            case .sensorSeries:
                return try await executeSeries(call, executedAt: executedAt)
            }
        } catch {
            return makeInvocation(
                providerCallID: call.id,
                toolName: call.function.name,
                summary: "查询未完成",
                argumentsJSON: call.function.arguments,
                payload: [
                    "status": "error",
                    "error": error.localizedDescription
                ],
                executedAt: executedAt
            )
        }
    }

    private func executeCurrentReading(
        _ call: AIModelToolCall,
        executedAt: Date
    ) -> ToolInvocation {
        guard let reading = currentReadingProvider(),
              executedAt.timeIntervalSince(reading.receivedAt) <= Self.maximumLiveReadingAge else {
            return makeInvocation(
                providerCallID: call.id,
                toolName: call.function.name,
                summary: "当前 BLE 读数不可用",
                argumentsJSON: call.function.arguments,
                payload: [
                    "status": "unavailable",
                    "source": "live_bluetooth",
                    "reason": "当前没有 10 分钟内收到的 BLE 实时读数",
                    "maximum_age_seconds": Int(Self.maximumLiveReadingAge)
                ],
                executedAt: executedAt
            )
        }
        return makeInvocation(
            providerCallID: call.id,
            toolName: call.function.name,
            summary: "当前 BLE 读数 · \(formatDate(reading.receivedAt))",
            argumentsJSON: call.function.arguments,
            payload: [
                "status": "ok",
                "source": "live_bluetooth",
                "collected_at": iso8601(reading.receivedAt),
                "collected_at_local": localISO8601(reading.receivedAt),
                "temperature_celsius": reading.temperature.map { Double($0) } ?? NSNull(),
                "humidity_percent": reading.humidity.map { Double($0) } ?? NSNull(),
                "soil_adc_raw": Int(reading.soilRaw),
                "light_lux": reading.lightLux.map { Double($0) } ?? NSNull()
            ],
            executedAt: executedAt
        )
    }

    private func executeImmediateCurrentReading(
        _ call: AIModelToolCall,
        executedAt: Date
    ) async throws -> ToolInvocation {
        var reading: PlantReading?
        var source = "on_demand_bluetooth"
        var bluetoothFailure: String?
        var cloudFailure: String?
        do {
            reading = try await immediateReadingRequester()
        } catch {
            bluetoothFailure = error.localizedDescription
            source = "on_demand_cloud_remote_scheme_a"
            do {
                reading = try await requestRemoteCloudSampling()
            } catch {
                // 两条采样通路的真实原因都要带出去，否则模型只能看到一句
                // 笼统的超时，无法告诉用户该去检查蓝牙还是设备联网。
                cloudFailure = error.localizedDescription
            }
        }
        guard let reading = reading else {
            let reasons = [bluetoothFailure, cloudFailure].compactMap { $0 }
            throw PlantToolExecutionError.samplingFailed(
                reasons.isEmpty
                    ? "蓝牙未连接且远程采样失败。"
                    : "蓝牙与远程采样均失败：\(reasons.joined(separator: "；"))"
            )
        }
        return makeInvocation(
            providerCallID: call.id,
            toolName: call.function.name,
            summary: "立即采样 · \(formatDate(reading.receivedAt))",
            argumentsJSON: call.function.arguments,
            payload: [
                "status": "ok",
                "source": source,
                "acquisition": "manual_extra_sample",
                "sampling_schedule": "unchanged_five_minute_cadence",
                "history_recording": "firmware_appends_extra_sample",
                // 远程采样的读数暂存在云端，要等下一次蓝牙同步才会落到手机本地库，
                // 且它在云端用的是固件配置的设备 ID。模型据此说明"这条读数现在
                // 还查不到历史里"，而不是让用户以为历史工具马上就能取到它。
                "local_history_availability": source == "on_demand_bluetooth"
                    ? "already_stored"
                    : "pending_next_bluetooth_sync",
                "requested_at": iso8601(executedAt),
                "collected_at": iso8601(reading.receivedAt),
                "collected_at_local": localISO8601(reading.receivedAt),
                "temperature_celsius": reading.temperature.map { Double($0) } ?? NSNull(),
                "humidity_percent": reading.humidity.map { Double($0) } ?? NSNull(),
                "soil_adc_raw": Int(reading.soilRaw),
                "light_lux": reading.lightLux.map { Double($0) } ?? NSNull()
            ],
            executedAt: executedAt
        )
    }

    private func requestRemoteCloudSampling() async throws -> PlantReading {
        try await PlantRemoteSampling.requestReading()
    }

    private func executeLatestHistoricalReading(
        _ call: AIModelToolCall,
        executedAt: Date
    ) async throws -> ToolInvocation {
        guard let deviceID = deviceIDProvider() else {
            throw PlantToolExecutionError.noKnownDevice
        }
        guard let reading = try await database.latestHistoricalReading(for: deviceID) else {
            return makeInvocation(
                providerCallID: call.id,
                toolName: call.function.name,
                summary: "没有已保存的历史记录",
                argumentsJSON: call.function.arguments,
                payload: [
                    "status": "unavailable",
                    "source": "local_history",
                    "device_id": deviceID,
                    "reason": "该设备尚无历史传感器记录"
                ],
                executedAt: executedAt
            )
        }
        return makeInvocation(
            providerCallID: call.id,
            toolName: call.function.name,
            summary: "最近历史记录 · \(formatDate(reading.recordedAt))",
            argumentsJSON: call.function.arguments,
            payload: [
                "status": "ok",
                "source": "local_history",
                "device_id": deviceID,
                "reading": historyReadingPayload(reading)
            ],
            executedAt: executedAt
        )
    }

    private func executeSummary(
        _ call: AIModelToolCall,
        executedAt: Date
    ) async throws -> ToolInvocation {
        guard let deviceID = deviceIDProvider() else {
            throw PlantToolExecutionError.noKnownDevice
        }
        let arguments = try decodeRangeArguments(call.function.arguments)
        let range = try resolveRange(arguments)
        guard range.duration <= Self.maximumSummaryRange else {
            throw PlantToolExecutionError.rangeTooLarge(maximum: "366 天")
        }
        let summary = try await database.sensorSummary(
            for: deviceID,
            from: range.start,
            to: range.end
        )
        let metrics = try selectedMetrics(arguments.metrics)
        let hasSamples = summary.readingCount > 0
        var payload: [String: Any] = [
            "status": hasSamples ? "ok" : "unavailable",
            "source": "local_history",
            "device_id": deviceID,
            "time_range": range.payload(timeZone: calendar.timeZone),
            "sample_count": summary.readingCount,
            "estimated_timestamp_count": summary.estimatedTimestampCount,
            "data_coverage": summaryCoveragePayload(summary),
            "metrics": metricSummaryPayload(summary, metrics: metrics)
        ]
        if !hasSamples {
            payload["reason"] = "该设备在请求时段没有已保存的历史传感器记录"
        }
        return makeInvocation(
            providerCallID: call.id,
            toolName: call.function.name,
            summary: hasSamples
                ? "\(metrics.map(\.displayTitle).joined(separator: "、")) · \(range.displayTitle)"
                : "该时段没有已保存的历史记录 · \(range.displayTitle)",
            argumentsJSON: call.function.arguments,
            payload: payload,
            executedAt: executedAt
        )
    }

    private func executeSeries(
        _ call: AIModelToolCall,
        executedAt: Date
    ) async throws -> ToolInvocation {
        guard let deviceID = deviceIDProvider() else {
            throw PlantToolExecutionError.noKnownDevice
        }
        let arguments = try decodeSeriesArguments(call.function.arguments)
        let range = try resolveRange(arguments)
        guard let maximum = Self.maximumSeriesRange[arguments.granularity], range.duration <= maximum else {
            let maximum = Self.maximumSeriesRange[arguments.granularity] ?? 0
            throw PlantToolExecutionError.rangeTooLarge(maximum: maxRangeLabel(for: arguments.granularity, duration: maximum))
        }
        let metrics = try selectedMetrics(arguments.metrics)
        let series = try await database.sensorSeries(
            for: deviceID,
            from: range.start,
            to: range.end,
            granularity: arguments.granularity
        )
        let points: [[String: Any]] = series.map {
            seriesPointPayload(
                $0,
                metrics: metrics,
                granularity: arguments.granularity,
                range: range
            )
        }
        let hasPoints = !points.isEmpty
        var payload: [String: Any] = [
            "status": hasPoints ? "ok" : "unavailable",
            "source": "local_history",
            "device_id": deviceID,
            "time_range": range.payload(timeZone: calendar.timeZone),
            "granularity": arguments.granularity.rawValue,
            "bucket_timezone": calendar.timeZone.identifier,
            "time_label_instruction": "请原样使用每个点的 bucket_start_local 与 bucket_end_exclusive_local；不要根据 bucket_start 重新换算或改写日期。",
            "bucket_count": points.count,
            "points": points
        ]
        if !hasPoints {
            payload["reason"] = "该设备在请求时段没有已保存的历史传感器记录"
        }
        return makeInvocation(
            providerCallID: call.id,
            toolName: call.function.name,
            summary: hasPoints
                ? "\(arguments.granularity.displayTitle)趋势 · \(metrics.map(\.displayTitle).joined(separator: "、")) · \(range.displayTitle)"
                : "该时段没有已保存的历史记录 · \(range.displayTitle)",
            argumentsJSON: call.function.arguments,
            payload: payload,
            executedAt: executedAt
        )
    }

    private func decodeRangeArguments(_ text: String) throws -> RangeArguments {
        try JSONDecoder().decode(RangeArguments.self, from: Data(text.utf8))
    }

    private func decodeSeriesArguments(_ text: String) throws -> SeriesArguments {
        try JSONDecoder().decode(SeriesArguments.self, from: Data(text.utf8))
    }

    private func selectedMetrics(_ metrics: [PlantToolMetric]) throws -> [PlantToolMetric] {
        let unique = Array(Set(metrics)).sorted { $0.rawValue < $1.rawValue }
        guard !unique.isEmpty else { throw PlantToolExecutionError.noMetrics }
        return unique
    }

    private func resolveRange(_ arguments: RangeArguments) throws -> ResolvedToolRange {
        let now = nowProvider()
        let startOfToday = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch arguments.period {
        case .today:
            start = startOfToday
            end = now
        case .yesterday:
            end = startOfToday
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: end) else {
                throw PlantToolExecutionError.invalidRange
            }
            start = yesterday
        case .last24Hours:
            end = now
            start = now.addingTimeInterval(-24 * 60 * 60)
        case .last7Days:
            end = now
            start = now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .custom:
            guard let startText = arguments.start,
                  let endText = arguments.end,
                  let customStart = parseISO8601(startText),
                  let customEnd = parseISO8601(endText),
                  customStart < customEnd else {
                throw PlantToolExecutionError.invalidRange
            }
            start = customStart
            end = customEnd
        }
        guard start < end else { throw PlantToolExecutionError.invalidRange }
        return ResolvedToolRange(period: arguments.period, start: start, end: end)
    }

    private func makeInvocation(
        providerCallID: String,
        toolName: String,
        summary: String,
        argumentsJSON: String,
        payload: [String: Any],
        executedAt: Date
    ) -> ToolInvocation {
        ToolInvocation(
            id: UUID(),
            providerCallID: providerCallID,
            toolName: toolName,
            summary: summary,
            argumentsJSON: canonicalJSON(argumentsJSON),
            resultJSON: prettyJSON(payload),
            executedAt: executedAt
        )
    }

    private func historyReadingPayload(_ reading: HistoryReading) -> [String: Any] {
        [
            "recorded_at": iso8601(reading.recordedAt),
            "recorded_at_local": localISO8601(reading.recordedAt),
            "timestamp_estimated": reading.timestampEstimated,
            "soil_adc_raw": Int(reading.soilRaw),
            "temperature_celsius": reading.temperature ?? NSNull(),
            "humidity_percent": reading.humidity ?? NSNull(),
            "light_lux": reading.lightLux ?? NSNull()
        ]
    }

    private func metricSummaryPayload(
        _ summary: SensorHistorySummary,
        metrics: [PlantToolMetric]
    ) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: metrics.map { metric in
            (metric.rawValue, metricStatisticsPayload(statistics(for: metric, in: summary)))
        })
    }

    private func summaryCoveragePayload(_ summary: SensorHistorySummary) -> [String: Any] {
        [
            "first_recorded_at": summary.firstReading.map { iso8601($0.recordedAt) } ?? NSNull(),
            "first_recorded_at_local": summary.firstReading.map { localISO8601($0.recordedAt) } ?? NSNull(),
            "last_recorded_at": summary.lastReading.map { iso8601($0.recordedAt) } ?? NSNull(),
            "last_recorded_at_local": summary.lastReading.map { localISO8601($0.recordedAt) } ?? NSNull(),
            "first_timestamp_estimated": summary.firstReading?.timestampEstimated ?? NSNull(),
            "last_timestamp_estimated": summary.lastReading?.timestampEstimated ?? NSNull()
        ]
    }

    private func seriesPointPayload(
        _ point: SensorSeriesPoint,
        metrics: [PlantToolMetric],
        granularity: SensorSeriesGranularity,
        range: ResolvedToolRange
    ) -> [String: Any] {
        let bucketEnd = endOfBucket(startingAt: point.bucketStart, granularity: granularity)
        return [
            "bucket_start": iso8601(point.bucketStart),
            "bucket_start_local": localISO8601(point.bucketStart),
            "bucket_end_exclusive_local": localISO8601(bucketEnd),
            "is_partial_bucket": point.bucketStart < range.start || bucketEnd > range.end,
            "sample_count": point.readingCount,
            "estimated_timestamp_count": point.estimatedTimestampCount,
            "metrics": metricSeriesPayload(point, metrics: metrics)
        ]
    }

    private func metricSeriesPayload(
        _ point: SensorSeriesPoint,
        metrics: [PlantToolMetric]
    ) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: metrics.map { metric in
            (metric.rawValue, metricStatisticsPayload(statistics(for: metric, in: point)))
        })
    }

    private func statistics(
        for metric: PlantToolMetric,
        in summary: SensorHistorySummary
    ) -> SensorMetricStatistics {
        switch metric {
        case .temperature: summary.temperature
        case .humidity: summary.humidity
        case .soilRaw: summary.soilRaw
        case .lightLux: summary.lightLux
        }
    }

    private func statistics(
        for metric: PlantToolMetric,
        in point: SensorSeriesPoint
    ) -> SensorMetricStatistics {
        switch metric {
        case .temperature: point.temperature
        case .humidity: point.humidity
        case .soilRaw: point.soilRaw
        case .lightLux: point.lightLux
        }
    }

    private func metricStatisticsPayload(_ values: SensorMetricStatistics) -> [String: Any] {
        [
            "average": values.average ?? NSNull(),
            "minimum": values.minimum ?? NSNull(),
            "maximum": values.maximum ?? NSNull()
        ]
    }

    private func canonicalJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return text
        }
        return prettyJSON(value)
    }

    private func prettyJSON(_ value: Any) -> String {
        let normalized = normalizeJSON(value)
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(
                withJSONObject: normalized,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"error\",\"error\":\"无法序列化工具结果\"}"
        }
        return text
    }

    private func normalizeJSON(_ value: Any) -> Any {
        switch value {
        case let value as [String: Any]:
            return Dictionary(uniqueKeysWithValues: value.map { ($0.key, normalizeJSON($0.value)) })
        case let value as [Any]:
            return value.map(normalizeJSON)
        default:
            return value
        }
    }

    private func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: text) { return value }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func localISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func endOfBucket(
        startingAt start: Date,
        granularity: SensorSeriesGranularity
    ) -> Date {
        let component: Calendar.Component
        let value: Int
        switch granularity {
        case .fiveMinutes:
            component = .minute
            value = 5
        case .hour:
            component = .hour
            value = 1
        case .day:
            component = .day
            value = 1
        }
        return calendar.date(byAdding: component, value: value, to: start)
            ?? start.addingTimeInterval(granularity.approximateDuration)
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func maxRangeLabel(for granularity: SensorSeriesGranularity, duration: TimeInterval) -> String {
        switch granularity {
        case .fiveMinutes: "24 小时"
        case .hour: "31 天"
        case .day: "366 天"
        }
    }
}

private struct RangeArguments: Decodable {
    let period: PlantToolPeriod
    let start: String?
    let end: String?
    let metrics: [PlantToolMetric]
}

private struct SeriesArguments: Decodable {
    let period: PlantToolPeriod
    let start: String?
    let end: String?
    let metrics: [PlantToolMetric]
    let granularity: SensorSeriesGranularity
}

private extension SeriesArguments {
    var rangeArguments: RangeArguments {
        RangeArguments(period: period, start: start, end: end, metrics: metrics)
    }
}

private extension PlantDataToolExecutor {
    func resolveRange(_ arguments: SeriesArguments) throws -> ResolvedToolRange {
        try resolveRange(arguments.rangeArguments)
    }
}

private struct ResolvedToolRange {
    let period: PlantToolPeriod
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var displayTitle: String {
        switch period {
        case .custom:
            "\(start.formatted(date: .abbreviated, time: .shortened))–\(end.formatted(date: .abbreviated, time: .shortened))"
        default:
            period.displayTitle
        }
    }

    func payload(timeZone: TimeZone) -> [String: Any] {
        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let localFormatter = ISO8601DateFormatter()
        localFormatter.timeZone = timeZone
        localFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "period": period.rawValue,
            "start": utcFormatter.string(from: start),
            "end_exclusive": utcFormatter.string(from: end),
            "start_local": localFormatter.string(from: start),
            "end_exclusive_local": localFormatter.string(from: end),
            "timezone": timeZone.identifier
        ]
    }
}

private enum PlantToolExecutionError: LocalizedError {
    case noKnownDevice
    case noActiveLiveDevice
    case immediateSamplingUnavailable
    case invalidRange
    case rangeTooLarge(maximum: String)
    case noMetrics
    /// 采样路径全部失败等运行期原因，原因文本直接来自调用点。
    case samplingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noKnownDevice:
            "尚未识别可查询历史数据的植物设备。"
        case .noActiveLiveDevice:
            "当前对话绑定的植物没有已连接的 BLE 设备，无法立即采样。"
        case .immediateSamplingUnavailable:
            "当前运行环境不能请求 ESP32 立即采样。"
        case .invalidRange:
            "工具请求的时间范围无效。"
        case .rangeTooLarge(let maximum):
            "该趋势查询的时间范围过大；最大允许 \(maximum)。"
        case .noMetrics:
            "工具请求没有指定有效的传感器指标。"
        case .samplingFailed(let reason):
            reason
        }
    }
}

private extension SensorSeriesGranularity {
    var displayTitle: String {
        switch self {
        case .fiveMinutes: "5 分钟"
        case .hour: "每小时"
        case .day: "每天"
        }
    }

    var approximateDuration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        }
    }
}

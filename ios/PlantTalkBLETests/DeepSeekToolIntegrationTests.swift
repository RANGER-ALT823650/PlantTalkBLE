import Foundation
import XCTest
@testable import PlantTalkBLE

/// A deliberately opt-in, live smoke test. It exercises the same production
/// text adapter, tool catalog and SQLite executor used by the app, while
/// keeping API credentials in the process environment rather than in source.
@MainActor
final class DeepSeekToolIntegrationTests: XCTestCase {
    func testDeepSeekToolCallingAgainstSyntheticFiveMinuteHistory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLANT_TALK_RUN_DEEPSEEK_INTEGRATION"] == "1" else {
            throw XCTSkip("Set PLANT_TALK_RUN_DEEPSEEK_INTEGRATION=1 to run the live DeepSeek simulation.")
        }
        guard let apiKey = environment["DEEPSEEK_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("DEEPSEEK_API_KEY is not available to the test process.")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 13,
            hour: 12
        )))
        let historyStart = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 29,
            hour: 0
        )))
        let deviceID = "simulation-plant-001"
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plant-talk-deepseek-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try PlantDatabase(path: databaseURL.path)
        let dataset = makeSyntheticDataset(
            from: historyStart,
            through: now,
            calendar: calendar
        )
        _ = try await database.saveHistoryBatch(
            dataset.readings,
            deviceID: deviceID,
            acknowledgedThrough: dataset.readings.last?.sequence ?? 0
        )

        let liveReading = dataset.liveReading
        let executor = PlantDataToolExecutor(
            database: database,
            deviceIDProvider: { deviceID },
            currentReadingProvider: { liveReading },
            nowProvider: { now },
            calendar: calendar
        )
        let configuration = AIConfiguration(
            baseURL: try XCTUnwrap(URL(string: environment["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com")),
            model: environment["DEEPSEEK_MODEL"] ?? "deepseek-chat",
            systemPrompt: """
                你是一株植物的中文照料助手。回答涉及传感器、当前状态、历史日期、平均值、极值或趋势的问题时，必须先调用合适工具，并且只依据工具结果回答。
                直接给出清楚、简洁的中文结论和必要数值；提到历史数据时说明时间范围。土壤 ADC 是未经校准的原始值，绝不能把它换算或声称为湿度百分比。
                """,
            apiKey: apiKey
        )
        let scenarios = [
            SimulationScenario(
                question: "现在的温度、空气湿度和光照怎么样？",
                expectedTool: .currentSensorReading,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "最近一次保存的历史记录是什么时候？温度和土壤 ADC 原始值分别是多少？",
                expectedTool: .latestHistoricalReading,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "今天截至现在，温度和空气湿度的平均值分别是多少？",
                expectedTool: .sensorSummary,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "昨天温度的最低值和最高值是多少？",
                expectedTool: .sensorSummary,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "最近 24 小时的光照整体情况如何？平均值、最低值和最高值分别是多少？",
                expectedTool: .sensorSummary,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "过去 7 天的平均温度和平均空气湿度是多少？",
                expectedTool: .sensorSummary,
                expectedGranularity: nil
            ),
            SimulationScenario(
                question: "今天上午 9:00 到 10:00，温度每 5 分钟是怎样变化的？",
                expectedTool: .sensorSeries,
                expectedGranularity: .fiveMinutes
            ),
            SimulationScenario(
                question: "昨天按小时看，温度与光照的变化趋势怎样？",
                expectedTool: .sensorSeries,
                expectedGranularity: .hour
            ),
            SimulationScenario(
                question: "过去 7 天按天看，土壤 ADC 原始值的变化趋势怎样？",
                expectedTool: .sensorSeries,
                expectedGranularity: .day
            ),
            SimulationScenario(
                question: "现在土壤湿度是百分之多少？如果不能可靠换算，请说明目前能确定的原始数据。",
                expectedTool: .currentSensorReading,
                expectedGranularity: nil
            )
        ]

        let adapter = TextModelAdapter(client: .live())
        var traces: [SimulationTrace] = []
        for (offset, scenario) in scenarios.enumerated() {
            var answer = ""
            do {
                let invocations = try await adapter.respond(
                    configuration: configuration,
                    initialMessages: [
                        AIRequestMessage(
                            role: .system,
                            content: "\(configuration.systemPrompt)\n\n\(PlantDataToolCatalog.usageInstructions)\n\n当前本地时间：2026-07-13 12:00（Asia/Shanghai）。"
                        ),
                        AIRequestMessage(role: .user, content: scenario.question)
                    ],
                    executor: executor,
                    onTextDelta: { answer += $0 },
                    onToolCallRound: { answer = "" }
                )
                let normalizedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(normalizedAnswer.isEmpty, "第 \(offset + 1) 个问题没有得到最终回答")
                XCTAssertTrue(
                    invocations.contains { $0.toolName == scenario.expectedTool.rawValue },
                    "第 \(offset + 1) 个问题没有调用预期工具 \(scenario.expectedTool.rawValue)"
                )
                if let expectedGranularity = scenario.expectedGranularity {
                    XCTAssertTrue(
                        invocations.contains { $0.argumentsJSON.contains("\"granularity\" : \"\(expectedGranularity.rawValue)\"") },
                        "第 \(offset + 1) 个问题没有使用预期粒度 \(expectedGranularity.rawValue)"
                    )
                }
                if offset == 9 {
                    XCTAssertTrue(
                        normalizedAnswer.contains("ADC") || normalizedAnswer.contains("原始"),
                        "模型没有说明土壤数据是 ADC 原始值"
                    )
                    XCTAssertTrue(
                        ["不能直接", "不可直接", "无法直接", "不能可靠", "无法可靠"]
                            .contains { normalizedAnswer.contains($0) },
                        "模型没有明确拒绝将土壤 ADC 直接换算为百分比"
                    )
                }
                traces.append(SimulationTrace(
                    index: offset + 1,
                    question: scenario.question,
                    answer: normalizedAnswer,
                    expectedTool: scenario.expectedTool.rawValue,
                    toolInvocations: invocations.map(SimulationToolTrace.init)
                ))
            } catch {
                XCTFail("第 \(offset + 1) 个问题失败：\(error.localizedDescription)")
                traces.append(SimulationTrace(
                    index: offset + 1,
                    question: scenario.question,
                    answer: "",
                    expectedTool: scenario.expectedTool.rawValue,
                    toolInvocations: [],
                    error: error.localizedDescription
                ))
            }
        }

        print(SimulationMarkdownRenderer.render(
            model: configuration.model,
            dataset: dataset,
            traces: traces
        ))
    }

    private func makeSyntheticDataset(
        from start: Date,
        through now: Date,
        calendar: Calendar
    ) -> SyntheticDataset {
        let interval: TimeInterval = 5 * 60
        let count = Int(now.timeIntervalSince(start) / interval)
        let readings = (0...count).map { index -> HistoryReading in
            let date = start.addingTimeInterval(Double(index) * interval)
            let values = simulatedValues(at: date, start: start, calendar: calendar)
            return HistoryReading(
                sequence: UInt32(index + 1),
                recordedAt: date,
                timestampEstimated: index % 173 == 0,
                soilRaw: UInt16(values.soil.rounded()),
                temperature: values.temperature,
                humidity: values.humidity,
                lightLux: values.light
            )
        }
        let current = simulatedValues(at: now, start: start, calendar: calendar)
        return SyntheticDataset(
            start: start,
            end: now,
            readings: readings,
            liveReading: PlantReading(
                temperature: Float(current.temperature),
                humidity: Float(current.humidity),
                soilRaw: UInt16(current.soil.rounded()),
                lightLux: Float(current.light),
                receivedAt: now
            )
        )
    }

    private func simulatedValues(
        at date: Date,
        start: Date,
        calendar: Calendar
    ) -> (temperature: Double, humidity: Double, soil: Double, light: Double) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let dayFraction = (Double(components.hour ?? 0) * 60 + Double(components.minute ?? 0)) / 1_440
        let elapsedDays = date.timeIntervalSince(start) / (24 * 60 * 60)
        let dailyWave = sin((dayFraction - 0.25) * .pi * 2)
        let smallVariation = sin(elapsedDays * 4.7 + dayFraction * 13) * 0.45
        let heatWave = (elapsedDays >= 10 && elapsedDays < 12.5) ? 1.8 : 0
        let temperature = 23.2 + dailyWave * 3.8 + smallVariation + heatWave
        let humidity = 64.0 - dailyWave * 11.5 - smallVariation * 2 - heatWave * 1.8

        // The simulated pot was watered once on day 8, then its raw ADC value
        // declines again. This is intentionally still an uncalibrated ADC value.
        let soil = min(3_800, max(700, 2_460 - elapsedDays * 68 + (elapsedDays >= 8 ? 510 : 0) + sin(elapsedDays * 2.2) * 18))
        let daylight = max(0, sin((dayFraction - 0.25) * .pi * 2))
        let cloudFactor = max(0.42, 0.83 + sin(elapsedDays * 1.37) * 0.17)
        let light = daylight == 0 ? 0 : 20_500 * daylight * cloudFactor
        return (temperature, humidity, soil, light)
    }
}

private struct SimulationScenario {
    let question: String
    let expectedTool: PlantToolName
    let expectedGranularity: SensorSeriesGranularity?
}

private struct SyntheticDataset {
    let start: Date
    let end: Date
    let readings: [HistoryReading]
    let liveReading: PlantReading
}

private struct SimulationTrace {
    let index: Int
    let question: String
    let answer: String
    let expectedTool: String
    let toolInvocations: [SimulationToolTrace]
    var error: String?
}

private struct SimulationToolTrace {
    let name: String
    let summary: String
    let arguments: String
    let resultExcerpt: String

    init(_ invocation: ToolInvocation) {
        name = invocation.toolName
        summary = invocation.summary
        arguments = invocation.argumentsJSON
        resultExcerpt = String(invocation.resultJSON.prefix(1_000))
            + (invocation.resultJSON.count > 1_000 ? "\n…（原始结果已截断）" : "")
    }
}

private enum SimulationMarkdownRenderer {
    static func render(
        model: String,
        dataset: SyntheticDataset,
        traces: [SimulationTrace]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "--- BEGIN PLANT TALK DEEPSEEK SIMULATION ---",
            "# DeepSeek 工具调用模拟结果",
            "",
            "- 模型：`\(model)`",
            "- 传感器数据：`\(dataset.readings.count)` 条，每 5 分钟一条",
            "- 历史范围：`\(formatter.string(from: dataset.start))` 至 `\(formatter.string(from: dataset.end))`（Asia/Shanghai）",
            "- 当前 BLE 模拟读数：温度 \(String(format: "%.1f", dataset.liveReading.temperature ?? 0)) °C；空气湿度 \(String(format: "%.1f", dataset.liveReading.humidity ?? 0))%；土壤 ADC 原始值 \(dataset.liveReading.soilRaw)；光照 \(String(format: "%.0f", dataset.liveReading.lightLux ?? 0)) lx。",
            ""
        ]

        for trace in traces {
            lines.append("## \(trace.index). \(trace.question)")
            lines.append("")
            lines.append("- 期望工具：`\(trace.expectedTool)`")
            if let error = trace.error {
                lines.append("- 错误：\(error)")
                lines.append("")
                continue
            }
            lines.append("- 实际调用：\(trace.toolInvocations.map { "`\($0.name)`" }.joined(separator: "、"))")
            for tool in trace.toolInvocations {
                lines.append("  - \(tool.summary)")
                lines.append("    - 参数：`\(tool.arguments.replacingOccurrences(of: "\n", with: " "))`")
                lines.append("    - 结果摘录：")
                lines.append("      ```json")
                lines.append(contentsOf: tool.resultExcerpt.split(separator: "\n", omittingEmptySubsequences: false).map { "      \($0)" })
                lines.append("      ```")
            }
            lines.append("")
            lines.append("**模型回答：** \(trace.answer)")
            lines.append("")
        }
        lines.append("--- END PLANT TALK DEEPSEEK SIMULATION ---")
        return lines.joined(separator: "\n")
    }
}

import SwiftUI

struct DetailView: View {
    let database: PlantDatabase

    @State private var todayReadings: [HistoryReading] = []
    @State private var dailySummaries: [DailySummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var dayPendingDeletion: Date?
    @State private var deletionErrorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取历史记录…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法读取历史记录",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if todayReadings.isEmpty && dailySummaries.isEmpty {
                ContentUnavailableView(
                    "暂无历史记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("连接传感器并完成同步后，记录会显示在这里。")
                )
            } else {
                List {
                    // MARK: - Today (collapsed to the same day-summary row as history)
                    if let todaySummary {
                        Section {
                            NavigationLink {
                                DayDetailView(database: database, date: todaySummary.date)
                            } label: {
                                DailySummaryRow(summary: todaySummary)
                            }
                            .contextMenu {
                                deleteDayButton(todaySummary.date)
                            }
                        } header: {
                            Label("今天", systemImage: "sun.max")
                        }
                    }

                    // MARK: - Past days (collapsed to one row per day)
                    if !dailySummaries.isEmpty {
                        Section {
                            ForEach(dailySummaries) { summary in
                                NavigationLink {
                                    DayDetailView(database: database, date: summary.date)
                                } label: {
                                    DailySummaryRow(summary: summary)
                                }
                                .contextMenu {
                                    deleteDayButton(summary.date)
                                }
                            }
                        } header: {
                            Label("历史记录", systemImage: "calendar")
                        }
                    }
                }
                .refreshable {
                    await loadAll()
                }
            }
        }
        .task {
            await observeTodayReadings()
        }
        .task {
            await loadSummaries()
        }
        .confirmationDialog(
            "删除这一天的传感器记录？",
            isPresented: dayDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let dayPendingDeletion {
                    deleteReadings(for: dayPendingDeletion)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该日期下的全部传感器数据都会被永久删除。")
        }
        .alert("删除失败", isPresented: deletionErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "无法删除传感器记录。")
        }
    }

    // MARK: - Data Loading

    private func observeTodayReadings() async {
        do {
            let observation = await database.historyReadingsObservation()
            for try await latestReadings in observation {
                guard !Task.isCancelled else { return }
                todayReadings = latestReadings
                errorMessage = nil
                isLoading = false
            }
        } catch is CancellationError {
            // Navigation away from this screen cancels the observation normally.
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadSummaries() async {
        do {
            dailySummaries = try await database.historySummaryByDate()
            isLoading = false
        } catch is CancellationError {
            // ignore
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func loadAll() async {
        await loadSummaries()
    }

    private var todaySummary: DailySummary? {
        guard !todayReadings.isEmpty else { return nil }

        return DailySummary(
            date: Calendar.current.startOfDay(for: Date()),
            readingCount: todayReadings.count,
            avgTemperature: average(todayReadings.compactMap(\.temperature)),
            avgHumidity: average(todayReadings.compactMap(\.humidity)),
            avgSoilRaw: average(todayReadings.map { Double($0.soilRaw) }),
            avgLightLux: average(todayReadings.compactMap(\.lightLux))
        )
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    @ViewBuilder
    private func deleteDayButton(_ date: Date) -> some View {
        Button("删除", systemImage: "trash", role: .destructive) {
            dayPendingDeletion = date
        }
    }

    private var dayDeletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { dayPendingDeletion != nil },
            set: { if !$0 { dayPendingDeletion = nil } }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { if !$0 { deletionErrorMessage = nil } }
        )
    }

    private func deleteReadings(for date: Date) {
        dayPendingDeletion = nil
        Task {
            do {
                try await database.deleteHistoryReadings(
                    for: Calendar.current.startOfDay(for: date)
                )
                await loadSummaries()
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Daily Summary Row

private struct DailySummaryRow: View {
    let summary: DailySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formattedDate)
                    .font(.headline)
                Spacer()
                Text("\(summary.readingCount) 条记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                avgValue("温度", summary.avgTemperature.map { String(format: "%.1f °C", $0) })
                avgValue("湿度", summary.avgHumidity.map { String(format: "%.1f%%", $0) })
                avgValue("土壤", summary.avgSoilRaw.map { String(format: "%.0f", $0) })
                avgValue("光照", summary.avgLightLux.map { String(format: "%.0f lx", $0) })
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var formattedDate: String {
        sensorHistoryDayTitle(summary.date)
    }

    private func avgValue(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "--")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Individual Reading Row (shared with DayDetailView)

struct HistoryReadingRow: View {
    let reading: HistoryReading
    let itemNumber: Int
    var showDate: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formattedTime)
                    .font(.headline)
                Spacer()
                Text("#\(itemNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                value("温度", reading.temperature.map { String(format: "%.1f °C", $0) } ?? "--")
                value("湿度", reading.humidity.map { String(format: "%.1f%%", $0) } ?? "--")
                value("土壤", "\(reading.soilRaw)")
                value("光照", reading.lightLux.map { String(format: "%.0f lx", $0) } ?? "--")
            }

            if reading.timestampEstimated {
                Label("时间为估算值", systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var formattedTime: String {
        let style: Date.FormatStyle = showDate
            ? .dateTime.month().day().hour().minute().second()
            : .dateTime.hour().minute().second()
        let value = reading.recordedAt.formatted(style)
        return reading.timestampEstimated ? "约 \(value)" : value
    }

    private func value(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func sensorHistoryDayTitle(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.month, .day], from: date)
    guard let month = components.month, let day = components.day else { return "" }
    return "\(month)月\(day)号"
}

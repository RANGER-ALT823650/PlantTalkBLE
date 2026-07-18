import SwiftUI
import Charts

// MARK: - Time Range

enum SensorChartTimeRange: String, CaseIterable, Identifiable {
    case fiveHours = "5小时"
    case oneDay = "1天"
    case sevenDays = "7天"

    var id: String { rawValue }

    func startDate(endingAt endDate: Date) -> Date {
        switch self {
        case .fiveHours:
            return endDate.addingTimeInterval(-5 * 3600)
        case .oneDay:
            return endDate.addingTimeInterval(-24 * 3600)
        case .sevenDays:
            return endDate.addingTimeInterval(-7 * 24 * 3600)
        }
    }
}

// MARK: - Chart Data Point

private struct ChartDataPoint: Identifiable {
    let id: UInt32
    let date: Date
    let value: Double
    let timestampEstimated: Bool
    let segmentID: Int

    init(
        id: UInt32,
        date: Date,
        value: Double,
        timestampEstimated: Bool = false,
        segmentID: Int = 0
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.timestampEstimated = timestampEstimated
        self.segmentID = segmentID
    }
}

// MARK: - Sheet View

struct SensorChartSheet: View {
    // Normal history arrives every five minutes. Half an interval of tolerance
    // avoids breaking the line for minor timer drift while still exposing a missed sample.
    private static let maximumContinuousSampleInterval: TimeInterval = 7.5 * 60

    let metric: SensorMetric
    let database: PlantDatabase?
    private let previewData: [ChartDataPoint]?

    @State private var timeRange: SensorChartTimeRange = .oneDay
    @State private var dataPoints: [ChartDataPoint] = []
    @State private var isLoading = true
    @State private var rangeEndDate = Date()
    @State private var selectedPoint: ChartDataPoint?

    init(metric: SensorMetric, database: PlantDatabase) {
        self.metric = metric
        self.database = database
        self.previewData = nil
    }

    /// Preview-only initializer: injects synthetic data, no database needed.
    fileprivate init(metric: SensorMetric, previewData: [ChartDataPoint]) {
        self.metric = metric
        self.database = nil
        self.previewData = previewData
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    chartSection
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: timeRange) {
            await loadData()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Current value highlight
            VStack(spacing: 4) {
                Text(selectedPoint.map { selectedTimeLabel(for: $0.date) } ?? " ")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 16)
                    .opacity(selectedPoint == nil ? 0 : 1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: metric.symbol)
                        .font(.title2)
                        .foregroundStyle(metric.tint.gradient)

                    Text(displayedValue)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())

                    if !displayedUnit.isEmpty {
                        Text(displayedUnit)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            // Time range picker
            Picker("时间范围", selection: $timeRange) {
                ForEach(SensorChartTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if isLoading {
                    chartPlaceholder
                } else if dataPoints.isEmpty {
                    emptyState
                } else {
                    chartContent
                }
            }
            .frame(height: 240)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.25))
            }

            if !dataPoints.isEmpty {
                statisticsRow
            }
        }
    }

    private var chartContent: some View {
        let floor = yAxisDomain.lowerBound

        return Chart {
            ForEach(dataPoints) { point in
                LineMark(
                    x: .value("时间", point.date),
                    y: .value(metric.title, point.value),
                    series: .value("连续采样区间", point.segmentID)
                )
                .foregroundStyle(metric.tint.gradient)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("时间", point.date),
                    yStart: .value("底线", floor),
                    yEnd: .value(metric.title, point.value),
                    series: .value("连续采样区间", point.segmentID)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            metric.tint.opacity(0.28),
                            metric.tint.opacity(0.05),
                            metric.tint.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }

            // X-axis baseline
            RuleMark(y: .value("X轴", floor))
                .lineStyle(StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(Color(uiColor: .separator).opacity(0.6))

            // Y-axis baseline
            RuleMark(x: .value("Y轴", chartXDomain.lowerBound))
                .lineStyle(StrokeStyle(lineWidth: 0.8))
                .foregroundStyle(Color(uiColor: .separator).opacity(0.6))

            if let selectedPoint {
                RuleMark(x: .value("选中时间", selectedPoint.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(metric.tint.opacity(0.75))

                PointMark(
                    x: .value("选中时间", selectedPoint.date),
                    y: .value(metric.title, selectedPoint.value)
                )
                .symbol {
                    Circle()
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle()
                                .stroke(metric.tint, lineWidth: 2)
                        }
                }
            }
        }
        .chartXAxis {
            if timeRange == .oneDay {
                AxisMarks(values: oneDayXAxisValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [4, 3]))
                        .foregroundStyle(Color(uiColor: .separator).opacity(0.5))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: xAxisDesiredCount)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [4, 3]))
                        .foregroundStyle(Color(uiColor: .separator).opacity(0.5))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [4, 3]))
                    .foregroundStyle(Color(uiColor: .separator).opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yAxisLabel(for: v))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: chartXDomain)
        .chartYScale(domain: yAxisDomain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let plotRect = geometry[plotFrame]
                                guard plotRect.contains(drag.location) else { return }

                                let plotX = drag.location.x - plotRect.minX
                                guard let date: Date = proxy.value(atX: plotX) else { return }
                                selectNearestPoint(to: date)
                            }
                            .onEnded { _ in
                                selectedPoint = nil
                            }
                    )
            }
        }
    }

    private var chartPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("加载中…")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("暂无数据")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("所选时间范围内没有传感器记录")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Statistics

    private var statisticsRow: some View {
        HStack(spacing: 0) {
            statisticItem(title: "最小", value: formatStatValue(dataPoints.map(\.value).min()))
            Divider().frame(height: 28)
            statisticItem(title: "平均", value: formatStatValue(average))
            Divider().frame(height: 28)
            statisticItem(title: "最大", value: formatStatValue(dataPoints.map(\.value).max()))
            Divider().frame(height: 28)
            statisticItem(title: "数据点", value: "\(dataPoints.count)")
        }
        .padding(.vertical, 14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.25))
        }
    }

    private func statisticItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var xAxisDesiredCount: Int {
        switch timeRange {
        case .fiveHours: return 5
        case .oneDay: return 4
        case .sevenDays: return 7
        }
    }

    private func xAxisLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        switch timeRange {
        case .fiveHours:
            formatter.dateFormat = "HH:mm"
        case .oneDay:
            formatter.dateFormat = "H时"
        case .sevenDays:
            formatter.dateFormat = "MM/dd"
        }
        return formatter.string(from: date)
    }

    private func selectedTimeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var displayedValue: String {
        guard let point = displayedDataPoint else { return metric.value }
        switch metric.kind {
        case .temperature, .humidity:
            return String(format: "%.1f", point.value)
        case .soil, .light:
            return String(format: "%.0f", point.value)
        }
    }

    private var displayedUnit: String {
        if displayedDataPoint != nil, metric.kind == .light {
            return "lx"
        }
        return metric.unit
    }

    private var displayedDataPoint: ChartDataPoint? {
        if let selectedPoint {
            return selectedPoint
        }
        guard metric.value == "--" || metric.value == "未接入" else {
            return nil
        }
        return dataPoints.last
    }

    private var chartXDomain: ClosedRange<Date> {
        timeRange.startDate(endingAt: rangeEndDate)...rangeEndDate
    }

    private var oneDayXAxisValues: [Date] {
        let calendar = Calendar.current
        let domain = chartXDomain
        guard var tick = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start else {
            return []
        }

        if tick < domain.lowerBound {
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: tick) else {
                return []
            }
            tick = nextHour
        }

        while calendar.component(.hour, from: tick).isMultiple(of: 6) == false {
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: tick) else {
                return []
            }
            tick = nextHour
        }

        var values: [Date] = []
        while tick < domain.upperBound, values.count < 4 {
            values.append(tick)
            guard let nextTick = calendar.date(byAdding: .hour, value: 6, to: tick) else {
                break
            }
            tick = nextTick
        }
        return values
    }

    private func yAxisLabel(for value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.0f", value)
        } else if value == value.rounded() {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    private var yAxisDomain: ClosedRange<Double> {
        let values = dataPoints.map(\.value)
        guard let minVal = values.min(), let maxVal = values.max() else {
            return 0...1
        }
        let padding = Swift.max(abs(maxVal - minVal) * 0.1, 0.5)
        return (minVal - padding)...(maxVal + padding)
    }

    private var average: Double? {
        guard !dataPoints.isEmpty else { return nil }
        return dataPoints.map(\.value).reduce(0, +) / Double(dataPoints.count)
    }

    private func formatStatValue(_ value: Double?) -> String {
        guard let value else { return "--" }
        switch metric.kind {
        case .soil:
            return String(format: "%.0f", value)
        default:
            return String(format: "%.1f", value)
        }
    }

    private func selectNearestPoint(to date: Date) {
        let fiveMinutes: TimeInterval = 5 * 60
        let snappedInterval = (date.timeIntervalSince1970 / fiveMinutes).rounded() * fiveMinutes
        let snappedDate = Date(timeIntervalSince1970: snappedInterval)
        let nearestPoint = dataPoints.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(snappedDate)) < abs(rhs.date.timeIntervalSince(snappedDate))
        }

        if nearestPoint?.id != selectedPoint?.id {
            selectedPoint = nearestPoint
        }
    }

    private func pointsSplitAtMissingSamples(_ points: [ChartDataPoint]) -> [ChartDataPoint] {
        let sortedPoints = points.sorted {
            if $0.date == $1.date {
                return $0.id < $1.id
            }
            return $0.date < $1.date
        }
        var segmentID = 0
        var previousPoint: ChartDataPoint?

        return sortedPoints.map { point in
            if let previousPoint {
                let sampleInterval = point.date.timeIntervalSince(previousPoint.date)
                let timestampCertaintyChanged = point.timestampEstimated != previousPoint.timestampEstimated
                if sampleInterval > Self.maximumContinuousSampleInterval || timestampCertaintyChanged {
                    segmentID += 1
                }
            }
            previousPoint = point
            return ChartDataPoint(
                id: point.id,
                date: point.date,
                value: point.value,
                timestampEstimated: point.timestampEstimated,
                segmentID: segmentID
            )
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        selectedPoint = nil
        let endDate = Date()
        rangeEndDate = endDate
        let startDate = timeRange.startDate(endingAt: endDate)

        if let previewData {
            // Preview mode: use injected data, filter by time range
            let filtered = previewData.filter { $0.date >= startDate && $0.date <= endDate }
            let segmentedPoints = pointsSplitAtMissingSamples(filtered)
            withAnimation(.easeInOut(duration: 0.3)) {
                dataPoints = segmentedPoints
                isLoading = false
            }
            return
        }

        guard let database else {
            withAnimation { isLoading = false }
            return
        }

        do {
            let readings = try await database.historyReadings(since: startDate)
            let points: [ChartDataPoint] = readings.compactMap { reading in
                guard reading.recordedAt <= endDate else { return nil }
                guard let value = extractValue(from: reading) else { return nil }
                return ChartDataPoint(
                    id: reading.sequence,
                    date: reading.recordedAt,
                    value: value,
                    timestampEstimated: reading.timestampEstimated
                )
            }
            let segmentedPoints = pointsSplitAtMissingSamples(points)
            withAnimation(.easeInOut(duration: 0.3)) {
                dataPoints = segmentedPoints
                isLoading = false
            }
        } catch {
            withAnimation {
                dataPoints = []
                isLoading = false
            }
        }
    }

    private func extractValue(from reading: HistoryReading) -> Double? {
        switch metric.kind {
        case .temperature:
            return reading.temperature
        case .humidity:
            return reading.humidity
        case .soil:
            return Double(reading.soilRaw)
        case .light:
            return reading.lightLux
        }
    }
}

// MARK: - Preview Helpers

private func generatePreviewData(
    count: Int = 144,
    hoursSpan: Double = 168,
    baseValue: Double,
    amplitude: Double,
    noiseRange: Double
) -> [ChartDataPoint] {
    let now = Date()
    let interval = (hoursSpan * 3600) / Double(count)
    return (0..<count).map { i in
        let date = now.addingTimeInterval(-hoursSpan * 3600 + Double(i) * interval)
        let progress = Double(i) / Double(count)
        // Simulate a day/night cycle with some noise
        let cycleValue = sin(progress * .pi * 4) * amplitude
        let trend = sin(progress * .pi * 0.8) * amplitude * 0.3
        let noise = Double.random(in: -noiseRange...noiseRange)
        let value = baseValue + cycleValue + trend + noise
        return ChartDataPoint(
            id: UInt32(i),
            date: date,
            value: value
        )
    }
}

#Preview("温度") {
    SensorChartSheet(
        metric: SensorMetric(
            kind: .temperature,
            title: "温度",
            value: "25.3",
            unit: "°C",
            symbol: "thermometer.medium",
            tint: Color(uiColor: .systemOrange)
        ),
        previewData: generatePreviewData(
            baseValue: 24.0,
            amplitude: 4.0,
            noiseRange: 0.8
        )
    )
}

#Preview("空气湿度") {
    SensorChartSheet(
        metric: SensorMetric(
            kind: .humidity,
            title: "空气湿度",
            value: "62.5",
            unit: "%",
            symbol: "humidity",
            tint: Color(uiColor: .systemBlue)
        ),
        previewData: generatePreviewData(
            baseValue: 60.0,
            amplitude: 12.0,
            noiseRange: 2.5
        )
    )
}

#Preview("土壤湿度") {
    SensorChartSheet(
        metric: SensorMetric(
            kind: .soil,
            title: "土壤湿度",
            value: "2180",
            unit: "ADC",
            symbol: "drop.degreesign",
            tint: Color(uiColor: .systemBrown)
        ),
        previewData: generatePreviewData(
            baseValue: 2200.0,
            amplitude: 300.0,
            noiseRange: 50.0
        )
    )
}

#Preview("光照") {
    SensorChartSheet(
        metric: SensorMetric(
            kind: .light,
            title: "光照",
            value: "540",
            unit: "lx",
            symbol: "sun.max.fill",
            tint: Color(uiColor: .systemYellow)
        ),
        previewData: generatePreviewData(
            baseValue: 450.0,
            amplitude: 380.0,
            noiseRange: 40.0
        )
    )
}

#Preview("光照 · 深色") {
    SensorChartSheet(
        metric: SensorMetric(
            kind: .light,
            title: "光照",
            value: "540",
            unit: "lx",
            symbol: "sun.max.fill",
            tint: Color(uiColor: .systemYellow)
        ),
        previewData: generatePreviewData(
            baseValue: 450.0,
            amplitude: 380.0,
            noiseRange: 40.0
        )
    )
    .preferredColorScheme(.dark)
}

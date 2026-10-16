import Charts
import CodexBarCore
import SwiftUI

struct SpendSpeedTrendView: View {
    let group: SpendDashboardModel.CurrencyGroup
    var onSelectDay: ((Date) -> Void)?
    var onClearSelectedDay: (() -> Void)?
    @State private var selectedModel = SpendSpeedTrendModel.Filter.all
    @State private var selectedEffort = SpendSpeedTrendModel.Filter.all

    var body: some View {
        let model = SpendSpeedTrendModel(group: self.group, model: self.selectedModel, effort: self.selectedEffort)
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L("spend_speed_title")).font(.headline)
                    Spacer()
                    self.filters(model)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("spend_speed_title")).font(.headline)
                    self.filters(model)
                }
            }
            Text(L("spend_turn_performance_help"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(L("spend_turn_performance_help"))
            if let summary = model.trend.summary {
                SpendSpeedTrendContent(
                    group: self.group,
                    model: model,
                    summary: summary,
                    onSelectDay: self.onSelectDay,
                    onClearSelectedDay: self.onClearSelectedDay)
            } else {
                ContentUnavailableView(
                    L("No data available"),
                    systemImage: "speedometer",
                    description: Text(L("spend_speed_empty")))
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .environment(\.calendar, self.group.calendar)
        .environment(\.timeZone, self.group.timeZone)
        .accessibilityIdentifier("spend-speed-panel")
    }

    private func filters(_ model: SpendSpeedTrendModel) -> some View {
        HStack(spacing: 8) {
            Picker(L("All models"), selection: Binding(
                get: { model.model },
                set: { self.selectedModel = $0; self.selectedEffort = .all }))
            {
                ForEach(model.models, id: \.self) { filter in
                    Text(self.filterTitle(filter, isModel: true)).tag(filter)
                }
            }
            .accessibilityIdentifier("spend-speed-model")
            Picker(L("spend_speed_all_efforts"), selection: Binding(
                get: { model.effort }, set: { self.selectedEffort = $0 }))
            {
                ForEach(model.efforts, id: \.self) { filter in
                    Text(self.filterTitle(filter, isModel: false)).tag(filter)
                }
            }
            .accessibilityIdentifier("spend-speed-effort")
        }
        .labelsHidden().controlSize(.small)
        .frame(maxWidth: 390)
    }

    private func filterTitle(_ filter: SpendSpeedTrendModel.Filter, isModel: Bool) -> String {
        switch filter {
        case .all: L(isModel ? "All models" : "spend_speed_all_efforts")
        case .unknown: L(isModel ? "Unknown model" : "Unknown reasoning effort")
        case let .named(value): value
        }
    }
}

/// Hover and metric selection only redraw the chart, without regrouping the session history.
private struct SpendSpeedTrendContent: View {
    let group: SpendDashboardModel.CurrencyGroup
    let model: SpendSpeedTrendModel
    let summary: CostUsageTurnPerformanceSummary
    var onSelectDay: ((Date) -> Void)?
    var onClearSelectedDay: (() -> Void)?
    @State private var showsFirstToken = false
    @State private var inspectedDate: Date?
    @State private var pinnedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.metrics(self.model, summary: self.summary)
            HStack {
                Picker(L("Chart"), selection: self.$showsFirstToken) {
                    Text(L("spend_speed_tps")).tag(false)
                    Text(L("spend_performance_first_token")).tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .frame(maxWidth: 250)
                .accessibilityIdentifier("spend-speed-metric")
                Spacer()
                if self.model.isHourly, let onClearSelectedDay {
                    Button(L("Overview"), action: onClearSelectedDay).controlSize(.small)
                }
            }
            self.chart(self.model)
            self.inspection(self.model)
        }
    }

    private func metrics(_ model: SpendSpeedTrendModel, summary: CostUsageTurnPerformanceSummary) -> some View {
        let latest = model.trend.latest
        let latestRate = latest.map { Double($0.outputTokens) / Double($0.durationMilliseconds) * 1000 }
        return SpendPerformanceMetricStrip(metrics: [
            SpendPerformanceMetric(
                id: "latest",
                label: L("spend_speed_latest"),
                value: self.rateText(latestRate),
                note: latest.map { self.dateText($0.completedAt, includesTime: true) }),
            SpendPerformanceMetric(
                id: "weighted",
                label: L("spend_speed_weighted"),
                value: self.rateText(summary.outputTokensPerSecond),
                note: L("spend_performance_turn_count", codexBarLocalizedInteger(summary.sampleCount))),
            SpendPerformanceMetric(
                id: "first-token",
                label: L("spend_performance_first_token"),
                value: self.secondsText(summary.medianFirstTokenMilliseconds),
                note: L(
                    "First-token samples: %@ / %@",
                    codexBarLocalizedInteger(summary.firstTokenSampleCount),
                    codexBarLocalizedInteger(summary.sampleCount))),
        ])
    }

    private func chart(_ model: SpendSpeedTrendModel) -> some View {
        Chart {
            ForEach(model.trend.buckets) { bucket in
                if let value = self.value(bucket) {
                    LineMark(
                        x: .value(L("Day"), bucket.interval.start),
                        y: .value(self.metricTitle, value),
                        series: .value(
                            "segment",
                            self.showsFirstToken ? bucket.firstTokenSegment : bucket.outputSegment))
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    PointMark(
                        x: .value(L("Day"), bucket.interval.start),
                        y: .value(self.metricTitle, value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(28)
                        .accessibilityLabel(self.dateText(bucket.interval.start, includesTime: model.isHourly))
                        .accessibilityValue(self.bucketText(bucket))
                }
            }
            if let bucket = self.selectedBucket(model) {
                RuleMark(x: .value(L("Day"), bucket.interval.start))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: model.domain)
        .chartYScale(domain: 0...self.upperBound(model))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(self.axisText(date, hourly: model.isHourly))
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel(self.showsFirstToken ? L("spend_performance_first_token") + " (s)" : "tok/s")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let frame = proxy.plotFrame, geometry[frame].contains(location) else {
                                self.inspectedDate = nil
                                return
                            }
                            self.inspectedDate = proxy.value(atX: location.x - geometry[frame].minX, as: Date.self)
                        case .ended: self.inspectedDate = nil
                        }
                    }
            }
        }
        .frame(height: 190)
        .accessibilityLabel(L("spend_speed_title"))
        .accessibilityIdentifier("spend-speed-chart")
    }

    private func inspection(_ model: SpendSpeedTrendModel) -> some View {
        let bucket = self.selectedBucket(model) ?? (self.inspectedDate == nil ? model.trend.buckets.last : nil)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let bucket {
                    Picker(L(model.isHourly ? "Hour" : "Day"), selection: Binding(
                        get: { bucket.id }, set: { self.pinnedDate = $0 }))
                    {
                        ForEach(model.trend.buckets) { item in
                            Text(self.dateText(item.id, includesTime: model.isHourly)).tag(item.id)
                        }
                    }
                    .labelsHidden().controlSize(.small)
                    .frame(maxWidth: 200, alignment: .leading)
                    .accessibilityIdentifier("spend-speed-bucket")
                    Spacer()
                    if !model.isHourly, let onSelectDay {
                        Button(L("Hour")) { onSelectDay(bucket.interval.start) }.controlSize(.small)
                    }
                    Text(self.bucketText(bucket)).monospacedDigit()
                } else {
                    Text(L("No data available")).foregroundStyle(.secondary)
                }
            }
            Text(self.group.timeZone.identifier).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("spend-speed-inspection")
    }

    private var metricTitle: String {
        self.showsFirstToken ? L("spend_performance_first_token") : L("spend_speed_tps")
    }

    private func selectedBucket(_ model: SpendSpeedTrendModel) -> CostUsageTurnPerformanceTrend.Bucket? {
        guard let date = self.inspectedDate ?? self.pinnedDate else { return nil }
        return model.trend.buckets.first { $0.interval.start <= date && date < $0.interval.end }
    }

    private func value(_ bucket: CostUsageTurnPerformanceTrend.Bucket) -> Double? {
        self.showsFirstToken
            ? bucket.summary.medianFirstTokenMilliseconds.map { $0 / 1000 }
            : bucket.summary.outputTokensPerSecond
    }

    private func upperBound(_ model: SpendSpeedTrendModel) -> Double {
        max(1, (model.trend.buckets.compactMap { self.value($0) }.max() ?? 0) * 1.15)
    }

    private func bucketText(_ bucket: CostUsageTurnPerformanceTrend.Bucket) -> String {
        let summary = bucket.summary
        let value = self.showsFirstToken
            ? self.secondsText(summary.medianFirstTokenMilliseconds) : self.rateText(summary.outputTokensPerSecond)
        let coverage = self.showsFirstToken
            ? L(
                "First-token samples: %@ / %@",
                codexBarLocalizedInteger(summary.firstTokenSampleCount),
                codexBarLocalizedInteger(summary.sampleCount))
            : L("spend_performance_turn_count", codexBarLocalizedInteger(summary.sampleCount))
        return value + " · " + coverage
    }

    private func rateText(_ value: Double?) -> String {
        value.map { L("spend_performance_rate", self.number($0)) } ?? "—"
    }

    private func secondsText(_ value: Double?) -> String {
        value.map { L("spend_performance_seconds", self.number($0 / 1000)) } ?? "—"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
    }

    private func dateText(_ date: Date, includesTime: Bool) -> String {
        let style = Date.FormatStyle(
            locale: codexBarLocalizedLocale(), calendar: self.group.calendar, timeZone: self.group.timeZone)
            .month(.abbreviated).day()
        return date.formatted(includesTime ? style.hour().minute().timeZone(.iso8601(.short)) : style)
    }

    private func axisText(_ date: Date, hourly: Bool) -> String {
        let style = Date.FormatStyle(
            locale: codexBarLocalizedLocale(), calendar: self.group.calendar, timeZone: self.group.timeZone)
        return date.formatted(hourly ? style.hour() : style.month(.abbreviated).day())
    }
}

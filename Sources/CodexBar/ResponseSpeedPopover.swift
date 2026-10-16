import Charts
import CodexBarCore
import SwiftUI

struct ResponseSpeedPopover: View {
    @Bindable var model: ResponseSpeedModel
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16)
        {
            self.header
            Picker(
                L("response_speed_window"),
                selection: self.$model.window)
            {
                ForEach(ResponseSpeedWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("response-speed-window")
            self.content
            self.footer
        }
        .padding(18)
        .frame(width: 400)
        .accessibilityIdentifier("response-speed-popover")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(
                alignment: .leading,
                spacing: 4)
            {
                Label(
                    L("response_speed_title"),
                    systemImage: "speedometer").font(.headline)
                Text(L("response_speed_subtitle")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: self.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L("Refresh"))
                .accessibilityLabel(L("Refresh"))
            Button(action: self.openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help(L("Settings..."))
                .accessibilityLabel(L("Settings..."))
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = self.model.rows
        if rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: self.model.isIndexing ? "clock" : "waveform.path")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(L(self.model.isIndexing ? "response_speed_indexing" : "response_speed_empty"))
                    .font(.subheadline.weight(.medium))
                Text(L("response_speed_empty_help"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 180)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(rows) { row in
                        ResponseSpeedCard(
                            row: row,
                            now: self.model.now)
                    }
                }
            }
            .frame(height: min(CGFloat(rows.count) * 192, 420))
        }
    }

    private var footer: some View {
        VStack(
            alignment: .leading,
            spacing: 7)
        {
            Toggle(
                L("response_speed_short"),
                isOn: self.$model.includeShortResponses)
                .toggleStyle(.checkbox).font(.caption)
            if self.model.isIndexing {
                Label(
                    L("response_speed_indexing"),
                    systemImage: "clock")
            }
            if self.model.unreadableFiles > 0 {
                Label(
                    L("response_speed_unreadable"),
                    systemImage: "exclamationmark.triangle")
            }
            if self.model.historyLimited {
                Label(
                    L("response_speed_limited"),
                    systemImage: "info.circle")
            }
            if self.model.lowPower {
                Label(
                    L("response_speed_power"),
                    systemImage: "leaf")
            }
            Text(L("response_speed_help"))
                .fixedSize(
                    horizontal: false,
                    vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct ResponseSpeedCard: View {
    let row: ResponseSpeedModelRow
    let now: Date

    private var isRecent: Bool {
        self.now.timeIntervalSince(self.row.latest.completedAt) < ResponseSpeedSummary.staleAfter
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 9)
        {
            HStack(alignment: .top) {
                VStack(
                    alignment: .leading,
                    spacing: 3)
                {
                    Text(self.row.key.model).font(.subheadline.weight(.semibold))
                        .lineLimit(2).textSelection(.enabled)
                    Text([self.row.key.source.title, self.row.key.effort, self.row.key.tier]
                        .compactMap(\.self).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(
                    alignment: .trailing,
                    spacing: 2)
                {
                    Text(ResponseSpeedModel.rate(self.row.recentMedian))
                        .font(.system(
                            size: 27,
                            weight: .semibold,
                            design: .rounded)).monospacedDigit()
                    Text(L("response_speed_unit")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Text(L("response_speed_recent"))
                Spacer()
                if let change = self.row.change {
                    let percent = abs(change).formatted(.number.precision(.fractionLength(0)))
                    Text(
                        abs(change) < 1 ? "≈0%"
                            :
                            "\(change >= 0 ? "↑" : "↓") \(percent)%")
                        .foregroundStyle(abs(change) < 10 ? Color.secondary : (change >= 0 ? .green : .orange))
                    Text(L("response_speed_baseline"))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Chart(self.chartPoints) { point in
                LineMark(
                    x: .value(L("response_speed_time"), point.sample.completedAt),
                    y: .value("tok/s", point.sample.tokensPerSecond),
                    series: .value("Activity", point.segment))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                PointMark(
                    x: .value(L("response_speed_time"), point.sample.completedAt),
                    y: .value("tok/s", point.sample.tokensPerSecond))
                    .symbolSize(10).foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .frame(height: 40)
            .accessibilityLabel(L("response_speed_chart"))
            .help(L("response_speed_chart_help"))
            HStack(spacing: 10) {
                Text("P50 \(ResponseSpeedModel.rate(self.row.median))")
                Text("P90 \(ResponseSpeedModel.rate(self.row.p90))")
                Spacer()
                Text(L("response_speed_count", self.row.samples.count))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Text(L("%@ tokens", UsageFormatter.tokenCountString(self.row.outputTokens)))
                Spacer()
                Text(self.relativeTime)
                if !self.isRecent { Text(L("response_speed_idle")) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            .primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var chartSamples: [ResponseSpeedSample] {
        // Bound Swift Charts work while preserving both ends. Metrics above use every response.
        let samples = self.row.samples
        guard samples.count > 80 else { return samples }
        return (0..<80).map { samples[$0 * (samples.count - 1) / 79] }
    }

    private struct ChartPoint: Identifiable {
        let sample: ResponseSpeedSample
        let segment: Int
        var id: String {
            self.sample.id
        }
    }

    private var chartPoints: [ChartPoint] {
        var previous: Date?
        var segment = 0
        return self.chartSamples.map { sample in
            if let previous, sample.completedAt.timeIntervalSince(previous) > 900 { segment += 1 }
            previous = sample.completedAt
            return ChartPoint(sample: sample, segment: segment)
        }
    }

    private var relativeTime: String {
        if self.now.timeIntervalSince(self.row.latest.completedAt) < 1 { return L("response_speed_now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = codexBarLocalizedLocale()
        return formatter.localizedString(for: self.row.latest.completedAt, relativeTo: self.now)
    }
}

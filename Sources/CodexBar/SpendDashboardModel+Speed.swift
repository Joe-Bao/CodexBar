import CodexBarCore
import Foundation

extension SpendDashboardModel {
    /// Collect before the cost-ranked session list is capped. Speed must not describe only expensive sessions.
    static func performanceSamples(
        summaries: [InputSummary],
        bounds: ClosedRange<Date>,
        calendar: Calendar,
        selectedDay: Date?) -> [CostUsageTurnPerformanceSample]
    {
        summaries.filter { $0.input.provider == .codex && $0.input.sourceKind == .native }
            .flatMap(\.input.snapshot.sessions)
            .flatMap(\.turnPerformanceSamples)
            .filter {
                let day = calendar.startOfDay(for: $0.completedAt)
                return bounds.contains(day) && (selectedDay == nil || day == selectedDay)
            }
    }
}

struct SpendSpeedTrendModel {
    enum Filter: Hashable {
        case all, unknown, named(String)

        func matches(_ value: String?) -> Bool {
            switch self {
            case .all: true
            case .unknown: value == nil
            case let .named(name): value == name
            }
        }

        static func options(_ values: [String?]) -> [Self] {
            [.all] + Set(values.compactMap(\.self)).sorted().map(named)
                + (values.contains(nil) ? [.unknown] : [])
        }
    }

    let models: [Filter]
    let efforts: [Filter]
    let model: Filter
    let effort: Filter
    let trend: CostUsageTurnPerformanceTrend
    let domain: ClosedRange<Date>
    let isHourly: Bool

    init(group: SpendDashboardModel.CurrencyGroup, model: Filter = .all, effort: Filter = .all) {
        self.models = Filter.options(group.performanceSamples.map(\.model))
        let selectedModel = self.models.contains(model) ? model : .all
        self.model = selectedModel
        let modelSamples = group.performanceSamples.filter { selectedModel.matches($0.model) }
        self.efforts = Filter.options(modelSamples.map(\.reasoningEffort))
        let selectedEffort = self.efforts.contains(effort) ? effort : .all
        self.effort = selectedEffort
        self.isHourly = group.selectedDay != nil
        let dayInterval = group.selectedDay.flatMap { group.calendar.dateInterval(of: .day, for: $0) }
        self.domain = dayInterval.map { $0.start...$0.end } ?? group.performanceDomain ?? group.chartDomain
        self.trend = CostUsageTurnPerformanceTrend(
            samples: modelSamples.filter { selectedEffort.matches($0.reasoningEffort) },
            range: self.domain.lowerBound..<self.domain.upperBound,
            granularity: self.isHourly ? .hour : .day,
            calendar: group.calendar)
    }
}

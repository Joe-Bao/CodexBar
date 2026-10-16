import Foundation

/// Completion-time buckets of validated whole-turn observations, never streaming token estimates.
public struct CostUsageTurnPerformanceTrend: Sendable, Equatable {
    public enum Granularity: Sendable {
        case hour, day

        var component: Calendar.Component {
            self == .hour ? .hour : .day
        }
    }

    public struct Bucket: Sendable, Equatable, Identifiable {
        public let interval: DateInterval
        public let summary: CostUsageTurnPerformanceSummary
        /// Separate line segments across periods with no observations.
        public let outputSegment: Int
        public let firstTokenSegment: Int

        public var id: Date {
            self.interval.start
        }
    }

    public let buckets: [Bucket]
    public let summary: CostUsageTurnPerformanceSummary?
    public let latest: CostUsageTurnPerformanceSample?

    public init(
        samples: [CostUsageTurnPerformanceSample],
        range: Range<Date>,
        granularity: Granularity,
        calendar: Calendar)
    {
        let samples = samples.filter { range.contains($0.completedAt) }
        self.summary = CostUsageTurnPerformanceSummary(samples: samples)
        self.latest = samples.max { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
            // Stable tie-breaking for equal timestamps across sessions.
            if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens < rhs.outputTokens }
            return lhs.durationMilliseconds < rhs.durationMilliseconds
        }
        let grouped = Dictionary(grouping: samples) {
            calendar.dateInterval(of: granularity.component, for: $0.completedAt)?.start
        }
        var buckets: [Bucket] = []
        var previousEnd: Date?
        var previousFirstTokenEnd: Date?
        var outputSegment = 0
        var firstTokenSegment = 0
        for start in grouped.keys.compactMap(\.self).sorted() {
            guard let observations = grouped[start],
                  let summary = CostUsageTurnPerformanceSummary(samples: observations),
                  let interval = calendar.dateInterval(of: granularity.component, for: start)
            else { continue }
            if previousEnd != interval.start { outputSegment += 1 }
            if previousFirstTokenEnd != interval.start { firstTokenSegment += 1 }
            buckets.append(Bucket(
                interval: interval,
                summary: summary,
                outputSegment: outputSegment,
                firstTokenSegment: firstTokenSegment))
            previousEnd = interval.end
            previousFirstTokenEnd = summary.firstTokenSampleCount > 0 ? interval.end : nil
        }
        self.buckets = buckets
    }
}

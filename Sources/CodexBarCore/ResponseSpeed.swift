import Foundation

public enum ResponseSpeedSource: String, Codable, Sendable, CaseIterable {
    case codex
    case claude

    public var title: String {
        self == .codex ? "Codex" : "Claude Code"
    }
}

/// Only usage and timing metadata. Never retains message text, tool arguments, or credentials.
public struct ResponseSpeedSample: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: ResponseSpeedSource
    public let model: String
    public let effort: String?
    public let tier: String?
    public let completedAt: Date
    public let duration: TimeInterval
    public let outputTokens: Int

    public init(
        id: String,
        source: ResponseSpeedSource,
        model: String,
        effort: String? = nil,
        tier: String? = nil,
        completedAt: Date,
        duration: TimeInterval,
        outputTokens: Int)
    {
        self.id = "\(source.rawValue):\(id)"
        self.source = source
        self.model = model
        self.effort = effort
        self.tier = tier
        self.completedAt = completedAt
        self.duration = duration
        self.outputTokens = outputTokens
    }

    public var tokensPerSecond: Double {
        Double(self.outputTokens) / self.duration
    }

    public var key: ResponseSpeedModelKey {
        .init(
            source: self.source,
            model: self.model,
            effort: self.effort,
            tier: self.tier)
    }
}

public struct ResponseSpeedModelKey: Hashable, Sendable {
    public let source: ResponseSpeedSource
    public let model: String
    public let effort: String?
    public let tier: String?
}

public struct ResponseSpeedModelRow: Identifiable, Equatable, Sendable {
    public let key: ResponseSpeedModelKey
    public let samples: [ResponseSpeedSample]
    public let recentMedian: Double
    public let median: Double
    public let p90: Double
    public let baseline: Double?
    public var id: ResponseSpeedModelKey {
        self.key
    }

    public var latest: ResponseSpeedSample {
        self.samples[self.samples.count - 1]
    }

    public var change: Double? {
        self.baseline.map { (self.recentMedian / $0 - 1) * 100 }
    }

    public var outputTokens: Int {
        self.samples.reduce(0) { partial, sample in
            let sum = partial.addingReportingOverflow(sample.outputTokens)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
}

public enum ResponseSpeedSummary {
    public static let retention: TimeInterval = 7 * 86400
    public static let staleAfter: TimeInterval = 30 * 60

    public static func rows(
        samples: [ResponseSpeedSample],
        now: Date,
        window: TimeInterval,
        minimumOutputTokens: Int = 200) -> [ResponseSpeedModelRow]
    {
        // Copied, archived and resumed transcripts may repeat a response ID.
        var unique: [String: ResponseSpeedSample] = [:]
        for sample in samples where sample.duration > 0 && sample.duration.isFinite
            && sample.outputTokens >= minimumOutputTokens && sample.outputTokens > 0
            && sample.completedAt <= now && sample.completedAt >= now.addingTimeInterval(-Self.retention)
        {
            if let previous = unique[sample.id], previous.completedAt >= sample.completedAt { continue }
            unique[sample.id] = sample
        }
        return Dictionary(
            grouping: unique.values,
            by: \.key).compactMap { key, all in
            let ordered = all.sorted { ($0.completedAt, $0.id) < ($1.completedAt, $1.id) }
            let visible = ordered.filter { $0.completedAt >= now.addingTimeInterval(-window) }
            guard !visible.isEmpty else { return nil }
            let recent = Array(visible.suffix(5))
            let recentIDs = Set(recent.map(\.id))
            let prior = ordered.filter { !recentIDs.contains($0.id) }
            return ResponseSpeedModelRow(
                key: key,
                samples: visible,
                recentMedian: Self.quantile(
                    recent.map(\.tokensPerSecond),
                    fraction: 0.5),
                median: Self.quantile(
                    visible.map(\.tokensPerSecond),
                    fraction: 0.5),
                p90: Self.quantile(
                    visible.map(\.tokensPerSecond),
                    fraction: 0.9),
                baseline: prior.count >= 5 ? Self.quantile(
                    prior.map(\.tokensPerSecond),
                    fraction: 0.5) : nil)
        }.sorted { ($0.latest.completedAt, $0.latest.id) > ($1.latest.completedAt, $1.latest.id) }
    }

    public static func activeRow(
        in rows: [ResponseSpeedModelRow],
        now: Date) -> ResponseSpeedModelRow?
    {
        rows.first { now.timeIntervalSince($0.latest.completedAt) < Self.staleAfter }
    }

    private static func quantile(
        _ values: [Double],
        fraction: Double) -> Double
    {
        let sorted = values.sorted()
        let index = Double(sorted.count - 1) * fraction
        let low = Int(index)
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (index - Double(low))
    }
}

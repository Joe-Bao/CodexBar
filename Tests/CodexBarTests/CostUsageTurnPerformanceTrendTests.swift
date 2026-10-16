import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTurnPerformanceTrendTests {
    private let start = Date(timeIntervalSince1970: 1_778_371_200) // 2026-05-10 UTC

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func `rates use total tokens over total time and missing buckets are not zero`() throws {
        let samples = try [
            self.sample(offset: 100, tokens: 100, duration: 1000, firstToken: 100),
            self.sample(offset: 200, tokens: 100, duration: 9000, firstToken: 300),
            self.sample(offset: 86400 + 100, tokens: 60, duration: 1000),
            self.sample(offset: 3 * 86400 + 100, tokens: 40, duration: 1000, firstToken: 400),
        ]
        let trend = self.trend(samples)
        #expect(trend.buckets.count == 3)
        #expect(trend.buckets.map(\.summary.outputTokensPerSecond) == [20, 60, 40])
        #expect(trend.summary?.outputTokensPerSecond == 25)
        #expect(trend.buckets.map(\.outputSegment) == [1, 1, 2])
        #expect(trend.buckets.map(\.firstTokenSegment) == [1, 1, 2])
        #expect(trend.buckets[0].summary.medianFirstTokenMilliseconds == 200)
        #expect(trend.buckets[1].summary.medianFirstTokenMilliseconds == nil)
        #expect(trend.latest == samples.last)
        #expect(self.trend(samples.reversed()) == trend)
    }

    @Test
    func `first token lines break across observed turns without first token timing`() throws {
        let samples = try (0..<3).map {
            try self.sample(
                offset: Double($0 * 86400 + 100),
                tokens: 100,
                duration: 1000,
                firstToken: $0 == 1 ? nil : 100)
        }
        let trend = self.trend(samples)
        #expect(trend.buckets.map(\.outputSegment) == [1, 1, 1])
        #expect(trend.buckets.map(\.firstTokenSegment) == [1, 1, 2])
    }

    @Test
    func `range is half open and absent observations remain unavailable`() throws {
        let samples = try [
            self.sample(offset: -1, tokens: 100, duration: 1000),
            self.sample(offset: 0, tokens: 0, duration: 1000),
            self.sample(offset: 4 * 86400, tokens: 100, duration: 1000),
        ]
        let trend = self.trend(samples)
        #expect(trend.summary?.sampleCount == 1)
        #expect(trend.summary?.outputTokensPerSecond == 0)
        #expect(self.trend([]).summary == nil)
        #expect(self.trend([]).latest == nil)
        #expect(self.trend([]).buckets.isEmpty)
    }

    @Test
    func `overflow does not publish a misleading rate`() throws {
        let sample = try self.sample(offset: 10, tokens: Int.max, duration: 1000)
        let trend = self.trend([sample, sample])
        #expect(trend.summary == nil)
        #expect(trend.buckets.isEmpty)
    }

    @Test
    func `repeated local hours remain distinct and spring days use calendar boundaries`() throws {
        var calendar = self.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let first = try #require(ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z"))
        let samples = try [first, first.addingTimeInterval(3600)].map {
            try #require(CostUsageTurnPerformanceSample(
                completedAt: $0, outputTokens: 100, durationMilliseconds: 1000))
        }
        let day = try #require(calendar.dateInterval(of: .day, for: first))
        let trend = CostUsageTurnPerformanceTrend(
            samples: samples, range: day.start..<day.end, granularity: .hour, calendar: calendar)
        #expect(day.duration == 25 * 3600)
        #expect(trend.buckets.count == 2)
        #expect(trend.buckets[0].id != trend.buckets[1].id)
        #expect(trend.buckets.map(\.outputSegment) == [1, 1])
        let spring = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:00:00Z"))
        let springSample = try #require(CostUsageTurnPerformanceSample(
            completedAt: spring, outputTokens: 100, durationMilliseconds: 1000))
        let springTrend = CostUsageTurnPerformanceTrend(
            samples: [springSample],
            range: spring.addingTimeInterval(-86400)..<spring.addingTimeInterval(86400),
            granularity: .day,
            calendar: calendar)
        let springDuration = try #require(springTrend.buckets.first?.interval.duration)
        #expect(springDuration == 82800.0)
    }

    private func trend(_ samples: [CostUsageTurnPerformanceSample]) -> CostUsageTurnPerformanceTrend {
        CostUsageTurnPerformanceTrend(
            samples: samples,
            range: self.start..<self.start.addingTimeInterval(4 * 86400),
            granularity: .day,
            calendar: self.calendar)
    }

    private func sample(offset: Double, tokens: Int, duration: Int, firstToken: Int? = nil) throws
        -> CostUsageTurnPerformanceSample
    {
        try #require(CostUsageTurnPerformanceSample(
            completedAt: self.start.addingTimeInterval(offset),
            outputTokens: tokens,
            durationMilliseconds: duration,
            firstTokenMilliseconds: firstToken))
    }
}

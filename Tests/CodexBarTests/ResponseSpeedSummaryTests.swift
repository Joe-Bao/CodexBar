import Foundation
import Testing
@testable import CodexBarCore

struct ResponseSpeedSummaryTests {
    private let now = ResponseSpeedFixture.base.addingTimeInterval(10000)

    @Test
    func `recent median baseline and percentiles use individual responses`() throws {
        let samples = (0..<10)
            .map { index in self.sample(
                id: "\(index)",
                rate: index < 5 ? 50 : 100,
                ago: 100 - index) }
        let row = try #require(ResponseSpeedSummary.rows(
            samples: samples,
            now: self.now,
            window: 3600).first)
        #expect(row.recentMedian == 100)
        #expect(row.baseline == 50)
        #expect(row.change == 100)
        #expect(row.median == 75)
        #expect(row.p90 == 100)
    }

    @Test
    func `provider effort and service tier are never merged`() {
        let samples = [
            self.sample(
                id: "1",
                source: .codex), self.sample(
                id: "2",
                source: .claude),
            self.sample(
                id: "3",
                effort: "high"), self.sample(
                id: "4",
                tier: "priority"),
        ]
        #expect(ResponseSpeedSummary.rows(
            samples: samples,
            now: self.now,
            window: 3600).count == 4)
    }

    @Test
    func `default short response filtering does not affect explicit inclusion`() {
        let sample = ResponseSpeedSample(
            id: "short",
            source: .codex,
            model: "example-model",
            completedAt: self.now,
            duration: 10,
            outputTokens: 100)
        #expect(ResponseSpeedSummary.rows(
            samples: [sample],
            now: self.now,
            window: 3600).isEmpty)
        #expect(ResponseSpeedSummary.rows(
            samples: [sample],
            now: self.now,
            window: 3600,
            minimumOutputTokens: 1).count == 1)
    }

    @Test
    func `stale future and expired samples never masquerade as current speed`() {
        let samples = [
            self.sample(
                id: "idle",
                ago: 1900),
            self.sample(
                id: "future",
                ago: -10),
            self.sample(
                id: "expired",
                ago: 8 * 86400),
        ]
        let rows = ResponseSpeedSummary.rows(
            samples: samples,
            now: self.now,
            window: 7 * 86400)
        #expect(rows.count == 1)
        #expect(ResponseSpeedSummary.activeRow(
            in: rows,
            now: self.now) == nil)
    }

    @Test
    func `same response content blocks are replaced instead of summed`() throws {
        let first = self.sample(
            id: "message",
            rate: 100,
            ago: 10)
        let last = self.sample(
            id: "message",
            rate: 50,
            ago: 5)
        let row = try #require(ResponseSpeedSummary.rows(
            samples: [first, last],
            now: self.now,
            window: 3600).first)
        #expect(row.samples.count == 1)
        #expect(row.recentMedian == 50)
        #expect(row.outputTokens == 1000)
        #expect(row.baseline == nil)
    }

    private func sample(
        id: String,
        source: ResponseSpeedSource = .codex,
        rate: Double = 100,
        ago: Int = 0,
        effort: String? = nil,
        tier: String? = nil) -> ResponseSpeedSample
    {
        .init(
            id: id,
            source: source,
            model: "example-model",
            effort: effort,
            tier: tier,
            completedAt: self.now.addingTimeInterval(-Double(ago)),
            duration: 1000 / rate,
            outputTokens: 1000)
    }
}

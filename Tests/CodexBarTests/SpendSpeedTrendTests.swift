import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SpendSpeedTrendTests {
    private static let now = Date(timeIntervalSince1970: 1_778_414_400)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func `speed uses every native session before cost ranking is capped`() throws {
        let group = try Self.group(sessionCount: 60)
        #expect(group.sessions.count == 50)
        #expect(group.performanceSamples.count == 60)
        #expect(SpendSpeedTrendModel(group: group).trend.summary?.sampleCount == 60)
        #expect(group.totalCost == 1)
        #expect(group.totalTokens == 1000)
    }

    @Test
    func `source and completion day filters apply to speed without changing billing`() throws {
        for (provider, kind) in [
            (UsageProvider.codex, SpendDashboardModel.SourceKind.native),
            (.codex, .openCodex), (.claude, .native),
        ] {
            let group = try Self.group(provider: provider, kind: kind)
            #expect(group.performanceSamples.count == (provider == .codex && kind == .native ? 24 : 0))
        }
        let today = try Self.group(selectedDay: Self.now)
        let todayModel = SpendSpeedTrendModel(group: today)
        #expect(todayModel.isHourly)
        #expect(todayModel.trend.summary?.sampleCount == 4)
        #expect(todayModel.trend.buckets.count == 4)
        let empty = try Self.group(selectedDay: Self.now.addingTimeInterval(-20 * 86400))
        #expect(empty.performanceSamples.isEmpty)
        let hidden = try Self.build(hiddenSourceIDs: ["codex"])
        #expect(hidden.groups.flatMap(\.performanceSamples).isEmpty)
    }

    @Test
    func `model and effort filters retain unknown attribution and reset stale selections`() throws {
        let group = try Self.group()
        let all = SpendSpeedTrendModel(group: group)
        #expect(all.models == [.all, .named("example-fast"), .named("example-steady"), .unknown])
        let fast = SpendSpeedTrendModel(group: group, model: .named("example-fast"), effort: .named("high"))
        #expect(fast.trend.summary?.sampleCount == 6)
        #expect(fast.trend.summary?.details.groups.count == 1)
        #expect(fast.trend.summary?.details.groups.first?.model == "example-fast")
        let unknown = SpendSpeedTrendModel(group: group, model: .unknown)
        #expect(unknown.trend.summary?.sampleCount == 6)
        #expect(unknown.efforts == [.all, .unknown])
        let stale = SpendSpeedTrendModel(group: group, model: .named("removed-model"), effort: .named("removed-effort"))
        #expect(stale.model == .all)
        #expect(stale.effort == .all)
        #expect(stale.trend == all.trend)
    }

    @Test
    func `speed tab is available for configured Codex and observations but not other providers`() {
        #expect(spendDashboardAvailableDetailSections(
            hasProjects: false, hasSessions: false, hasPerformance: true) == [.providers, .speed])
        #expect(!spendDashboardAvailableDetailSections(hasProjects: false, hasSessions: true).contains(.speed))
        #expect(spendDashboardAvailableDetailSections(
            hasProjects: false, hasSessions: false, supportsCodexDetails: true).contains(.speed))
    }

    @Test
    func `render production speed panel using synthetic observations`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SPEED_UI_PROOF_DIR"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans"] {
            for width in [820.0, 420.0] {
                for dark in [false, true] {
                    let group = try Self.group()
                    try await CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                        try await Self.render(
                            SpendSpeedTrendView(group: group),
                            width: width,
                            dark: dark,
                            url: root.appendingPathComponent("speed-\(language)-\(Int(width))-\(dark).png"))
                    }
                }
            }
        }
        let empty = try Self.group(sessionCount: 0)
        try await CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            try await Self.render(
                SpendSpeedTrendView(group: empty),
                width: 420,
                dark: false,
                url: root.appendingPathComponent("speed-empty.png"))
        }
    }

    private static func render(_ view: some View, width: Double, dark: Bool, url: URL) async throws {
        let hosting = NSHostingView(rootView: view.padding(20).frame(width: width)
            .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : .white)
            .foregroundStyle(dark ? .white : .black)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private static func group(
        sessionCount: Int = 24,
        provider: UsageProvider = .codex,
        kind: SpendDashboardModel.SourceKind = .native,
        selectedDay: Date? = nil) throws -> SpendDashboardModel.CurrencyGroup
    {
        try #require(self.build(
            sessionCount: sessionCount, provider: provider, kind: kind, selectedDay: selectedDay).groups.first)
    }

    private static func build(
        sessionCount: Int = 24,
        provider: UsageProvider = .codex,
        kind: SpendDashboardModel.SourceKind = .native,
        selectedDay: Date? = nil,
        hiddenSourceIDs: Set<String> = []) throws -> SpendDashboardModel
    {
        let sessions = try (0..<sessionCount).map { index in
            let sample = try #require(CostUsageTurnPerformanceSample(
                completedAt: Self.now.addingTimeInterval(Double(-(index % 6) * 86400 + (index / 6) * 3600)),
                outputTokens: 100 + index * 10,
                durationMilliseconds: 1000 + index * 300,
                firstTokenMilliseconds: index.isMultiple(of: 5) ? nil : 100 + index * 15,
                model: index % 4 == 0 ? nil : index.isMultiple(of: 2) ? "example-fast" : "example-steady",
                reasoningEffort: index % 4 == 0 ? nil : index.isMultiple(of: 2) ? "high" : "low"))
            return CostUsageSessionBreakdown(
                sessionID: "synthetic-\(index)",
                lastActivity: Self.now,
                inputTokens: 100,
                cachedInputTokens: 0,
                outputTokens: 100,
                totalTokens: 200,
                requestCount: 1,
                costUSD: Double(index),
                modelBreakdowns: [],
                turnPerformanceSamples: [sample])
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 1,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 1,
            daily: [.init(
                date: "2026-05-10",
                inputTokens: 500,
                outputTokens: 500,
                totalTokens: 1000,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            sessions: sessions,
            updatedAt: Self.now)
        return SpendDashboardModel.build(
            inputs: [.init(provider: provider, displayName: "Example", snapshot: snapshot, sourceKind: kind)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar,
            hiddenSourceIDs: hiddenSourceIDs,
            selectedDay: selectedDay)
    }
}

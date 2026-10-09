import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutV5PersistenceTests {
    private static let spendLayout = MenuBarLayout(lines: [[
        .icon,
        .percent(window: .spend),
        .pace(window: .spend),
        .windowResetCountdown(window: .spend),
        .spendAmount,
        .spendBudget,
        .extraPercent(id: "cursor-grok-bot"),
        .windowResetCountdown(window: .weekly),
    ]])

    @Test
    func `V4 downgrade and reupgrade preserve bars while older edits win`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "progress-generation", userDefaults: defaults)
        let layout = MenuBarLayout(lines: [
            [.icon, .progressBar(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.progressBar(window: .weekly)],
        ])
        let projected = MenuBarLayout(lines: [
            [.icon, .percent(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.percent(window: .weekly)],
        ])
        var rule = MenuBarLayoutConditional.makeDefault()
        rule.thenToken = .progressBar(window: .scopedWeekly)
        settings.setMenuBarLayout(layout, for: nil)
        settings.setMenuBarLayout(layout, for: .codex)
        settings.setMenuBarLayout(layout, for: .claude)
        settings.menuBarLayoutConditionals = [rule]
        let decoder = JSONDecoder()
        let full = try #require(defaults.data(forKey: "menuBarLayoutV5"))
        let fullRules = try #require(defaults.data(forKey: "menuBarLayoutConditionalsV5"))
        // A frozen strict decoder rejects any discriminator unknown to the V4 app.
        let v4 = try #require(defaults.data(forKey: "menuBarLayoutV4"))
        let strict = try decoder.decode(V4Layout.self, from: v4)
        #expect(strict.lines == [
            [.icon, .percent(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.percent(window: .weekly)],
        ])
        let overrides = try decoder.decode([String: V4Layout].self, from: #require(
            defaults.data(forKey: "menuBarLayoutOverridesV4")))
        #expect(overrides["codex"] == strict)
        let strictRules = try decoder.decode([V4Rule].self, from: #require(
            defaults.data(forKey: "menuBarLayoutConditionalsV4")))
        #expect(strictRules.first?.thenToken == .percent(window: .scopedWeekly))

        // V4 startup/editor writes its four generations, leaving the unknown V5 keys untouched.
        var olderRule = rule
        olderRule.thenToken = .percent(window: .scopedWeekly)
        try self.saveV4(
            layout: projected,
            overrides: ["codex": projected, "claude": projected],
            rules: [olderRule],
            defaults: defaults)
        #expect(defaults.data(forKey: "menuBarLayoutV5") == full)
        #expect(defaults.data(forKey: "menuBarLayoutConditionalsV5") == fullRules)
        let returned = testSettingsStore(suiteName: "progress-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == layout)
        #expect(returned.menuBarLayoutOverrides[.codex] == layout)
        #expect(returned.menuBarLayoutConditionals == [rule])

        let edited = MenuBarLayout(lines: [[.usageBar]])
        olderRule.thenToken = .usageBar
        try self.saveV4(
            layout: edited,
            overrides: ["codex": edited, "claude": projected],
            rules: [olderRule],
            defaults: defaults)
        let editedReturn = testSettingsStore(suiteName: "progress-edited-return", userDefaults: defaults)
        #expect(editedReturn.menuBarLayout == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.codex] == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.claude] == layout)
        #expect(editedReturn.menuBarLayoutConditionals == [olderRule])
    }

    @Test
    func `historical separator projections do not discard existing window resets on upgrade`() throws {
        let defaults = InMemoryUserDefaults()
        let layout = MenuBarLayout(lines: [[.icon, .separatorDot, .windowResetCountdown(window: .session)]])
        let historical = MenuBarLayout(lines: [[.icon, .separatorDot]])
        for (key, value) in [
            ("menuBarLayoutV4", layout),
            ("menuBarLayoutV3", layout),
            ("menuBarLayoutV2", historical),
            ("menuBarLayout", historical),
        ] {
            try defaults.set(JSONEncoder().encode(value), forKey: key)
        }
        let returned = testSettingsStore(suiteName: "historical-separators", userDefaults: defaults)
        #expect(returned.menuBarLayout == layout)
    }

    @Test
    func `spend token discriminators stay stable and round trip`() throws {
        let fixtures: [(MenuBarLayoutToken, String)] = [
            (.percent(window: .spend), #"{"percent":{"window":"spend"}}"#),
            (.pace(window: .spend), #"{"pace":{"window":"spend"}}"#),
            (.windowResetCountdown(window: .spend), #"{"windowResetCountdown":{"window":"spend"}}"#),
            (.windowResetAbsolute(window: .spend), #"{"windowResetAbsolute":{"window":"spend"}}"#),
            (.spendAmount, #"{"spendAmount":{}}"#),
            (.spendBudget, #"{"spendBudget":{}}"#),
        ]
        for (token, json) in fixtures {
            #expect(try String(bytes: JSONEncoder().encode(token), encoding: .utf8) == json)
            #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(json.utf8)) == token)
        }
    }

    @Test
    func `V4 projection drops spend tokens but keeps named extras and reset windows`() throws {
        let decoder = JSONDecoder()
        let overrides = [
            "claude": Self.spendLayout,
            "cursor": MenuBarLayout(lines: [[.spendBudget, .windowResetAbsolute(window: .session)]]),
        ]
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(Self.spendLayout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)

        let kept = V4Layout(lines: [[
            .icon,
            .extraPercent(id: "cursor-grok-bot"),
            .windowResetCountdown(window: .weekly),
        ]])
        #expect(try decoder.decode(V4Layout.self, from: layoutBlobs.v4) == kept)
        let projected = try decoder.decode([String: V4Layout].self, from: overrideBlobs.v4)
        #expect(projected["claude"] == kept)
        #expect(projected["cursor"] == V4Layout(lines: [[.windowResetAbsolute(window: .session)]]))
        // V3 also loses the named extra, and the oldest generation loses every reset window.
        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.v3)
            == MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]]))
        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.released) == MenuBarLayout(lines: [[.icon]]))
        // The frozen decoder is strict: the current blob, with Spend tokens, would lose the whole layout.
        #expect(throws: DecodingError.self) {
            try decoder.decode(V4Layout.self, from: layoutBlobs.current)
        }
    }

    @Test
    func `a spend only layout projects to the default layout and returns intact`() throws {
        let spendOnly = MenuBarLayout(lines: [[.percent(window: .spend), .spendBudget]])
        let decoder = JSONDecoder()
        let blobs = try MenuBarLayoutPersistence.encoded(spendOnly)

        for blob in [blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode(MenuBarLayout.self, from: blob) == .defaultLayout)
        }
        #expect(try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: blobs.current),
            v4: decoder.decode(MenuBarLayout.self, from: blobs.v4),
            v3: decoder.decode(MenuBarLayout.self, from: blobs.v3),
            released: decoder.decode(MenuBarLayout.self, from: blobs.released),
            legacy: decoder.decode(MenuBarLayout.self, from: blobs.legacy)) == spendOnly)
    }

    @Test
    func `conditionals reading spend metrics are omitted from older libraries`() throws {
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendRules = [
            Self.rule(metric: .spend, thenToken: .providerName),
            Self.rule(metric: .spendResetsIn, thenToken: .providerName),
            Self.rule(metric: .spendPace, thenToken: .providerName),
            Self.rule(metric: .spendAmount, thenToken: .providerName),
            Self.rule(metric: .session, thenToken: .percent(window: .spend)),
            Self.rule(metric: .session, thenToken: .providerName, elseToken: .spendBudget),
        ]
        for rule in spendRules {
            #expect(!rule.hasV4Representation)
            #expect(rule.v3Compatible == nil)
            #expect(rule.releasedCompatible == nil)
            #expect(rule.legacyCompatible == nil)
        }

        let blobs = try MenuBarLayoutPersistence.encodedLibrary([readable] + spendRules)
        let decoder = JSONDecoder()
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.current).count == spendRules.count + 1)
        for blob in [blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode([V4Rule].self, from: blob).map(\.id) == [readable.id])
        }
    }

    @Test
    func `a spend layout survives a settings reload while V4 keeps only what 0.73.0 reads`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "spend-reload", userDefaults: defaults)
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendRule = Self.rule(metric: .spend, thenToken: .percent(window: .spend))
        let laterReadable = Self.rule(metric: .weekly, thenToken: .resetCountdown)
        settings.menuBarLayoutConditionals = [readable, spendRule, laterReadable]
        settings.setMenuBarLayout(Self.spendLayout, for: nil)
        settings.setMenuBarLayout(Self.spendLayout, for: .claude)

        let returned = testSettingsStore(suiteName: "spend-reload-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == Self.spendLayout)
        #expect(returned.menuBarLayoutOverrides[.claude] == Self.spendLayout)
        #expect(returned.menuBarLayoutConditionals == [readable, spendRule, laterReadable])

        let v4Rules = try JSONDecoder().decode(
            [V4Rule].self,
            from: #require(defaults.data(forKey: "menuBarLayoutConditionalsV4")))
        #expect(v4Rules.map(\.id) == [readable.id, laterReadable.id])
    }

    @Test
    func `a V4 library edit wins on return while spend rules survive it`() {
        let readable = Self.rule(metric: .session, thenToken: .windowResetCountdown(window: .weekly))
        let spendRule = Self.rule(metric: .spend, thenToken: .percent(window: .spend))
        let edited = MenuBarLayoutConditional(
            id: readable.id,
            name: "Edited in 0.73.0",
            clauses: readable.clauses,
            thenToken: .windowResetAbsolute(window: .session),
            elseToken: .hidden)

        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v4: [edited],
            v3: [edited],
            released: [],
            legacy: []) == [edited, spendRule])
        // Clearing the library in 0.73.0 deliberately clears the Spend rules too.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v4: [],
            v3: [],
            released: [],
            legacy: []) == [])
        // A V4-only install upgrading to V5 has no current library yet.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: nil,
            v4: [readable],
            v3: [readable],
            released: [],
            legacy: []) == [readable])
    }

    private func saveV4(
        layout: MenuBarLayout,
        overrides: [String: MenuBarLayout],
        rules: [MenuBarLayoutConditional],
        defaults: UserDefaults) throws
    {
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(layout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)
        let ruleBlobs = try MenuBarLayoutPersistence.encodedLibrary(rules)
        for (prefix, blobs) in [
            ("menuBarLayout", layoutBlobs),
            ("menuBarLayoutOverrides", overrideBlobs),
            ("menuBarLayoutConditionals", ruleBlobs),
        ] {
            defaults.set(blobs.current, forKey: prefix + "V4")
            defaults.set(blobs.v3, forKey: prefix + "V3")
            defaults.set(blobs.released, forKey: prefix + "V2")
            defaults.set(blobs.legacy, forKey: prefix)
        }
    }

    private static func rule(
        metric: MenuBarConditionalMetric,
        thenToken: MenuBarLayoutToken,
        elseToken: MenuBarLayoutToken = .hidden)
        -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: .greaterThan, threshold: 50))],
            thenToken: thenToken,
            elseToken: elseToken)
    }
}

/// Frozen 0.73.0 decoder surface: its windows and conditional metrics have no Spend cases, and a synthesized
/// `Codable` enum throws on an unknown case.
private enum V4Window: String, Codable {
    case session
    case weekly
    case scopedWeekly
    case automatic
}

private enum V4Token: Codable, Equatable {
    case icon
    case providerName
    case percent(window: V4Window)
    case usageBar
    case extraPercent(id: String)
    case resetCountdown
    case windowResetCountdown(window: V4Window)
    case windowResetAbsolute(window: V4Window)
    case hidden
}

private struct V4Layout: Decodable, Equatable {
    let lines: [[V4Token]]
}

private enum V4Metric: String, Decodable {
    case session, weekly, scopedWeekly, automatic, primaryLane, secondaryLane, tertiaryLane
    case sessionResetsIn, weeklyResetsIn, scopedWeeklyResetsIn, automaticResetsIn
    case sessionPace, weeklyPace, automaticPace, runsOutIn, balance, costToday, cost30d
}

private struct V4Rule: Decodable {
    struct Clause: Decodable {
        struct Predicate: Decodable {
            let metric: V4Metric
        }

        let predicate: Predicate
    }

    let id: UUID
    let clauses: [Clause]
    let thenToken: V4Token
    let elseToken: V4Token
}

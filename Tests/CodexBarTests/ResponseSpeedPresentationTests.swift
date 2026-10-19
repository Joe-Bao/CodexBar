import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ResponseSpeedPresentationTests {
    @Test
    func `menu bar uses recent response median and retires stale values`() {
        let model = Self.model()
        #expect(model.active != nil)
        #expect(model.statusTitle.contains("TPS"))
        model.now = model.now.addingTimeInterval(1900)
        #expect(model.active == nil)
        #expect(model.statusTitle == "TPS")
    }

    @Test
    func `menu bar speed label leaves room for the quota item`() {
        for rate in [nil, "9.9", "72.4", "999.9"] {
            let image = ResponseSpeedStatusImage.render(rate: rate)
            #expect(image.size.width <= 40)
            #expect(image.size.height == 22)
            #expect(image.isTemplate)
        }
    }

    @Test
    func `history window and short response filters do not change menu bar semantics`() {
        let model = Self.model()
        let title = model.statusTitle
        model.window = .minutes15
        model.includeShortResponses = true
        #expect(model.statusTitle == title)
        #expect(model.rows.count == 2)
    }

    @Test
    func `render menu popover with synthetic per response data`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SPEED_UI_PROOF_DIR"] else { return }
        let root = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        for rate in ["72.4", "999.9"] {
            let image = ResponseSpeedStatusImage.render(rate: rate)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("response-speed-status-\(rate).png"))
        }
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                try await CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                    try await self.render(
                        model: Self.model(),
                        dark: dark,
                        url: root.appendingPathComponent("response-speed-\(language)-\(dark).png"))
                }
            }
        }
        let empty = ResponseSpeedModel()
        empty.isIndexing = false
        try await self.render(
            model: empty,
            dark: false,
            url: root.appendingPathComponent("response-speed-empty.png"))
    }

    private static func model() -> ResponseSpeedModel {
        let model = ResponseSpeedModel()
        model.now = ResponseSpeedFixture.base.addingTimeInterval(20000)
        model.isIndexing = false
        model.samples = (0..<36).map { index in
            let source: ResponseSpeedSource = index.isMultiple(of: 2) ? .codex : .claude
            let speed = (source == .codex ? 65.0 : 42.0) + sin(Double(index)) * 12
            return ResponseSpeedSample(
                id: "response-\(index)",
                source: source,
                model: source == .codex ? "example-codex" : "example-claude",
                effort: source == .codex ? "high" : nil,
                tier: source == .codex ? "priority" : nil,
                completedAt: model.now.addingTimeInterval(Double(-index * 90)),
                duration: 1000 / speed,
                outputTokens: 1000)
        }
        return model
    }

    private func render(
        model: ResponseSpeedModel,
        dark: Bool,
        url: URL) async throws
    {
        let hosting = NSHostingView(rootView: ResponseSpeedPopover(model: model)
            .background(dark ? Color(
                red: 0.12,
                green: 0.12,
                blue: 0.12) : .white)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.frame = CGRect(
            origin: .zero,
            size: size)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap)
        try #require(bitmap.representation(
            using: .png,
            properties: [:])).write(to: url)
    }
}

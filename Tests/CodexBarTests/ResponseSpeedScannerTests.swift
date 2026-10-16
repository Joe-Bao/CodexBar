import Foundation
import Testing
@testable import CodexBarCore

struct ResponseSpeedScannerTests {
    @Test
    func `incremental reads preserve incomplete JSON lines without reusing tokens`() async throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let header = try ResponseSpeedFixture.jsonl(ResponseSpeedFixture.header())
        let usage = try ResponseSpeedFixture.usage(at: 10)
        try (header + usage.prefix(usage.count / 2)).write(to: file)
        let scanner = ResponseSpeedScanner(
            roots: [.init(
                url: root,
                source: .codex)],
            byteBudget: 100)
        var scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        for _ in 0..<20 where scan.isIndexing {
            scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        }
        #expect(scan.samples.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: usage.suffix(from: usage.count / 2) + Data([10]))
        try handle.close()
        for _ in 0..<20 {
            scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
            if !scan.isIndexing { break }
        }
        #expect(scan.samples.count == 1)
        #expect(scan.samples.first?.tokensPerSecond == 100)
        scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        #expect(scan.samples.count == 1)
    }

    @Test
    func `archived copies deduplicate and symlinks are ignored`() async throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try ResponseSpeedFixture.jsonl(ResponseSpeedFixture.header() + [ResponseSpeedFixture.usage(at: 10)])
        let original = root.appendingPathComponent("session.jsonl")
        try data.write(to: original)
        try data.write(to: root.appendingPathComponent("archive.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.jsonl"),
            withDestinationURL: original)
        let scanner = ResponseSpeedScanner(roots: [.init(
            url: root,
            source: .codex)])
        let now = ResponseSpeedFixture.base.addingTimeInterval(100)
        let scan = await scanner.scan(now: now)
        #expect(scan.samples.count == 2)
        let rows = ResponseSpeedSummary.rows(
            samples: scan.samples,
            now: now,
            window: 3600)
        #expect(rows.first?.samples.count == 1)
    }

    @Test
    func `file replacement and same inode larger rewrites discard old timing`() async throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let data = try ResponseSpeedFixture.jsonl(ResponseSpeedFixture.header() + [ResponseSpeedFixture.usage(at: 10)])
        try data.write(to: file)
        let scanner = ResponseSpeedScanner(roots: [.init(
            url: root,
            source: .codex)])
        let now = ResponseSpeedFixture.base.addingTimeInterval(100)
        #expect(await scanner.scan(now: now).samples.count == 1)
        let replacement = try ResponseSpeedFixture.jsonl(
            ResponseSpeedFixture.header() + [ResponseSpeedFixture.usage(
                at: 20,
                id: "replacement-long-id")])
        try replacement.write(to: file)
        let rewritten = await scanner.scan(now: now)
        #expect(rewritten.samples.count == 1)
        #expect(rewritten.samples.first?.tokensPerSecond == 50)
        try Data("{}\n".utf8).write(
            to: file,
            options: .atomic)
        #expect(await scanner.scan(now: now).samples.isEmpty)
    }

    @Test
    func `oversized and truncated records cannot bridge response timing`() async throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let data = try ResponseSpeedFixture.jsonl(ResponseSpeedFixture.header())
            + Data(
                repeating: 65,
                count: 2000) + Data([10])
            + (ResponseSpeedFixture.jsonl([ResponseSpeedFixture.usage(at: 10)]))
        try data.write(to: file)
        let scanner = ResponseSpeedScanner(
            roots: [.init(
                url: root,
                source: .codex)],
            byteBudget: 100,
            maximumLineBytes: 1000)
        var scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        for _ in 0..<40 where scan.isIndexing {
            scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        }
        #expect(!scan.isIndexing)
        #expect(scan.samples.isEmpty)
    }

    @Test
    func `memory ceiling remains bounded even when multiple files duplicate response ids`() async throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try ResponseSpeedFixture.jsonl(ResponseSpeedFixture.header() + [
            ResponseSpeedFixture.usage(at: 10), ResponseSpeedFixture.usage(at: 20, id: "second"),
        ])
        for index in 0..<3 {
            try data.write(to: root.appendingPathComponent("\(index).jsonl"))
        }
        let scanner = ResponseSpeedScanner(roots: [.init(url: root, source: .codex)], maximumSamples: 2)
        let scan = await scanner.scan(now: ResponseSpeedFixture.base.addingTimeInterval(100))
        #expect(scan.historyLimited)
        #expect(scan.samples.count == 2)
        #expect(scan.samples.allSatisfy { $0.id == "codex:second" })
    }

    @Test
    func `environment roots never require credentials or account configuration`() {
        let home = URL(fileURLWithPath: "/synthetic-home")
        let roots = ResponseSpeedScanner.localRoots(
            home: home,
            environment: [
                "CODEX_HOME": "/synthetic-codex",
                "CLAUDE_CONFIG_DIR": "/synthetic-claude",
            ])
        #expect(roots.map(\.url.path) == [
            "/synthetic-codex/sessions", "/synthetic-codex/archived_sessions", "/synthetic-claude/projects",
        ])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("response-speed-\(UUID())")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }
}

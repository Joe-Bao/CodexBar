import Foundation

public struct ResponseSpeedScan: Sendable {
    public let samples: [ResponseSpeedSample]
    public let isIndexing: Bool
    public let unreadableFiles: Int
    public let historyLimited: Bool
}

/// Incremental, read-only local log scanner. No networking, credentials, commands or disk cache.
public actor ResponseSpeedScanner {
    public struct Root: Sendable {
        public let url: URL
        public let source: ResponseSpeedSource

        public init(
            url: URL,
            source: ResponseSpeedSource)
        {
            self.url = url
            self.source = source
        }
    }

    private struct FileState {
        var parser: ResponseSpeedLogParser
        var identity: String
        var offset: UInt64 = 0
        var pending = Data()
        var discardingLine = false
        var modifiedAt = Date.distantPast
        var tail = Data()
        var samples: [String: ResponseSpeedSample] = [:]
    }

    private struct Entry {
        let url: URL
        let source: ResponseSpeedSource
        let modifiedAt: Date
    }

    private let roots: [Root]
    private let byteBudget: Int
    private let maximumLineBytes: Int
    private let maximumSamples: Int
    private var files: [URL: FileState] = [:]
    private var entries: [Entry] = []
    private var discoveredAt = Date.distantPast
    private var discoveryLimited = false
    private var sampleLimitReached = false
    private var discoveryErrors = 0

    public init(
        roots: [Root],
        byteBudget: Int = 16 * 1024 * 1024,
        maximumLineBytes: Int = 8 * 1024 * 1024,
        maximumSamples: Int = 30000)
    {
        self.roots = roots
        self.byteBudget = max(1, byteBudget)
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumSamples = max(1, maximumSamples)
    }

    public static func localRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [Root]
    {
        func directory(
            _ key: String,
            fallback: String) -> URL
        {
            guard let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return home.appendingPathComponent(
                    fallback,
                    isDirectory: true)
            }
            return URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath,
                isDirectory: true)
        }
        let codex = directory(
            "CODEX_HOME",
            fallback: ".codex")
        let claude = directory(
            "CLAUDE_CONFIG_DIR",
            fallback: ".claude")
        return [
            Root(
                url: codex.appendingPathComponent("sessions"),
                source: .codex),
            Root(
                url: codex.appendingPathComponent("archived_sessions"),
                source: .codex),
            Root(
                url: claude.appendingPathComponent("projects"),
                source: .claude),
        ]
    }

    public func scan(
        now: Date = Date(),
        rediscover: Bool = false) -> ResponseSpeedScan
    {
        let cutoff = now.addingTimeInterval(-ResponseSpeedSummary.retention)
        if rediscover || now.timeIntervalSince(self.discoveredAt) >= 15 {
            self.discover(
                now: now,
                cutoff: cutoff)
        }
        var remaining = self.byteBudget
        var isIndexing = false
        var errors = self.discoveryErrors
        for entry in self.entries {
            if Task.isCancelled { break }
            do {
                var url = entry.url
                url.removeAllCachedResourceValues()
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey, .fileResourceIdentifierKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, let modified = values.contentModificationDate,
                      modified >= cutoff
                else { continue }
                let identity = String(describing: values.fileResourceIdentifier)
                var state = self.files[entry.url] ?? FileState(
                    parser: .init(source: entry.source),
                    identity: identity)
                if state.identity != identity || UInt64(size) < state.offset
                    || (UInt64(size) == state.offset && modified != state.modifiedAt)
                {
                    state = FileState(
                        parser: .init(source: entry.source),
                        identity: identity)
                }
                if UInt64(size) > state.offset, remaining > 0 {
                    let handle = try FileHandle(forReadingFrom: entry.url)
                    defer { try? handle.close() }
                    if state.offset > 0, !state.tail.isEmpty {
                        try handle.seek(toOffset: state.offset - UInt64(state.tail.count))
                        if try handle.read(upToCount: state.tail.count) != state.tail {
                            state = FileState(
                                parser: .init(source: entry.source),
                                identity: identity)
                        }
                    }
                    try handle.seek(toOffset: state.offset)
                    while remaining > 0, state.offset < UInt64(size), !Task.isCancelled {
                        // Match this pass's stat snapshot even if the agent appends while we are reading.
                        let count = min(64 * 1024, remaining, size - Int(state.offset))
                        let data = try handle.read(upToCount: count) ?? Data()
                        guard !data.isEmpty else { break }
                        state.offset += UInt64(data.count)
                        state.tail = Data((state.tail + data).suffix(64))
                        remaining -= data.count
                        self.consume(
                            data,
                            state: &state,
                            cutoff: cutoff,
                            now: now)
                    }
                }
                isIndexing = isIndexing || state.offset < UInt64(size)
                state.modifiedAt = modified
                state.samples = state.samples.filter { $0.value.completedAt >= cutoff }
                self.files[entry.url] = state
            } catch {
                errors += 1
            }
        }
        self.trimSamples()
        return ResponseSpeedScan(
            samples: self.files.values.flatMap(\.samples.values),
            isIndexing: isIndexing,
            unreadableFiles: errors,
            historyLimited: self.discoveryLimited || self.sampleLimitReached)
    }

    private func consume(
        _ data: Data,
        state: inout FileState,
        cutoff: Date,
        now: Date)
    {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !state.discardingLine {
                if state.pending.count + end - cursor <= self.maximumLineBytes {
                    state.pending.append(contentsOf: data[cursor..<end])
                } else {
                    state.pending.removeAll(keepingCapacity: false)
                    state.discardingLine = true
                    state.parser.invalidateTiming()
                }
            }
            guard let newline else { break }
            if !state.discardingLine, !state.pending.isEmpty {
                for sample in state.parser.consume(state.pending)
                    where sample.completedAt >= cutoff && sample.completedAt <= now
                {
                    state.samples[sample.id] = sample
                }
            }
            state.pending.removeAll(keepingCapacity: true)
            state.discardingLine = false
            cursor = newline + 1
        }
    }

    private func discover(
        now: Date,
        cutoff: Date)
    {
        self.discoveredAt = now
        self.discoveryLimited = false
        self.discoveryErrors = 0
        var entries: [Entry] = []
        let manager = FileManager.default
        for root in self.roots {
            guard manager.fileExists(atPath: root.url.path) else { continue }
            guard let enumerator = manager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                self.discoveryErrors += 1
                continue
            }
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 50000 || Task.isCancelled {
                    self.discoveryLimited = true
                    break
                }
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, modified >= cutoff
                else { continue }
                entries.append(Entry(
                    url: url,
                    source: root.source,
                    modifiedAt: modified))
            }
        }
        entries.sort { $0.modifiedAt > $1.modifiedAt }
        if entries.count > 2000 { self.discoveryLimited = true }
        self.entries = Array(entries.prefix(2000))
        let retained = Set(self.entries.map(\.url))
        self.files = self.files.filter { retained.contains($0.key) }
    }

    private func trimSamples() {
        let samples = self.files.flatMap { url, state in state.samples.values.map { (url, $0) } }
        guard samples.count > self.maximumSamples else { return }
        self.sampleLimitReached = true
        var retained: [URL: Set<String>] = [:]
        for (url, sample) in samples.sorted(by: { $0.1.completedAt > $1.1.completedAt }).prefix(self.maximumSamples) {
            retained[url, default: []].insert(sample.id)
        }
        for url in Array(self.files.keys) {
            guard var state = self.files[url] else { continue }
            let ids = retained[url] ?? []
            state.samples = state.samples.filter { ids.contains($0.key) }
            self.files[url] = state
        }
    }
}

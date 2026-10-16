import Foundation
import Testing
@testable import CodexBarCore

struct ResponseSpeedParserTests {
    @Test
    func `single responses exclude parallel tool execution and do not double count reasoning`() throws {
        var parser = try ResponseSpeedFixture.codex()
        _ = try parser.consume(ResponseSpeedFixture.item(
            "function_call",
            at: 8,
            call: "a"))
        _ = try parser.consume(ResponseSpeedFixture.item(
            "custom_tool_call",
            at: 9,
            call: "b"))
        let first = try #require(parser.consume(ResponseSpeedFixture.usage(at: 10)).first)
        #expect(first.duration == 10)
        #expect(first.outputTokens == 1000)
        #expect(first.tokensPerSecond == 100)
        _ = try parser.consume(ResponseSpeedFixture.item(
            "function_call_output",
            at: 40,
            call: "a"))
        _ = try parser.consume(ResponseSpeedFixture.item(
            "custom_tool_call_output",
            at: 50,
            call: "b"))
        let second = try #require(parser.consume(ResponseSpeedFixture.usage(
            at: 60,
            id: "second")).first)
        #expect(second.duration == 10)
        #expect(second.tokensPerSecond == 100)
        #expect(second.effort == "high")
    }

    @Test
    func `continuation starts at previous response completion and mirrors do not advance timing`() throws {
        var parser = try ResponseSpeedFixture.codex()
        _ = try parser.consume(ResponseSpeedFixture.usage(at: 10))
        #expect(try parser.consume(ResponseSpeedFixture.usage(
            at: 12,
            thread: "foreign")).isEmpty)
        #expect(try parser.consume(ResponseSpeedFixture.usage(at: 13)).isEmpty)
        let next = try #require(parser.consume(ResponseSpeedFixture.usage(
            at: 20,
            id: "second")).first)
        #expect(next.duration == 10)
    }

    @Test
    func `pending parallel tools never become model time`() throws {
        var parser = try ResponseSpeedFixture.codex()
        _ = try parser.consume(ResponseSpeedFixture.item(
            "function_call",
            at: 8,
            call: "a"))
        _ = try parser.consume(ResponseSpeedFixture.item(
            "function_call",
            at: 9,
            call: "b"))
        _ = try parser.consume(ResponseSpeedFixture.usage(at: 10))
        _ = try parser.consume(ResponseSpeedFixture.item(
            "function_call_output",
            at: 40,
            call: "a"))
        #expect(try parser.consume(ResponseSpeedFixture.usage(
            at: 50,
            id: "second")).isEmpty)
    }

    @Test(arguments: ["turn_aborted", "task_complete"])
    func `terminal boundaries prevent idle time entering the next response`(terminal: String) throws {
        var parser = try ResponseSpeedFixture.codex()
        _ = try parser.consume(ResponseSpeedFixture.event(
            terminal,
            at: 5))
        #expect(try parser.consume(ResponseSpeedFixture.usage(at: 100)).isEmpty)
    }

    @Test
    func `compaction malformed lines and unmeasurable built in tools fail closed`() throws {
        for interruption in try [
            Data("invalid".utf8),
            ResponseSpeedFixture.line(
                "compacted",
                at: 2,
                payload: [:]),
            ResponseSpeedFixture.item(
                "web_search_call",
                at: 2),
        ] {
            var parser = try ResponseSpeedFixture.codex()
            _ = parser.consume(interruption)
            #expect(try parser.consume(ResponseSpeedFixture.usage(at: 10)).isEmpty)
        }
    }

    @Test
    func `usage requires response ownership and valid output counts`() throws {
        for output in [true, -1, 1.5, "1000", NSNull()] as [Any] {
            var parser = try ResponseSpeedFixture.codex()
            #expect(try parser.consume(ResponseSpeedFixture.usage(
                at: 10,
                tokens: output)).isEmpty)
        }
        var parser = ResponseSpeedLogParser(source: .codex)
        #expect(try parser.consume(ResponseSpeedFixture.usage(at: 10)).isEmpty)
        parser = try ResponseSpeedFixture.codex()
        #expect(try parser.consume(ResponseSpeedFixture.usage(at: 0)).isEmpty)
        #expect(try parser.consume(ResponseSpeedFixture.usage(
            at: 8000,
            id: "late")).isEmpty)
    }

    @Test
    func `subsecond response timestamps retain millisecond precision`() throws {
        var parser = try ResponseSpeedFixture.codex()
        let sample = try #require(parser.consume(ResponseSpeedFixture.usage(at: 0.25)).first)
        #expect(sample.duration == 0.25)
        #expect(sample.tokensPerSecond == 4000)
    }

    @Test
    func `model recorded on response overrides context and tiers remain distinct`() throws {
        var parser = try ResponseSpeedFixture.codex()
        _ = try parser.consume(ResponseSpeedFixture.line(
            "event_msg",
            at: 0,
            payload: [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": "priority"],
            ]))
        let sample = try #require(parser.consume(ResponseSpeedFixture.usage(
            at: 10,
            model: "example-actual")).first)
        #expect(sample.model == "example-actual")
        #expect(sample.tier == "priority")
    }

    @Test
    func `claude groups content blocks by message and excludes tool wait`() throws {
        var parser = ResponseSpeedLogParser(source: .claude)
        _ = try parser.consume(ResponseSpeedFixture.claude(
            type: "user",
            at: 0,
            uuid: "u1"))
        #expect(try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 5,
            id: "m1",
            parent: "u1",
            stop: "tool_use",
            block: "thinking")).isEmpty)
        _ = try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 10,
            id: "m1",
            stop: "tool_use",
            block: "tool_use"))
        let first = try #require(parser.consume(ResponseSpeedFixture.claude(
            type: "user",
            at: 50,
            uuid: "u2")).first)
        #expect(first.duration == 10)
        #expect(first.outputTokens == 1000)
        let second = try #require(parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 60,
            id: "m2",
            parent: "u2")).first)
        #expect(second.duration == 10)
    }

    @Test
    func `claude missing input and synthetic messages do not fabricate speed`() throws {
        var parser = ResponseSpeedLogParser(source: .claude)
        #expect(try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 10)).isEmpty)
        _ = try parser.consume(ResponseSpeedFixture.claude(
            type: "user",
            at: 20))
        #expect(try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 30,
            model: "<synthetic>")).isEmpty)
    }

    @Test
    func `claude assistant continuation starts at parent completion not parent prompt`() throws {
        var parser = ResponseSpeedLogParser(source: .claude)
        _ = try parser.consume(ResponseSpeedFixture.claude(
            type: "user",
            at: 0,
            uuid: "u1"))
        _ = try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 10,
            id: "m1",
            uuid: "a1",
            parent: "u1"))
        let samples = try parser.consume(ResponseSpeedFixture.claude(
            type: "assistant",
            at: 20,
            id: "m2",
            parent: "a1"))
        let sample = try #require(samples.last)
        #expect(sample.id == "claude:m2")
        #expect(sample.duration == 10)
    }
}

enum ResponseSpeedFixture {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func codex() throws -> ResponseSpeedLogParser {
        var parser = ResponseSpeedLogParser(source: .codex)
        for data in try self.header() {
            _ = parser.consume(data)
        }
        return parser
    }

    static func header() throws -> [Data] {
        try [
            self.line(
                "session_meta",
                at: 0,
                payload: ["id": "thread"]),
            self.event(
                "task_started",
                at: 0),
            self.line(
                "turn_context",
                at: 0,
                payload: [
                    "model": "example-model", "turn_id": "turn", "effort": "high",
                ]),
        ]
    }

    static func line(
        _ type: String,
        at seconds: Double,
        payload: [String: Any]) throws -> Data
    {
        try JSONSerialization.data(
            withJSONObject: [
                "type": type, "timestamp": self.timestamp(seconds), "payload": payload,
            ],
            options: [.sortedKeys])
    }

    static func event(
        _ type: String,
        at seconds: Double) throws -> Data
    {
        try self.line(
            "event_msg",
            at: seconds,
            payload: ["type": type, "turn_id": "turn"])
    }

    static func item(
        _ type: String,
        at seconds: Double,
        call: String = "a") throws -> Data
    {
        try self.line(
            "response_item",
            at: seconds,
            payload: ["type": type, "call_id": call])
    }

    static func usage(
        at seconds: Double,
        id: String = "response",
        thread: String = "thread",
        tokens: Any = 1000,
        model: String? = nil) throws -> Data
    {
        var payload: [String: Any] = [
            "thread_id": thread, "turn_id": "turn", "response_id": id,
            "usage": ["output_tokens": tokens, "reasoning_output_tokens": 100],
        ]
        payload["model"] = model
        return try self.line(
            "token_usage_record",
            at: seconds,
            payload: payload)
    }

    static func claude(
        type: String,
        at seconds: Double,
        id: String = "message",
        uuid: String = "uuid",
        parent: String = "",
        stop: String = "end_turn",
        block: String = "text",
        model: String = "example-claude") throws -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "type": type, "timestamp": self.timestamp(seconds), "uuid": uuid, "parentUuid": parent,
            "message": [
                "id": id, "model": model, "stop_reason": stop,
                "content": [["type": block]], "usage": ["output_tokens": 1000],
            ],
        ])
    }

    static func timestamp(_ seconds: Double) -> String {
        self.base.addingTimeInterval(seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func jsonl(_ lines: [Data]) -> Data {
        lines.reduce(into: Data()) { result, line in result.append(line); result.append(10) }
    }
}

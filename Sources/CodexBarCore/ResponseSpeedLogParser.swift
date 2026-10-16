import CoreFoundation
import Foundation

/// Per-file state for documented-by-observation JSONL boundaries. Unknown timing is omitted,
/// never replaced by turn duration or by a cumulative token-count delta.
struct ResponseSpeedLogParser: Sendable {
    let source: ResponseSpeedSource
    private var sessionID: String?
    private var turnID: String?
    private var model: String?
    private var effort: String?
    private var tier: String?
    private var start: Date?
    private var pendingTools: Set<String> = []
    private var unsupportedTool = false
    private var lastResponseID: String?
    private var claudePending: ResponseSpeedSample?
    private var claudeInputs: [String: Date] = [:]

    init(source: ResponseSpeedSource) { self.source = source }

    mutating func invalidateTiming() {
        self.start = nil
        self.pendingTools.removeAll()
        self.unsupportedTool = false
        self.claudePending = nil
        self.claudeInputs.removeAll()
    }

    mutating func consume(_ data: Data) -> [ResponseSpeedSample] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else {
            self.invalidateTiming()
            return []
        }
        let timestamp = (object["timestamp"] as? String).flatMap(Self.date)
        switch self.source {
        case .codex:
            return self.consumeCodex(
                type: type,
                object: object,
                timestamp: timestamp)
        case .claude:
            return self.consumeClaude(
                type: type,
                object: object,
                timestamp: timestamp)
        }
    }

    private mutating func consumeCodex(
        type: String,
        object: [String: Any],
        timestamp: Date?) -> [ResponseSpeedSample]
    {
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch type {
        case "session_meta":
            self.sessionID = payload["id"] as? String
        case "turn_context":
            self.model = Self.label(payload["model"])
            self.effort = Self.label(payload["effort"] ?? payload["reasoning_effort"])
            if let turn = payload["turn_id"] as? String { self.turnID = turn }
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                self.invalidateTiming()
                self.model = nil
                self.effort = nil
                self.turnID = payload["turn_id"] as? String
                self.start = timestamp
            case "task_complete", "turn_aborted": self.invalidateTiming()
            case "thread_settings_applied":
                let settings = payload["thread_settings"] as? [String: Any]
                self.tier = Self.label(settings?["service_tier"])
            default: break
            }
        case "response_item": self.consumeCodexItem(
                payload,
                timestamp: timestamp)
        case "token_usage_record": return self.codexSample(
                payload,
                timestamp: timestamp)
        case "compacted": self.invalidateTiming()
        default: break
        }
        return []
    }

    private mutating func consumeCodexItem(
        _ payload: [String: Any],
        timestamp: Date?)
    {
        let type = payload["type"] as? String ?? ""
        if type == "message", payload["role"] as? String == "user" {
            self.invalidateTiming()
            self.start = timestamp
        } else if ["function_call", "custom_tool_call", "local_shell_call"].contains(type) {
            if let id = payload["call_id"] as? String {
                self.pendingTools.insert(id)
            } else {
                self.unsupportedTool = true
            }
        } else if ["function_call_output", "custom_tool_call_output", "local_shell_call_output"].contains(type) {
            guard let id = payload["call_id"] as? String, self.pendingTools.remove(id) != nil else {
                self.start = nil
                return
            }
            // Parallel tool calls all have to finish before the next model response can begin.
            if self.pendingTools.isEmpty, !self.unsupportedTool { self.start = timestamp }
        } else if type.hasSuffix("_call") {
            // Built-in tools without an explicit completion boundary cannot be separated from inference.
            self.unsupportedTool = true
        }
    }

    private mutating func codexSample(
        _ payload: [String: Any],
        timestamp: Date?) -> [ResponseSpeedSample]
    {
        // Rows belonging to another thread can be mirrored into a rollout. They must not advance it.
        guard let sessionID = self.sessionID,
              payload["thread_id"] as? String == sessionID,
              (payload["turn_id"] as? String) == self.turnID,
              self.turnID != nil
        else { return [] }
        let responseID = Self.label(payload["response_id"])
        if let responseID, responseID == self.lastResponseID { return [] }
        self.lastResponseID = responseID
        defer { self.start = self.pendingTools.isEmpty && !self.unsupportedTool ? timestamp : nil }
        guard !self.unsupportedTool,
              let start, let timestamp,
              let responseID,
              let model = Self.label(payload["model"]) ?? self.model,
              let usage = payload["usage"] as? [String: Any],
              let tokens = Self.tokenCount(usage["output_tokens"]),
              let sample = Self.sample(
                  id: responseID,
                  key: .init(
                      source: .codex,
                      model: model,
                      effort: self.effort,
                      tier: self.tier),
                  start: start,
                  end: timestamp,
                  tokens: tokens)
        else { return [] }
        // reasoning_output_tokens is a subset of output_tokens; do not add it twice.
        return [sample]
    }

    private mutating func consumeClaude(
        type: String,
        object: [String: Any],
        timestamp: Date?) -> [ResponseSpeedSample]
    {
        guard type == "user" || type == "assistant" else { return [] }
        guard let timestamp else {
            self.invalidateTiming()
            return []
        }
        var completed: [ResponseSpeedSample] = []
        let message = object["message"] as? [String: Any] ?? [:]
        if type == "user" {
            if let pending = self.claudePending { completed.append(pending) }
            self.claudePending = nil
            self.start = timestamp
        } else if let id = Self.label(message["id"]),
                  let model = Self.label(message["model"]), model != "<synthetic>",
                  let usage = message["usage"] as? [String: Any],
                  let tokens = Self.tokenCount(usage["output_tokens"])
        {
            let sampleID = "claude:\(id)"
            if let pending = self.claudePending, pending.id != sampleID {
                completed.append(pending)
                self.start = pending.completedAt
                self.claudePending = nil
            }
            let parent = (object["parentUuid"] as? String).flatMap { self.claudeInputs[$0] }
            let start = self.claudePending.map { $0.completedAt.addingTimeInterval(-$0.duration) }
                ?? parent ?? self.start
            if let start, let sample = Self.sample(
                id: id,
                key: .init(
                    source: .claude,
                    model: model,
                    effort: Self.label(object["effort"] ?? object["perTurnEffort"]),
                    tier: Self.label(usage["speed"])),
                start: start,
                end: timestamp,
                tokens: tokens)
            {
                self.start = start
                self.claudePending = sample
                // Claude repeats usage on content blocks. Upsert the same ID, with the last block's time.
                let content = message["content"] as? [[String: Any]] ?? []
                if message["stop_reason"] as? String == "end_turn",
                   content.contains(where: { $0["type"] as? String == "text" })
                {
                    completed.append(sample)
                }
            }
        }
        if let uuid = object["uuid"] as? String {
            if self.claudeInputs.count >= 512 { self.claudeInputs.removeAll() }
            self.claudeInputs[uuid] = timestamp
        }
        return completed
    }

    private static func sample(
        id: String,
        key: ResponseSpeedModelKey,
        start: Date,
        end: Date,
        tokens: Int) -> ResponseSpeedSample?
    {
        let duration = end.timeIntervalSince(start)
        guard duration > 0, duration <= 7200, duration.isFinite, tokens > 0 else { return nil }
        return ResponseSpeedSample(
            id: id,
            source: key.source,
            model: key.model,
            effort: key.effort,
            tier: key.tier,
            completedAt: end,
            duration: duration,
            outputTokens: tokens)
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int.max),
              value.doubleValue.rounded(.towardZero) == value.doubleValue
        else { return nil }
        return value.intValue
    }

    private static func label(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 200 else { return nil }
        return value
    }

    private static func date(_ value: String) -> Date? {
        (try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(
                value,
                strategy: .iso8601))
    }
}

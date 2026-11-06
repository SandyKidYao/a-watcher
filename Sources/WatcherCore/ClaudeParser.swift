import Foundation

/// Reads usage and lifecycle evidence only. No account credentials or quota API.
public struct ClaudeParser: Sendable {
    public var state: ParserState
    private let fileID: String
    public init(state: ParserState = ParserState(), fileID: String = "unknown") {
        self.state = state; self.fileID = fileID; self.state.session.provider = .claude
    }
    public mutating func consume(_ line: Data, offset: UInt64) -> [UsageRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = root["type"] as? String else { state.malformed += 1; return [] }
        let message = root["message"] as? [String: Any] ?? [:]
        let time = parseTimestamp(root["timestamp"] as? String)
        let parent = root["sessionId"] as? String ?? fileID
        let agent = root["agentId"] as? String ?? (fileID.hasPrefix("agent-") ? fileID : nil)
        if root["sessionId"] is String || state.session.id.isEmpty { state.session.id = agent.map { parent + ":agent:" + $0 } ?? parent }
        if let cwd = root["cwd"] as? String {
            state.session.observeDirectory(cwd, at: time)
        }
        if let model = message["model"] as? String { state.session.model = String(model.prefix(256)) }
        if let time, time >= state.session.observedAt {
            // Bookkeeping records (titles, last-prompt, history snapshots) must
            // not revive a completed turn. A tool result continues the same turn.
            if type == "user" { state.session.status = .running; state.session.tool = nil; state.session.observedAt = time }
            if type == "assistant" {
                let blocks = message["content"] as? [[String: Any]] ?? []
                let tool = blocks.last { $0["type"] as? String == "tool_use" }?["name"] as? String
                let stop = message["stop_reason"] as? String
                if root["isApiErrorMessage"] as? Bool == true { state.session.status = .error }
                else if tool == "AskUserQuestion" { state.session.status = .waitingInput }
                else if stop == "tool_use" || tool != nil { state.session.status = .tool }
                else if ["end_turn", "stop_sequence"].contains(stop ?? "") { state.session.status = .idle }
                else if ["max_tokens", "refusal"].contains(stop ?? "") { state.session.status = .unknown }
                else { state.session.status = .running }
                state.session.tool = tool.map { String($0.prefix(128)) }; state.session.observedAt = time
            }
        }
        guard type == "assistant", let usage = message["usage"] as? [String: Any] else { return [] }
        guard let input = integer(usage["input_tokens"]), let output = integer(usage["output_tokens"]), let time else { state.malformed += 1; return [] }
        let read = integer(usage["cache_read_input_tokens"]) ?? 0, write = integer(usage["cache_creation_input_tokens"]) ?? 0
        let (subtotal, overflow1) = input.addingReportingOverflow(read)
        let (totalInput, overflow2) = subtotal.addingReportingOverflow(write)
        guard !overflow1, !overflow2, !totalInput.addingReportingOverflow(output).overflow else { state.malformed += 1; return [] }
        let id = message["id"] as? String
        let request = root["requestId"] as? String ?? ""
        // Anthropic message IDs identify a response across streaming chunks and
        // copied sidechain history, even if the copied request ID was rewritten.
        let identity: String
        if let id, id.hasPrefix("msg_") { identity = id }
        else if let id { identity = state.session.id + "|" + id + "|" + request }
        else { identity = state.session.id + "|offset:\(offset)"; state.malformed += 1 }
        state.ordinal += 1
        var record = UsageRecord(key: "claude:" + stableHash(identity), sessionID: state.session.id, ordinal: state.ordinal,
            timestamp: time, model: state.session.model, tier: usage["speed"] as? String ?? "unknown",
            tokens: TokenUsage(input: totalInput, cached: read, cacheWrite: write, output: output))
        record.finalized = message["stop_reason"] is String
        return [record]
    }
}

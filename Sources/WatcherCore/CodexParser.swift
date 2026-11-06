import Foundation

public struct ParserState: Codable, Sendable {
    public var session = SessionRecord()
    public var previous: TokenUsage?
    public var ordinal: Int64 = 0
    public var tier = "unknown"
    public var malformed = 0
    public var pending: [String: PendingCompaction] = [:]
    public var compacted: Set<String> = []
    public var accounted: Set<String> = []
    public var latestResponse: String?
    public init() {}
}
public struct PendingCompaction: Codable, Sendable {
    var record: UsageRecord
    var total: TokenUsage?
}

public struct CodexParser: Sendable {
    public var state: ParserState
    public init(state: ParserState = ParserState()) { self.state = state }

    public mutating func consume(_ line: Data, offset: UInt64) -> [UsageRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = root["type"] as? String else {
            state.malformed += 1; return []
        }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let time = parseTimestamp(root["timestamp"] as? String)
        if type == "session_meta" {
            if let id = payload["id"] as? String { state.session.id = String(id.prefix(256)) }
            if let cwd = payload["cwd"] as? String {
                state.session.observeDirectory(cwd, at: time)
            }
            state.session.parentID = payload["forked_from_id"] as? String
            if let source = payload["source"] as? [String: Any], let subagent = source["subagent"] as? [String: Any], let spawn = subagent["thread_spawn"] as? [String: Any] {
                state.session.parentID = spawn["parent_thread_id"] as? String
            }
            if state.session.parentID == state.session.id { state.session.parentID = nil; state.malformed += 1 }
            return []
        }
        if type == "turn_context" {
            if let cwd = payload["cwd"] as? String { state.session.observeDirectory(cwd, at: time) }
            if let model = payload["model"] as? String { state.session.model = String(model.prefix(256)) }
            return []
        }
        if type == "response_item", payload["type"] as? String == "function_call" || payload["type"] as? String == "custom_tool_call" {
            observe(.tool, at: time)
            state.session.tool = (payload["name"] as? String).map { String($0.prefix(128)) }
            return []
        }
        if type == "compacted", let id = payload["compaction_response_id"] as? String {
            state.compacted.insert(id)
            if let pending = state.pending[id], !state.accounted.contains(id) {
                state.accounted.insert(id); return [pending.record]
            }
            trimCompactions(); return []
        }
        if type == "token_usage_record", let id = payload["response_id"] as? String,
           !state.accounted.contains(id), let tokens = TokenUsage.read(payload["usage"] as? [String: Any]), let time {
            let candidate = makeRecord(key: "response:\(id)", tokens: tokens, time: time, compaction: true, model: payload["model"] as? String)
            state.latestResponse = id
            state.pending[id] = PendingCompaction(record: candidate, total: TokenUsage.read(payload["thread_token_usage"] as? [String: Any]))
            if state.compacted.contains(id) { state.accounted.insert(id); return [candidate] }
            trimCompactions(); return []
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return [] }
        switch event {
        case "task_started": observe(.running, at: time)
        case "task_complete": observe(.idle, at: time); state.session.tool = nil
        case "turn_aborted": observe(.interrupted, at: time)
        case "thread_settings_applied":
            if let settings = payload["thread_settings"] as? [String: Any], let tier = settings["service_tier"] as? String {
                state.tier = ["default", "standard"].contains(tier) ? "standard" : ["fast", "priority"].contains(tier) ? "fast" : ["flex", "ultrafast"].contains(tier) ? tier : "unknown"
            }
        default: break
        }
        guard event == "token_count", let info = payload["info"] as? [String: Any] else { return [] }
        let total = TokenUsage.read(info["total_token_usage"] as? [String: Any])
        let last = TokenUsage.read(info["last_token_usage"] as? [String: Any])
        let advanced = total == nil || total != state.previous
        let delta: TokenUsage?
        if advanced, let last { delta = last }
        else if let total { delta = state.previous.map { total.delta(from: $0) } ?? total }
        else { delta = nil }
        if let total { state.previous = total }
        guard let delta, delta.total > 0 else { return [] }
        guard let time, !state.session.id.isEmpty else { state.malformed += 1; return [] }
        var corrections: [UsageRecord] = []
        if let id = state.latestResponse, let pending = state.pending[id], advanced,
           pending.record.tokens == delta || (total != nil && pending.total == total) {
            if state.accounted.contains(id) {
                var removal = pending.record; removal.removal = true; corrections.append(removal)
            }
            state.pending.removeValue(forKey: id); state.accounted.insert(id)
        }
        // Snapshot identity also deduplicates an active/archive copy of a rollout.
        // Identical requests with no cumulative identity stay offset-scoped and
        // explicitly reduce coverage rather than silently guessing equivalence.
        let identity: String
        if let total { identity = "\(time.timeIntervalSince1970)|\(total.fingerprint)" }
        else { identity = "offset:\(offset)"; state.malformed += 1 }
        if let model = payload["model"] as? String ?? info["model"] as? String { state.session.model = String(model.prefix(256)) }
        state.session.observedAt = max(state.session.observedAt, time)
        return corrections + [makeRecord(key: "usage:\(state.session.id):\(stableHash(identity))", tokens: delta, time: time)]
    }

    private mutating func observe(_ status: SessionStatus, at time: Date?) {
        guard let time, time >= state.session.observedAt else { return }
        state.session.status = status; state.session.observedAt = time
    }
    private mutating func makeRecord(key: String, tokens: TokenUsage, time: Date, compaction: Bool = false, model: String? = nil) -> UsageRecord {
        state.ordinal += 1
        return UsageRecord(key: key, sessionID: state.session.id, ordinal: state.ordinal, timestamp: time,
                           model: model ?? state.session.model, tier: state.tier, tokens: tokens, compaction: compaction)
    }
    private mutating func trimCompactions() {
        if state.pending.count > 64 {
            let oldest = state.pending.min { $0.value.record.ordinal < $1.value.record.ordinal }!.key
            state.pending.removeValue(forKey: oldest); state.malformed += 1
        }
        if state.compacted.count > 512 || state.accounted.count > 512 {
            // Persisted records retain response identity. Keep parser state bounded.
            state.compacted.removeAll(); state.accounted.removeAll()
        }
    }
}

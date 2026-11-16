import Foundation

struct PiParser: SessionParser {
    var state: ParserState
    mutating func consume(_ line: Data, offset: UInt64) -> [UsageRecord] {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = entry["type"] as? String else { state.malformed += 1; return [] }
        let date = parseTimestamp(entry["timestamp"] as? String)
        state.session.provider = .pi
        if type == "session" {
            guard let id = entry["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  [2, 3].contains(integer(entry["version"]) ?? 0) else { state.malformed += 1; state.session.id = ""; return [] }
            state.session.id = id
            state.session.project = "Pi"
            if let directory = entry["cwd"] as? String { state.session.observeDirectory(directory, at: date) }
            state.session.parentID = (entry["parentSession"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        }
        // Only the extension supplies live evidence; transcript history stays unknown.
        guard !state.session.id.isEmpty else { return [] }
        if let date { state.session.observedAt = max(date, state.session.observedAt) }
        let message = entry["message"] as? [String: Any]
        let body: [String: Any]
        switch type {
        case "usage": body = entry
        case "compaction", "branch_summary":
            guard entry["usage"] != nil else { return [] }
            body = entry
        case "message":
            guard let message, let role = message["role"] as? String,
                  role == "assistant" || (role == "toolResult" && message["usage"] != nil) else { return [] }
            body = message
        default: return []
        }
        guard let usage = body["usage"] as? [String: Any], let output = integer(usage["output"]),
              let input = integer(usage["input"]), let read = integer(usage["cacheRead"]), let write = integer(usage["cacheWrite"]),
              let id = entry["id"] as? String, !id.isEmpty, let date else { state.malformed += 1; return [] }
        let (subtotal, firstOverflow) = input.addingReportingOverflow(read)
        let (combined, secondOverflow) = subtotal.addingReportingOverflow(write)
        let (total, thirdOverflow) = combined.addingReportingOverflow(output)
        guard !firstOverflow, !secondOverflow, !thirdOverflow, usage["totalTokens"] == nil || integer(usage["totalTokens"]) == total else { state.malformed += 1; return [] }
        let model = String((body["model"] as? String ?? "unknown").prefix(256))
        if model != "unknown" { state.session.model = model }
        state.ordinal += 1
        let key = stableHash(id) + ":" + stableHash(state.session.id)
        return [UsageRecord(key: key, sessionID: state.session.id, ordinal: state.ordinal, timestamp: date, model: model, tier: "unknown",
            tokens: TokenUsage(input: combined, cached: read, cacheWrite: write, output: output, reasoning: integer(usage["reasoning"]) ?? 0))]
    }
}

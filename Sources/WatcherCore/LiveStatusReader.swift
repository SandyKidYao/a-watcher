import Foundation

/// File-event status observation, independent of the hourly usage ledger.
/// Reads only bounded header/tail data from changed transcripts, no DB writes.
public actor LiveStatusReader {
    private let root: URL
    private let provider: AgentProvider
    private var sessions: [String: SessionRecord] = [:]
    public init(root: URL, provider: AgentProvider) { self.root = root.resolvingSymlinksInPath(); self.provider = provider }
    public func seed(_ values: [String: SessionRecord]) { for (path, value) in values { if sessions[path] == nil || sessions[path]!.observedAt <= value.observedAt { sessions[path] = value } } }
    public func update(paths: [String], now: Date = Date()) -> [SessionRecord] {
        for path in Set(paths).prefix(32) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), url.pathExtension == "jsonl" else { continue }
            autoreleasepool {
                guard let file = try? FileHandle(forReadingFrom: url), let size = try? file.seekToEnd() else { return }
                defer { try? file.close() }
                var state = ParserState()
                state.session = sessions[path] ?? SessionRecord(id: url.deletingPathExtension().lastPathComponent, project: provider.name)
                state.session.provider = provider
                if state.session.projectDirectory == nil {
                    state.session = SessionProject.restoring(state.session, from: url, provider: provider)
                }
                var codex = CodexParser(state: state), claude = ClaudeParser(state: state, fileID: url.deletingPathExtension().lastPathComponent)
                func consume(_ data: Data, discardFirst: Bool) {
                    var start = data.startIndex
                    if discardFirst { guard let newline = data.firstIndex(of: 10) else { return }; start = newline + 1 }
                    while start < data.endIndex, let newline = data[start...].firstIndex(of: 10) {
                        let line = data.subdata(in: start..<newline)
                        if provider == .codex { _ = codex.consume(line, offset: 0) } else { _ = claude.consume(line, offset: 0) }
                        start = newline + 1
                    }
                }
                if sessions[path] == nil {
                    try? file.seek(toOffset: 0)
                    if let head = try? file.read(upToCount: 2 * 1024 * 1024) { consume(head, discardFirst: false) }
                }
                let offset = size > 65536 ? size - 65536 : 0
                try? file.seek(toOffset: offset)
                if let tail = try? file.read(upToCount: 65536) { consume(tail, discardFirst: offset > 0) }
                sessions[path] = provider == .codex ? codex.state.session : claude.state.session
            }
        }
        var unique: [String: SessionRecord] = [:]
        for session in sessions.values where session.observedAt > now.addingTimeInterval(-86400) {
            if unique[session.key] == nil || unique[session.key]!.observedAt < session.observedAt { unique[session.key] = session }
        }
        return Array(unique.values)
    }
}

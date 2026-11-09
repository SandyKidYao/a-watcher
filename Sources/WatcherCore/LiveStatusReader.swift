import Foundation

public struct LiveStatusSeed: Sendable {
    public var session: SessionRecord
    public var cursor: ReadCursor
    public var identity: String
    public init(session: SessionRecord, cursor: ReadCursor, identity: String) {
        self.session = session; self.cursor = cursor; self.identity = identity
    }
}

/// File-event observations are independent of the usage ledger. Persist only
/// metadata in memory: no transcript text, token records, or credentials.
public actor LiveStatusReader {
    private let root: URL
    private let provider: AgentProvider
    private var sessions: [String: SessionRecord] = [:]
    private var cursors: [String: ReadCursor] = [:]
    private var identities: [String: String] = [:]
    private var queued: Set<String> = []
    public var hasPendingUpdates: Bool { !queued.isEmpty }
    public init(root: URL, provider: AgentProvider) { self.root = root.resolvingSymlinksInPath(); self.provider = provider }
    public func seed(_ values: [String: SessionRecord]) {
        for (path, value) in values {
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if sessions[key] == nil || sessions[key]!.observedAt < value.observedAt { sessions[key] = value }
        }
    }
    public func seedSources(_ values: [String: LiveStatusSeed]) {
        for (path, value) in values {
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            // An older accounting scan must never rewind a live cursor/state.
            if let current = cursors[key], identities[key] == value.identity,
               current.offset > value.cursor.offset || (current.offset == value.cursor.offset && sessions[key]?.status != .unknown) { continue }
            if let session = sessions[key], session.observedAt > value.session.observedAt { continue }
            sessions[key] = value.session; cursors[key] = value.cursor; identities[key] = value.identity
        }
    }
    public func update(paths: [String], now: Date = Date()) -> [SessionRecord] {
        for path in Set(paths) { enqueue(path, now: now) }
        // Bound each actor turn; callers drain the backlog without waiting for
        // another filesystem event. A coalesced burst cannot silently lose files.
        var remaining = 4 * 1024 * 1024
        for path in queued.sorted().prefix(16) {
            guard remaining > 0 else { break }
            queued.remove(path)
            let url = URL(fileURLWithPath: path)
            autoreleasepool {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                    sessions.removeValue(forKey: path); cursors.removeValue(forKey: path); identities.removeValue(forKey: path)
                    return
                }
                let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
                if let old = identities[path], old != identity || size < (cursors[path]?.offset ?? 0) {
                    sessions.removeValue(forKey: path); cursors.removeValue(forKey: path)
                }
                var state = ParserState()
                state.session = sessions[path] ?? SessionRecord(id: url.deletingPathExtension().lastPathComponent, project: provider.name)
                state.session.provider = provider
                var codex = CodexParser(state: state), claude = ClaudeParser(state: state, fileID: url.deletingPathExtension().lastPathComponent)
                func consume(_ line: Data, _ offset: UInt64) {
                    if provider == .codex { _ = codex.consume(line, offset: offset) } else { _ = claude.consume(line, offset: offset) }
                }
                var cursor = cursors[path] ?? ReadCursor()
                if cursors[path] == nil, size > 2 * 1024 * 1024 {
                    guard remaining >= 4 * 1024 * 1024 else { queued.insert(path); return }
                    // Bootstrap only: recover metadata from a bounded header,
                    // then recent evidence. An unobserved gap stays unknown.
                    if let header = try? LineReader.read(url, cursor: ReadCursor(), byteBudget: 2 * 1024 * 1024, consume: consume) { remaining -= header.bytesRead }
                    codex.state.session.status = .unknown; claude.state.session.status = .unknown
                    cursor = ReadCursor(offset: size - 2 * 1024 * 1024, dropping: true)
                }
                let budget = min(remaining, 2 * 1024 * 1024)
                guard let result = try? LineReader.read(url, cursor: cursor, byteBudget: budget, lineLimit: 1024 * 1024, consume: consume) else { return }
                remaining -= result.bytesRead
                sessions[path] = provider == .codex ? codex.state.session : claude.state.session
                // Missing oversized records must not preserve a false working
                // or completed state. Later evidence/accounting may refine it.
                if result.skipped > 0 { sessions[path]?.status = .unknown }
                cursors[path] = result.cursor; identities[path] = identity
                if result.bytesRead == budget, result.cursor.offset < size { queued.insert(path) }
            }
        }
        return SessionRecord.latest(Array(sessions.values), now: now)
    }
    private func enqueue(_ path: String, now: Date) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let bases = (provider == .codex ? ["sessions", "archived_sessions"] : ["projects"]).map { root.appendingPathComponent($0) }
        guard url.path == root.path || bases.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else { return }
        if url.pathExtension == "jsonl" { queued.insert(url.path); return }
        // Directory/drop/root events trigger metadata discovery, never a usage
        // reindex. Do not traverse unrelated Codex plugins, caches or auth files.
        for base in bases where url.path == root.path || base.path == url.path || base.path.hasPrefix(url.path + "/") || url.path.hasPrefix(base.path + "/") {
            let directory = url.path.hasPrefix(base.path + "/") ? url : base
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let candidate as URL in enumerator {
                guard let metadata = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) else { continue }
                if metadata.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard candidate.pathExtension == "jsonl" else { continue }
                let canonical = candidate.resolvingSymlinksInPath().path
                if sessions[canonical] != nil || (metadata.contentModificationDate ?? .distantPast) > now.addingTimeInterval(-86400) { queued.insert(canonical) }
            }
        }
    }
}

extension SessionRecord {
    /// Merge asynchronous usage snapshots and live observations by identity;
    /// accounting progress cannot temporarily hide a freshly observed session.
    public static func latest(_ records: [SessionRecord], now: Date = Date()) -> [SessionRecord] {
        var unique: [String: SessionRecord] = [:]
        for session in records where session.observedAt > now.addingTimeInterval(-86400) {
            if unique[session.key] == nil || unique[session.key]!.observedAt <= session.observedAt { unique[session.key] = session }
        }
        return unique.values.sorted { $0.observedAt > $1.observedAt }
    }
}

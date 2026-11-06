import Foundation

public actor CodexIndex {
    public let root: URL
    public let provider: AgentProvider
    private let store: SQLiteStore
    private var files: [String: IndexedFile]
    private var knownURLs: [URL] = []
    private var compressedCount = 0
    private var invalidated = true
    public init(root: URL, database: URL, provider: AgentProvider = .codex) throws {
        self.provider = provider
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        let db = try SQLiteStore(url: database)
        self.store = db; self.files = try db.loadFiles()
        let canonicalRoot = self.root
        let sourceRoots = (provider == .codex ? ["sessions", "archived_sessions"] : ["projects"]).map { canonicalRoot.appendingPathComponent($0).path + "/" }
        var repaired: [IndexedFile] = []
        for (path, var file) in files where file.parser.session.projectDirectory == nil {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.pathExtension == "jsonl", sourceRoots.contains(where: { url.path.hasPrefix($0) }) else { continue }
            let session = SessionProject.restoring(file.parser.session, from: url, provider: provider)
            if session != file.parser.session {
                file.parser.session = session; files[path] = file; repaired.append(file)
            }
        }
        if !repaired.isEmpty {
            try db.begin()
            do { for file in repaired { try db.save(file) }; try db.commit() }
            catch { db.rollback(); throw error }
        }
    }
    public func invalidate() { invalidated = true }
    public func history(year: Int, calendar: Calendar = .current, now: Date = Date()) throws -> UsageHistory {
        try Task.checkCancellation()
        guard (1900...9998).contains(year), let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return UsageHistory() }
        var result = try store.history(from: start, until: min(end, now.addingTimeInterval(1)), calendar: calendar)
        result.isPartial = result.isPartial || knownURLs.isEmpty || compressedCount > 0 || files.values.contains {
            !$0.complete || $0.skipped > 0 || $0.parser.malformed > 0 || $0.cursor.dropping
        }
        // Unresolved inherited history is excluded from the ledger; propagate
        // that coverage caveat even when the selected year has no counted rows.
        if try store.hasUnresolvedForks() { result.isPartial = true }
        return result
    }
    public func sessionMap() -> [String: SessionRecord] {
        Dictionary(uniqueKeysWithValues: knownURLs.compactMap { url in
            guard let session = files[url.path]?.parser.session, !session.id.isEmpty else { return nil }
            return (url.path, session)
        })
    }
    public func scanStep(days: Int = 1, calendar: Calendar = .current, now: Date = Date()) throws -> IndexSnapshot {
        if invalidated || knownURLs.isEmpty { discover(); invalidated = false }
        var budget = 4 * 1024 * 1024
        for url in knownURLs {
            guard budget > 0 else { break }
            try autoreleasepool {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
                let old = files[url.path]
                let reset = old == nil || old?.identity != identity || size < (old?.cursor.offset ?? 0) || (old?.complete == true && old?.size == size && old?.modified != modified)
                if !reset, let old, old.complete, old.size == size, old.modified == modified { return }
                var parser = CodexParser(state: reset ? ParserState() : old!.parser)
                var claude = ClaudeParser(state: reset ? ParserState() : old!.parser, fileID: url.deletingPathExtension().lastPathComponent)
                let cursor = reset ? ReadCursor() : old!.cursor
                try store.begin()
                do {
                    if reset { try store.resetFile(url.path) }
                    let result = try LineReader.read(url, cursor: cursor, byteBudget: budget) { line, offset in
                        let records = provider == .codex ? parser.consume(line, offset: offset) : claude.consume(line, offset: offset)
                        for record in records { try store.insert(record, path: url.path, fork: provider == .codex && parser.state.session.parentID != nil) }
                    }
                    budget -= result.bytesRead
                    let entry = IndexedFile(path: url.path, identity: identity, size: size, modified: modified, cursor: result.cursor,
                                            parser: provider == .codex ? parser.state : claude.state, skipped: (reset ? 0 : old!.skipped) + result.skipped,
                                            complete: result.cursor.offset >= size || result.bytesRead == 0 || result.bytesRead < max(1, budget + result.bytesRead))
                    try store.save(entry); try store.commit(); files[url.path] = entry
                } catch { store.rollback(); throw error }
            }
        }
        if provider == .codex { try store.reconcileForks(files: files) }
        return try snapshot(days: days, calendar: calendar, now: now)
    }
    public func snapshot(days: Int = 1, calendar: Calendar = .current, now: Date = Date()) throws -> IndexSnapshot {
        let start = calendar.date(byAdding: .day, value: 1 - max(1, days), to: calendar.startOfDay(for: now))!
        var snapshot = IndexSnapshot()
        snapshot.usage = try store.summary(since: start, until: now.addingTimeInterval(1))
        snapshot.usage.filesTotal = knownURLs.count
        snapshot.usage.filesDone = knownURLs.filter { files[$0.path]?.complete == true }.count
        snapshot.usage.indexing = snapshot.usage.filesDone < snapshot.usage.filesTotal
        snapshot.usage.skippedLines = files.values.reduce(0) { $0 + $1.skipped + $1.parser.malformed + ($1.cursor.dropping ? 1 : 0) }
        snapshot.usage.compressedFiles = compressedCount
        var sessions: [String: SessionRecord] = [:]
        for url in knownURLs {
            guard let file = files[url.path], !file.parser.session.id.isEmpty else { continue }
            let session = file.parser.session
            if sessions[session.id] == nil || sessions[session.id]!.observedAt < session.observedAt { sessions[session.id] = session }
        }
        snapshot.sessions = sessions.values.filter { $0.observedAt > now.addingTimeInterval(-86400) }.sorted {
            let left = $0.status.needsAttention ? 0 : $0.status.isActive ? 1 : 2
            let right = $1.status.needsAttention ? 0 : $1.status.isActive ? 1 : 2
            return left == right ? $0.observedAt > $1.observedAt : left < right
        }
        return snapshot
    }
    private func discover() {
        var urls: [URL] = [], seen: Set<String> = []
        compressedCount = 0
        for name in (provider == .codex ? ["sessions", "archived_sessions"] : ["projects"]) {
            let directory = root.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                if url.pathExtension == "zst" { compressedCount += 1; continue }
                guard url.pathExtension == "jsonl" else { continue }
                // The active directory wins over its archived equivalent.
                let relative = String(url.path.dropFirst(directory.path.count))
                if seen.insert(relative).inserted { urls.append(url) }
            }
        }
        knownURLs = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}

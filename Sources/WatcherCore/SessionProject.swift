import Foundation

public enum SessionProject {
    /// Resolve once from the session's initial directory. Worktree .git files
    /// count as repository markers too; no git process or directory scan.
    public static func root(for directory: String) -> String {
        let initial = URL(fileURLWithPath: directory).standardizedFileURL
        var candidate = initial
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return candidate.path }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return initial.path
    }

    private enum HeaderFound: Error { case directory(String) }
    private static func initialDirectory(in url: URL, provider: AgentProvider) -> String? {
        do {
            _ = try LineReader.read(url, cursor: ReadCursor(), byteBudget: 2 * 1024 * 1024) { line, _ in
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                let object: [String: Any]?
                if provider == .claude { object = record }
                else if record["type"] as? String == "session_meta" { object = record["payload"] as? [String: Any] }
                else { object = nil }
                if let cwd = object?["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 { throw HeaderFound.directory(cwd) }
            }
        } catch HeaderFound.directory(let cwd) { return cwd }
        catch { return nil }
        return nil
    }

    /// Repair metadata from old caches without reindexing token usage. Prefer
    /// the transcript header over the old cache's latest, possibly unrelated cwd.
    public static func restoring(_ session: SessionRecord, from url: URL, provider: AgentProvider) -> SessionRecord {
        guard session.projectDirectory == nil else { return session }
        var repaired = session
        let initial = initialDirectory(in: url, provider: provider) ?? (session.directory.hasPrefix("/") ? session.directory : nil)
        if let initial {
            let directory = root(for: initial)
            repaired.projectDirectory = directory
            repaired.project = URL(fileURLWithPath: directory).lastPathComponent
            if repaired.directory.isEmpty { repaired.directory = initial }
            repaired.directoryObservedAt = session.directoryObservedAt ?? session.observedAt
        }
        return repaired
    }
}

extension SessionRecord {
    mutating func observeDirectory(_ cwd: String, at time: Date?) {
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { return }
        let normalized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        if projectDirectory == nil {
            let anchor = SessionProject.root(for: normalized)
            projectDirectory = anchor; project = URL(fileURLWithPath: anchor).lastPathComponent
        }
        if directory.isEmpty || (time != nil && time! >= (directoryObservedAt ?? observedAt)) {
            directory = normalized; directoryObservedAt = time
        }
    }
}

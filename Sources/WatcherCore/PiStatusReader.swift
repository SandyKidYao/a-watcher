import Foundation
import Darwin

/// Read only small snapshots produced by the opt-in extension. Root-bound
/// records keep separate installations from sharing session identities.
public actor PiStatusReader: AgentStatusFeed {
    private struct Evidence: Decodable {
        let version: Int
        let id, root, cwd: String
        let pid: Int32
        let status: SessionStatus
        let completions: [Double]?
        let time: Double
    }
    public let directory: URL
    private let rootHash: String
    private var sessions: [String: SessionRecord] = [:]
    public init(directory: URL, agentRoot: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        rootHash = stableHash(physicalPath(agentRoot.path))
    }
    public func update(paths: [String], now: Date = Date()) -> [String: SessionRecord] {
        var urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        if urls.contains(where: { $0.path == directory.path }) {
            urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            sessions.removeAll()
        }
        for url in Set(urls) where url.pathExtension == "jsonl" {
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == directory.path else { continue }
            let file = directory.appendingPathComponent(url.lastPathComponent)
            sessions[file.path] = read(file, now: now)
        }
        sessions = sessions.filter { now.timeIntervalSince($0.value.observedAt) < 86400 }
        return Dictionary(SessionRecord.latest(Array(sessions.values), now: now).map { ($0.key, $0) }, uniquingKeysWith: { lhs, _ in lhs })
    }
    private func read(_ url: URL, now: Date) -> SessionRecord? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 8192,
              info.st_uid == getuid(), let data = try? file.read(upToCount: 8193), data.count <= 8192,
              let entry = try? JSONDecoder().decode(Evidence.self, from: data),
              entry.version == 1, entry.root == rootHash, !entry.id.isEmpty, entry.id.utf8.count <= 256, entry.pid > 0 else { return nil }
        let date = Date(timeIntervalSince1970: entry.time / 1000)
        let age = now.timeIntervalSince(date)
        if age >= 86400 {
            // The writer uses a random instance ID in the filename. Once it
            // exits it cannot replace this snapshot. Prune only our own format.
            if kill(entry.pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        guard age >= -5 else { return nil }
        var status = entry.status
        if status.isActive && (age >= 180 || (kill(entry.pid, 0) != 0 && errno == ESRCH)) { status = .unknown }
        var session = SessionRecord(id: entry.id, project: "Pi", status: status, observedAt: date, source: "Pi 扩展")
        session.confirmedCompletions = (entry.completions ?? []).suffix(32).map { Date(timeIntervalSince1970: $0 / 1000) }.filter { $0 <= date && now.timeIntervalSince($0) < 86400 }
        session.provider = .pi
        session.observeDirectory(entry.cwd, at: date)
        return session
    }
}

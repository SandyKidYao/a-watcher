import Foundation

protocol SessionParser: Sendable {
    var state: ParserState { get set }
    mutating func consume(_ line: Data, offset: UInt64) -> [UsageRecord]
}
extension CodexParser: SessionParser {}
extension ClaudeParser: SessionParser {}

public protocol AgentQuotaClient: Sendable {
    func lastKnown() async -> QuotaSnapshot?
    func refresh(manual: Bool) async throws -> QuotaSnapshot
}
extension CodexQuotaClient: AgentQuotaClient {}
extension ClaudeQuotaClient: AgentQuotaClient {}

public protocol AgentStatusFeed: Actor {
    nonisolated var directory: URL { get }
    func update(paths: [String], now: Date) -> [String: SessionRecord]
}

struct LedgerPolicy: Sendable {
    typealias Match = @Sendable (SQLiteStore, String, String, [String: IndexedFile]) throws -> Bool
    let insert: @Sendable (SQLiteStore, UsageRecord, String, Bool) throws -> Void
    var matchFork: Match?

    static let codexPrefix = Self(insert: { store, record, path, fork in
        let excluded = try fork && !store.forkResolved(record.sessionID)
        try store.insertUsage(record, path: path, excluded: excluded)
    }, matchFork: { try $0.reconcilePrefix(child: $1, parent: $2, files: $3) })

    static let streamingResponses = Self(insert: { store, record, path, _ in
        try store.mergeStreamingResponse(record, path: path)
    })

    static let piEntries = Self(insert: { store, record, path, fork in
        if fork {
            try store.run("UPDATE forks SET resolved=0 WHERE session=? AND resolved=1", [.text(record.sessionID)])
        }
        try store.insertUsage(record, path: path, excluded: fork)
    }, matchFork: { try $0.reconcileEntryIDs(child: $1, parent: $2, files: $3) })
}

/// Built-in adapters share file observation, indexing and presentation.
public struct AgentSource: Sendable {
    public let name: String
    public let shortName: String
    public let directories: [String]
    let environmentKey: String
    let defaultHome: String
    public let watchDirectory: String
    let ledger: LedgerPolicy
    let parser: @Sendable (ParserState, String) -> any SessionParser
    let headerDirectory: @Sendable ([String: Any]) -> String?
    public var applicationID: String? = nil
    public var darkAsset: String? = nil
    public var symbol = "app"
    var sessionDirectoryEnvironment: String? = nil
    public var reasoning = false
    public var billing = false
    public var statusFeed: (@Sendable (URL, URL) -> any AgentStatusFeed)? = nil
    public var quotaAuthFile: String? = nil
    public var automaticQuotaInterval: TimeInterval = 0
    public var quotaClient: (@Sendable (URL, URL) -> any AgentQuotaClient)? = nil
    public var weeklyWindow: @Sendable (QuotaWindow) -> Bool = { _ in false }

    public func sessionOverride(_ argument: String?) -> URL? {
        guard let key = sessionDirectoryEnvironment, let path = argument ?? ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
    }
    func transcriptDirectories(root: URL, override: URL?) -> [URL] {
        if let override { return [override] }
        return directories.map { root.appendingPathComponent($0) }
    }
    public func root(override: String?) -> URL {
        URL(fileURLWithPath: override ?? ProcessInfo.processInfo.environment[environmentKey] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(defaultHome).path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
extension AgentProvider {
    public var source: AgentSource {
        switch self {
        case .codex: Self.codexSource
        case .claude: Self.claudeSource
        case .pi: Self.piSource
        }
    }
    private static let codexSource = AgentSource(
        name: "Codex", shortName: "Codex", directories: ["sessions", "archived_sessions"],
        environmentKey: "CODEX_HOME", defaultHome: ".codex", watchDirectory: "",
        ledger: .codexPrefix, parser: { state, _ in CodexParser(state: state) },
        headerDirectory: { record in
            guard record["type"] as? String == "session_meta" else { return nil }
            return (record["payload"] as? [String: Any])?["cwd"] as? String
        },
        applicationID: "com.openai.codex", darkAsset: "codex-dark", reasoning: true, quotaAuthFile: "auth.json",
        quotaClient: { root, directory in
            CodexQuotaClient(root: root, cacheFile: directory.appendingPathComponent("quota-\(stableHash(root.path).prefix(16)).json"))
        },
        weeklyWindow: { $0.name == "Codex" && $0.seconds == 604800 }
    )

    private static let claudeSource = AgentSource(
        name: "Claude Code", shortName: "Claude", directories: ["projects"],
        environmentKey: "CLAUDE_CONFIG_DIR", defaultHome: ".claude", watchDirectory: "projects",
        ledger: .streamingResponses, parser: { ClaudeParser(state: $0, fileID: $1) },
        headerDirectory: { $0["cwd"] as? String }, billing: true, automaticQuotaInterval: 600,
        quotaClient: { root, directory in
            ClaudeQuotaClient(root: root, cacheFile: directory.appendingPathComponent("quota-claude-\(stableHash(root.path).prefix(16)).json"))
        },
        weeklyWindow: { $0.id == "seven_day" }
    )

    private static let piSource = AgentSource(
        name: "Pi", shortName: "Pi", directories: ["sessions"],
        environmentKey: "PI_CODING_AGENT_DIR", defaultHome: ".pi/agent", watchDirectory: "sessions",
        ledger: .piEntries, parser: { state, _ in PiParser(state: state) },
        headerDirectory: { $0["type"] as? String == "session" ? $0["cwd"] as? String : nil },
        darkAsset: "pi-dark", symbol: "p.circle", sessionDirectoryEnvironment: "PI_CODING_AGENT_SESSION_DIR",
        statusFeed: { root, directory in
            PiStatusReader(directory: directory.appendingPathComponent("pi-status"), agentRoot: root)
        }
    )
}

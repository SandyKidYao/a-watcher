import Foundation
import CSQLite

enum SQLValue { case text(String), integer(Int64), real(Double), blob(Data) }
public enum StoreError: Error { case database(Int32) }

struct IndexedFile: Codable {
    var path: String
    var identity: String
    var size: UInt64
    var modified: Double
    var cursor: ReadCursor
    var parser: ParserState
    var skipped: Int
    var complete: Bool
}

/// One owner (CodexIndex actor) serializes use; SQLite additionally uses FULLMUTEX.
final class SQLiteStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { throw StoreError.database(code) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 1000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-2048")
        try execute("""
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, state BLOB NOT NULL, present INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE IF NOT EXISTS usage(
                path TEXT NOT NULL, event_key TEXT NOT NULL, session TEXT NOT NULL,
                ordinal INTEGER NOT NULL, timestamp REAL NOT NULL, model TEXT NOT NULL, tier TEXT NOT NULL,
                input INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                output INTEGER NOT NULL, reasoning INTEGER NOT NULL, compaction INTEGER NOT NULL,
                replay INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(path,event_key));
            CREATE INDEX IF NOT EXISTS usage_date ON usage(timestamp);
            CREATE INDEX IF NOT EXISTS usage_session ON usage(session,ordinal);
            CREATE TABLE IF NOT EXISTS forks(session TEXT PRIMARY KEY, parent TEXT NOT NULL, resolved INTEGER NOT NULL DEFAULT 0);
            """)
        let columns = try statement("PRAGMA table_info(usage)")
        var hasFinal = false
        while sqlite3_step(columns) == SQLITE_ROW { if text(columns, 1) == "finalized" { hasFinal = true } }
        sqlite3_finalize(columns)
        if !hasFinal { try execute("ALTER TABLE usage ADD COLUMN finalized INTEGER NOT NULL DEFAULT 1") }
        try execute("CREATE INDEX IF NOT EXISTS usage_event_key ON usage(event_key)")
        try execute("""
            CREATE TABLE IF NOT EXISTS canonical_usage AS SELECT * FROM usage WHERE 0;
            CREATE UNIQUE INDEX IF NOT EXISTS canonical_key ON canonical_usage(event_key);
            CREATE INDEX IF NOT EXISTS canonical_date ON canonical_usage(timestamp);
            CREATE TRIGGER IF NOT EXISTS usage_insert_canonical AFTER INSERT ON usage BEGIN
                DELETE FROM canonical_usage WHERE event_key=NEW.event_key;
                INSERT INTO canonical_usage SELECT * FROM usage WHERE event_key=NEW.event_key AND replay=0 ORDER BY timestamp,path LIMIT 1;
            END;
            CREATE TRIGGER IF NOT EXISTS usage_delete_canonical AFTER DELETE ON usage BEGIN
                DELETE FROM canonical_usage WHERE event_key=OLD.event_key;
                INSERT INTO canonical_usage SELECT * FROM usage WHERE event_key=OLD.event_key AND replay=0 ORDER BY timestamp,path LIMIT 1;
            END;
            CREATE TRIGGER IF NOT EXISTS usage_update_canonical AFTER UPDATE ON usage BEGIN
                DELETE FROM canonical_usage WHERE event_key=NEW.event_key;
                INSERT INTO canonical_usage SELECT * FROM usage WHERE event_key=NEW.event_key AND replay=0 ORDER BY timestamp,path LIMIT 1;
            END;
            """)
        let version = try statement("PRAGMA user_version")
        let migrate = sqlite3_step(version) == SQLITE_ROW && sqlite3_column_int(version, 0) < 2
        sqlite3_finalize(version)
        if migrate {
            try begin()
            do {
                try execute("DELETE FROM canonical_usage; INSERT OR REPLACE INTO canonical_usage SELECT * FROM usage WHERE replay=0 ORDER BY timestamp DESC,path DESC; PRAGMA user_version=2")
                try commit()
            } catch { rollback(); throw error }
        }
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw StoreError.database(code) }
    }
    func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let stmt else { throw StoreError.database(code) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let bound: Int32
            switch value {
            case .text(let v): bound = v.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
            case .integer(let v): bound = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): bound = sqlite3_bind_double(stmt, index, v)
            case .blob(let v): bound = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), transient) }
            }
            guard bound == SQLITE_OK else { sqlite3_finalize(stmt); throw StoreError.database(bound) }
        }
        return stmt
    }
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE else { throw StoreError.database(code) }
    }
    func begin() throws { try execute("BEGIN IMMEDIATE") }
    func commit() throws { try execute("COMMIT") }
    func rollback() { try? execute("ROLLBACK") }
    func loadFiles() throws -> [String: IndexedFile] {
        let stmt = try statement("SELECT path,state FROM files"); defer { sqlite3_finalize(stmt) }
        var result: [String: IndexedFile] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
            if let entry = try? JSONDecoder().decode(IndexedFile.self, from: data) { result[text(stmt, 0)] = entry }
        }
        return result
    }
    func resetFile(_ path: String) throws {
        try run("DELETE FROM usage WHERE path=?", [.text(path)])
        try run("UPDATE forks SET resolved=0")
    }
    func save(_ file: IndexedFile) throws {
        try run("INSERT INTO files(path,state,present) VALUES(?,?,1) ON CONFLICT(path) DO UPDATE SET state=excluded.state,present=1", [.text(file.path), .blob(try JSONEncoder().encode(file))])
        if let parent = file.parser.session.parentID {
            try run("INSERT INTO forks(session,parent) VALUES(?,?) ON CONFLICT(session) DO UPDATE SET parent=excluded.parent", [.text(file.parser.session.id), .text(parent)])
        }
    }
    func insert(_ record: UsageRecord, path: String, fork: Bool) throws {
        if record.key.hasPrefix("claude:") { try insertClaude(record, path: path); return }
        if record.removal { try run("DELETE FROM usage WHERE event_key=?", [.text(record.key)]); return }
        var exclude = fork
        if fork {
            let resolved = try statement("SELECT resolved FROM forks WHERE session=?", [.text(record.sessionID)])
            defer { sqlite3_finalize(resolved) }
            if sqlite3_step(resolved) == SQLITE_ROW, sqlite3_column_int(resolved, 0) == 1 { exclude = false }
        }
        try run("""
            INSERT OR IGNORE INTO usage(path,event_key,session,ordinal,timestamp,model,tier,input,cached,cache_write,output,reasoning,compaction,replay)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(path), .text(record.key), .text(record.sessionID), .integer(record.ordinal), .real(record.timestamp.timeIntervalSince1970),
                   .text(record.model), .text(record.tier), .integer(record.tokens.input), .integer(record.tokens.cached), .integer(record.tokens.cacheWrite),
                   .integer(record.tokens.output), .integer(record.tokens.reasoning), .integer(record.compaction ? 1 : 0), .integer(exclude ? 1 : 0)])
    }
    private func insertClaude(_ record: UsageRecord, path: String) throws {
        // Upgrade every known copy together. An older partial chunk cannot
        // overwrite a final response, and duplicate copies keep their dates.
        let lookup = try statement("SELECT input,cached,cache_write,output,reasoning,finalized FROM usage WHERE event_key=? ORDER BY finalized DESC,output DESC LIMIT 1", [.text(record.key)])
        defer { sqlite3_finalize(lookup) }
        var tokens = record.tokens, final = record.finalized
        if sqlite3_step(lookup) == SQLITE_ROW {
            let oldFinal = sqlite3_column_int(lookup, 5) != 0
            let oldOutput = sqlite3_column_int64(lookup, 3)
            if (oldFinal && !final) || (oldFinal == final && oldOutput >= tokens.output) {
                tokens = TokenUsage(input: sqlite3_column_int64(lookup, 0), cached: sqlite3_column_int64(lookup, 1), cacheWrite: sqlite3_column_int64(lookup, 2), output: oldOutput, reasoning: sqlite3_column_int64(lookup, 4))
                final = oldFinal
            }
        }
        try run("UPDATE usage SET input=?,cached=?,cache_write=?,output=?,reasoning=?,finalized=? WHERE event_key=?",
            [.integer(tokens.input), .integer(tokens.cached), .integer(tokens.cacheWrite), .integer(tokens.output), .integer(tokens.reasoning), .integer(final ? 1 : 0), .text(record.key)])
        try run("INSERT OR IGNORE INTO usage(path,event_key,session,ordinal,timestamp,model,tier,input,cached,cache_write,output,reasoning,compaction,replay,finalized) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,0,?)",
            [.text(path), .text(record.key), .text(record.sessionID), .integer(record.ordinal), .real(record.timestamp.timeIntervalSince1970), .text(record.model), .text(record.tier), .integer(tokens.input), .integer(tokens.cached), .integer(tokens.cacheWrite), .integer(tokens.output), .integer(tokens.reasoning), .integer(final ? 1 : 0)])
    }
    func reconcileForks(files: [String: IndexedFile]) throws {
        let forks = try statement("SELECT session,parent FROM forks WHERE resolved=0"); defer { sqlite3_finalize(forks) }
        var pairs: [(String, String)] = []
        while sqlite3_step(forks) == SQLITE_ROW { pairs.append((text(forks, 0), text(forks, 1))) }
        for (child, parent) in pairs {
            guard files.values.contains(where: { $0.parser.session.id == child && $0.complete }),
                  files.values.contains(where: { $0.parser.session.id == parent && $0.complete }) else { continue }
            // Compare the child's leading usage against the parent's actual prefix,
            // independently of rewritten timestamps. No parent => remain excluded
            // and report incomplete coverage instead of inflating the total.
            let sql = "SELECT event_key,input,cached,cache_write,output,reasoning FROM usage WHERE session=? AND compaction=0 GROUP BY event_key ORDER BY MIN(ordinal)"
            let c = try statement(sql, [.text(child)]), p = try statement(sql, [.text(parent)])
            defer { sqlite3_finalize(c); sqlite3_finalize(p) }
            var replayKeys: [String] = []
            while sqlite3_step(c) == SQLITE_ROW {
                guard sqlite3_step(p) == SQLITE_ROW else { break }
                if (1...5).allSatisfy({ sqlite3_column_int64(c, Int32($0)) == sqlite3_column_int64(p, Int32($0)) }) {
                    replayKeys.append(text(c, 0))
                } else { break }
            }
            try run("UPDATE usage SET replay=0 WHERE session=?", [.text(child)])
            for key in replayKeys { try run("UPDATE usage SET replay=1 WHERE session=? AND event_key=?", [.text(child), .text(key)]) }
            try run("UPDATE forks SET resolved=1 WHERE session=?", [.text(child)])
        }
    }
    func summary(since: Date, until: Date = .distantFuture) throws -> UsageSummary {
        var summary = UsageSummary()
        // SQLite's MIN aggregate picks the row carrying the earliest timestamp.
        // Replayed compaction copies must keep their original spend day.
        let unique = "SELECT * FROM canonical_usage"
        let stmt = try statement("SELECT COALESCE(SUM(input),0),COALESCE(SUM(cached),0),COALESCE(SUM(cache_write),0),COALESCE(SUM(output),0),COALESCE(SUM(reasoning),0),COUNT(*) FROM (\(unique)) WHERE timestamp>=? AND timestamp<?", [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database(sqlite3_errcode(db)) }
        summary.tokens = TokenUsage(input: sqlite3_column_int64(stmt, 0), cached: sqlite3_column_int64(stmt, 1), cacheWrite: sqlite3_column_int64(stmt, 2), output: sqlite3_column_int64(stmt, 3), reasoning: sqlite3_column_int64(stmt, 4))
        summary.records = Int(sqlite3_column_int64(stmt, 5))
        let incomplete = try statement("SELECT COUNT(DISTINCT event_key) FROM usage WHERE finalized=0 AND timestamp>=? AND timestamp<?", [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)])
        defer { sqlite3_finalize(incomplete) }
        if sqlite3_step(incomplete) == SQLITE_ROW { summary.incompleteRequests = Int(sqlite3_column_int64(incomplete, 0)) }
        let grouped = try statement("SELECT model,SUM(input+output) FROM (\(unique)) WHERE timestamp>=? AND timestamp<? GROUP BY model ORDER BY SUM(input+output) DESC", [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)])
        defer { sqlite3_finalize(grouped) }
        while sqlite3_step(grouped) == SQLITE_ROW { summary.byModel.append(UsageGroup(name: text(grouped, 0), tokens: sqlite3_column_int64(grouped, 1))) }
        let replay = try statement("SELECT COUNT(*) FROM usage WHERE replay=1 AND timestamp>=? AND timestamp<?", [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)])
        defer { sqlite3_finalize(replay) }
        if sqlite3_step(replay) == SQLITE_ROW { summary.excludedReplayRecords = Int(sqlite3_column_int64(replay, 0)) }
        let unresolved = try statement("SELECT COUNT(*) FROM forks WHERE resolved=0"); defer { sqlite3_finalize(unresolved) }
        if sqlite3_step(unresolved) == SQLITE_ROW { summary.unresolvedForks = Int(sqlite3_column_int64(unresolved, 0)) }
        return summary
    }
    func hasUnresolvedForks() throws -> Bool {
        let stmt = try statement("SELECT EXISTS(SELECT 1 FROM forks WHERE resolved=0)")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) != 0
    }
    func history(from start: Date, until end: Date, calendar: Calendar) throws -> UsageHistory {
        var history = UsageHistory()
        let first = try statement("SELECT MIN(timestamp) FROM canonical_usage")
        if sqlite3_step(first) == SQLITE_ROW, sqlite3_column_type(first, 0) != SQLITE_NULL { history.firstRecordedAt = Date(timeIntervalSince1970: sqlite3_column_double(first, 0)) }
        sqlite3_finalize(first)
        let stmt = try statement("SELECT timestamp,input,cached,cache_write,output,reasoning,model,finalized FROM canonical_usage WHERE timestamp>=? AND timestamp<? ORDER BY timestamp", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
        defer { sqlite3_finalize(stmt) }
        var buckets: [Date: UsageDay] = [:]
        history.isPartial = false
        var finished = false
        while !finished {
            try Task.checkCancellation()
            try autoreleasepool {
                for _ in 0..<512 {
                    let status = sqlite3_step(stmt)
                    if status == SQLITE_DONE { finished = true; break }
                    guard status == SQLITE_ROW else { throw StoreError.database(status) }
                    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)))
                    let usage = TokenUsage(input: sqlite3_column_int64(stmt, 1), cached: sqlite3_column_int64(stmt, 2), cacheWrite: sqlite3_column_int64(stmt, 3), output: sqlite3_column_int64(stmt, 4), reasoning: sqlite3_column_int64(stmt, 5))
                    buckets[day, default: UsageDay(date: day)].add(usage, model: text(stmt, 6))
                    if sqlite3_column_int(stmt, 7) == 0 { history.isPartial = true }
                }
            }
        }
        history.days = buckets.values.sorted { $0.date < $1.date }
        return history
    }
    func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}

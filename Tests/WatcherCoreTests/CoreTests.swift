import Foundation
import WatcherCore

private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
private func meta(_ id: String = "session", parent: String? = nil) throws -> Data {
    var payload: [String: Any] = ["id": id, "cwd": "/synthetic/project"]
    if let parent { payload["forked_from_id"] = parent }
    return try json(["type": "session_meta", "payload": payload])
}
private func tokens(input: Int = 100, output: Int = 10, last: Bool = true, time: String = "2026-11-06T01:00:00Z") throws -> Data {
    let usage = ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": output, "reasoning_output_tokens": output / 2]
    var info = ["total_token_usage": usage]
    if last { info["last_token_usage"] = usage }
    return try json(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": info]])
}
private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("a-watcher-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func cachedAndReasoningAreSubsets() throws {
    try expect(TokenUsage(input: 1000, cached: 800, output: 200, reasoning: 150).total == 1200)
    try expect(TokenUsage(input: 100, cached: 200, cacheWrite: 80, output: 20, reasoning: 80) == TokenUsage(input: 100, cached: 100, output: 20, reasoning: 20))
}
func timestampSupportsWholeAndFractionalSeconds() throws {
    try expect(parseTimestamp("2026-11-06T01:02:03Z") != nil)
    try expect(parseTimestamp("2026-11-06T01:02:03.123Z") != nil)
    try expect(parseTimestamp("not a date") == nil)
}
func cumulativeRepetitionDoesNotChargeAgain() throws {
    var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
    try expect(parser.consume(try tokens(), offset: 1).first?.tokens.total == 110)
    try expect(parser.consume(try tokens(time: "2026-11-06T01:00:01Z"), offset: 2).isEmpty)
}
func cumulativeOnlyEventsProduceDeltas() throws {
    var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
    _ = parser.consume(try tokens(last: false), offset: 1)
    try expect(parser.consume(try tokens(input: 180, output: 40, last: false), offset: 2).first?.tokens.total == 110)
}
func counterResetCanUseRecordedRequestDelta() throws {
    var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
    _ = parser.consume(try tokens(input: 1000, output: 100), offset: 1)
    try expect(parser.consume(try tokens(input: 30, output: 3), offset: 2).first?.tokens.total == 33)
}
private func compactionRequest() throws -> Data {
    try json(["type": "token_usage_record", "timestamp": "2026-11-06T01:00:00Z", "payload": ["response_id": "r1", "usage": ["input_tokens": 100, "cached_input_tokens": 50, "output_tokens": 10, "reasoning_output_tokens": 5]]])
}
private func compactionMarker() throws -> Data { try json(["type": "compacted", "payload": ["compaction_response_id": "r1"]]) }
func unpairedRequestRecordsAreNotDoubleCounted() throws {
    var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
    try expect(parser.consume(try compactionRequest(), offset: 1).isEmpty)
    try expect(parser.consume(try tokens(), offset: 2).first?.tokens.total == 110)
    try expect(parser.consume(try compactionMarker(), offset: 3).isEmpty)
}
func remoteCompactionWorksInEitherRecordOrder() throws {
    for order in [[try compactionRequest(), try compactionMarker()], [try compactionMarker(), try compactionRequest()]] {
        var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
        let records = order.enumerated().flatMap { parser.consume($0.element, offset: UInt64($0.offset + 1)) }
        try expect(records.map(\.tokens.total).reduce(0, +) == 110)
    }
}
func localCompactionLateAdvanceRetractsExtraRecord() throws {
    var parser = CodexParser(); _ = parser.consume(try meta(), offset: 0)
    _ = parser.consume(try compactionRequest(), offset: 1)
    try expect(parser.consume(try compactionMarker(), offset: 2).count == 1)
    let records = parser.consume(try tokens(), offset: 3)
    try expect(records.count == 2); try expect(records.first?.removal == true)
}
func partialLineWaitsForNewline() throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("log.jsonl"); try Data("first\npar".utf8).write(to: file)
    var rows: [String] = []
    let first = try LineReader.read(file, cursor: ReadCursor()) { data, _ in rows.append(String(decoding: data, as: UTF8.self)) }
    try expect(rows == ["first"]); try expect(first.cursor.offset == 6)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("tial\n".utf8)); try handle.close()
    _ = try LineReader.read(file, cursor: first.cursor) { data, _ in rows.append(String(decoding: data, as: UTF8.self)) }
    try expect(rows == ["first", "partial"])
}
func oversizedLineTailCannotBecomeARecord() throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("log.jsonl"); try Data(repeating: 65, count: 100).write(to: file)
    let first = try LineReader.read(file, cursor: ReadCursor(), lineLimit: 16) { _, _ in throw CheckFailure("oversized line was admitted") }
    try expect(first.cursor.dropping)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\nvalid\n".utf8)); try handle.close()
    var rows: [String] = []
    let next = try LineReader.read(file, cursor: first.cursor, lineLimit: 16) { data, _ in rows.append(String(decoding: data, as: UTF8.self)) }
    try expect(rows == ["valid"]); try expect(next.skipped == 1)
}
func quotaWindowIsDataDrivenAndInvalidSiblingsAreSkipped() throws {
    let data = try json(["rate_limit": ["primary_window": ["used_percent": 32, "limit_window_seconds": 604800, "reset_at": 1794000000], "secondary_window": ["used_percent": true]]])
    let snapshot = try QuotaDecoder.decode(data, binding: "test")
    try expect(snapshot.windows.count == 1); try expect(snapshot.windows.first?.shortLabel == "7d"); try expect(snapshot.windows.first?.remainingPercent == 68)
}
func missingQuotaNeverMeansZeroOrAnotherAccount() throws {
    try expectThrows { try QuotaDecoder.decode(json(["rate_limit": [:]]), binding: "test") }
    try expectThrows { try QuotaDecoder.decode(json(["account_id": "other", "rate_limit": [:]]), binding: "test", accountID: "current") }
}
func persistedIndexSurvivesRestartAndTruncation() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let sessions = folder.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout.jsonl")
    func write(_ input: Int) throws { var d = try meta(); d.append(10); d.append(try tokens(input: input)); d.append(10); try d.write(to: file) }
    try write(100)
    let index = try CodexIndex(root: folder, database: folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    try await expectAsync { try await index.scanStep(now: now).usage.tokens.total == 110 }
    let restarted = try CodexIndex(root: folder, database: folder.appendingPathComponent("cache.sqlite"))
    try await expectAsync { try await restarted.scanStep(now: now).usage.tokens.total == 110 }
    try write(40); await restarted.invalidate()
    try await expectAsync { try await restarted.scanStep(now: now).usage.tokens.total == 50 }
}
func forkReplayIsExcludedButOwnRequestsRemain() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let sessions = folder.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    for (name, id, parent, rows) in [("parent", "parent", nil as String?, [try tokens()]), ("child", "child", "parent", [try tokens(time: "2026-11-06T01:01:00Z"), try tokens(input: 20, output: 2, time: "2026-11-06T01:02:00Z")])] {
        var data = try meta(id, parent: parent); data.append(10)
        for row in rows { data.append(row); data.append(10) }
        try data.write(to: sessions.appendingPathComponent("\(name).jsonl"))
    }
    let index = try CodexIndex(root: folder, database: folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    let snapshot = try await index.scanStep(now: now)
    try expect(snapshot.usage.tokens.total == 132); try expect(snapshot.usage.unresolvedForks == 0)
    let handle = try FileHandle(forWritingTo: sessions.appendingPathComponent("child.jsonl"))
    try handle.seekToEnd(); var appended = try tokens(input: 10, output: 1, time: "2026-11-06T01:03:00Z"); appended.append(10)
    try handle.write(contentsOf: appended); try handle.close(); await index.invalidate()
    try await expectAsync { try await index.scanStep(now: now).usage.tokens.total == 143 }
}

func compactionCopiesKeepOriginalSpendDay() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let sessions = folder.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    for (name, timestamp) in [("old", "2026-11-05T01:00:00Z"), ("copy", "2026-11-06T01:00:00Z")] {
        var data = try meta(name); data.append(10)
        let request = String(decoding: try compactionRequest(), as: UTF8.self).replacingOccurrences(of: "2026-11-06T01:00:00Z", with: timestamp)
        data.append(Data(request.utf8)); data.append(10); data.append(try compactionMarker()); data.append(10)
        try data.write(to: sessions.appendingPathComponent("\(name).jsonl"))
    }
    let index = try CodexIndex(root: folder, database: folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = try await index.scanStep(days: 1, calendar: calendar, now: now)
    try expect(today.usage.tokens.total == 0)
    let week = try await index.snapshot(days: 7, calendar: calendar, now: now)
    try expect(week.usage.tokens.total == 110)
}
func archivedCopyDoesNotDoubleCountSession() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    for (directory, name) in [("sessions", "active"), ("archived_sessions", "copy")] {
        let dir = folder.appendingPathComponent(directory); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = try meta(); data.append(10); data.append(try tokens()); data.append(10)
        try data.write(to: dir.appendingPathComponent("\(name).jsonl"))
    }
    let index = try CodexIndex(root: folder, database: folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    let snapshot = try await index.scanStep(now: now)
    try expect(snapshot.usage.tokens.total == 110)
    try expect(snapshot.sessions.count == 1)
}

private func claudeRow(output: Int, final: Bool, request: String = "req-1", time: String = "2026-11-06T01:00:00Z") throws -> Data {
    try json(["type":"assistant", "sessionId":"c1", "cwd":"/synthetic/claude-project", "requestId":request, "timestamp":time,
        "message":["id":"msg_unique", "model":"claude-test", "stop_reason":final ? "end_turn" as Any : NSNull(),
        "usage":["input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"cache_creation":["ephemeral_5m_input_tokens":300],"output_tokens":output]]])
}
func claudeCacheAccountingAndIdentity() throws {
    var parser = ClaudeParser(fileID:"c1")
    let row = try require(parser.consume(try claudeRow(output:50,final:true), offset:0).first)
    try expect(row.tokens.total == 650); try expect(row.tokens.input == 600)
    try expect(row.tokens.cached == 200); try expect(row.tokens.cacheWrite == 300)
    try expect(parser.state.session.provider == .claude); try expect(parser.state.session.status == .idle)
    var codex = SessionRecord(id:"c1"); codex.provider = .codex
    try expect(codex.key != parser.state.session.key)
}
func claudeStreamUpdatesAndCrossFileCopies() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let projects = folder.appendingPathComponent("projects/p"); try FileManager.default.createDirectory(at:projects, withIntermediateDirectories:true)
    let file = projects.appendingPathComponent("c1.jsonl")
    var initial = try claudeRow(output:9,final:false); initial.append(10); try initial.write(to:file)
    let index = try CodexIndex(root:folder, database:folder.appendingPathComponent("cache.sqlite"), provider:.claude)
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    let first = try await index.scanStep(now:now)
    try expect(first.usage.tokens.total == 609); try expect(first.usage.incompleteRequests == 1)
    let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
    var last = try claudeRow(output:159,final:true,time:"2026-11-06T01:00:10Z"); last.append(10)
    try handle.write(contentsOf:last); try handle.close()
    var copy = try claudeRow(output:159,final:true,request:"rewritten-copy",time:"2026-11-06T01:00:20Z"); copy.append(10)
    try copy.write(to:projects.appendingPathComponent("copy.jsonl"))
    await index.invalidate(); let done = try await index.scanStep(now:now)
    try expect(done.usage.tokens.total == 759); try expect(done.usage.records == 1); try expect(done.usage.incompleteRequests == 0)
    let late = try FileHandle(forWritingTo:file); try late.seekToEnd(); try late.write(contentsOf:initial); try late.close()
    await index.invalidate(); let stable = try await index.scanStep(now:now)
    try expect(stable.usage.tokens.total == 759); try expect(stable.usage.incompleteRequests == 0)
    let restarted = try CodexIndex(root:folder,database:folder.appendingPathComponent("cache.sqlite"),provider:.claude)
    let restart = try await restarted.scanStep(now:now); try expect(restart.usage.tokens.total == 759)
}
func claudeQuestionLifecycleAndBookkeeping() throws {
    var parser = ClaudeParser(fileID:"file-fallback")
    _ = parser.consume(try json(["type":"assistant","sessionId":"actual-session","timestamp":"2026-11-06T01:00:00Z", "message":["stop_reason":"tool_use", "content":[["type":"tool_use","name":"AskUserQuestion"]]]]), offset:0)
    try expect(parser.state.session.status == .waitingInput)
    _ = parser.consume(try json(["type":"ai-title","timestamp":"2026-11-06T01:00:02Z"]), offset:1)
    try expect(parser.state.session.status == .waitingInput); try expect(parser.state.session.id == "actual-session")
    _ = parser.consume(try json(["type":"user","sessionId":"actual-session","timestamp":"2026-11-06T01:00:03Z","message":["content":[["type":"tool_result"]]]]), offset:2)
    try expect(parser.state.session.status == .running)
    _ = parser.consume(try json(["type":"assistant","sessionId":"actual-session","timestamp":"2026-11-06T01:00:04Z","message":["stop_reason":"end_turn"]]), offset:3)
    try expect(parser.state.session.status == .idle)
    _ = parser.consume(try json(["type":"assistant","sessionId":"actual-session","timestamp":"2026-11-06T01:00:05Z","message":["stop_reason":"max_tokens"]]), offset:4)
    try expect(parser.state.session.status == .unknown)
}

func liveStatusUpdatesWithoutRefreshingUsage() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let dir = folder.appendingPathComponent("projects/p"); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    let file = dir.appendingPathComponent("c1.jsonl")
    var row = try claudeRow(output:50,final:true); row.append(10); try row.write(to:file)
    let engine = try CodexIndex(root:folder,database:folder.appendingPathComponent("cache.sqlite"),provider:.claude)
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    let initial = try await engine.scanStep(now:now); try expect(initial.usage.tokens.total == 650)
    let live = LiveStatusReader(root:folder,provider:.claude); await live.seed(await engine.sessionMap())
    let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
    var next = try json(["type":"user","sessionId":"c1","timestamp":"2026-11-06T01:02:00Z","message":["content":"synthetic"]]); next.append(10)
    try handle.write(contentsOf:next); try handle.close()
    let observed = await live.update(paths:[file.path],now:now)
    try expect(observed.first?.status == .running)
    let unchanged = try await engine.snapshot(now:now)
    try expect(unchanged.usage.tokens.total == 650)
    try expect(unchanged.sessions.first?.status == .idle)
}

func codexLiveStatusKeepsLifecycleAcrossLargeWrites() async throws {
    for terminal in [false, true] {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let dir = folder.appendingPathComponent("sessions/2026/11/09")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-session.jsonl")
        var initial = try meta("large-write"); initial.append(10); try initial.write(to: file)
        let now = Date()
        var baseline = SessionRecord(id: "large-write", status: terminal ? .running : .idle, observedAt: now.addingTimeInterval(-2))
        baseline.projectDirectory = "/synthetic/project"
        let live = LiveStatusReader(root: folder, provider: .codex)
        await live.seed([file.path: baseline])
        var append = try json(["type": "event_msg", "timestamp": now.ISO8601Format(), "payload": ["type": terminal ? "task_complete" : "task_started"]]); append.append(10)
        append.append(try json(["type": "synthetic_padding", "payload": ["text": String(repeating: "x", count: 100_000)]])); append.append(10)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
        let result = await live.update(paths: [file.path], now: now)
        try expect(result.first?.status == (terminal ? .idle : .running))
    }
}

func liveDirectoryEventsDiscoverNewSessions() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let dir = folder.appendingPathComponent("sessions/2026/11/09")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("new.jsonl")
    var content = try meta("directory-event"); content.append(10)
    content.append(try json(["type": "event_msg", "timestamp": Date().ISO8601Format(), "payload": ["type": "task_started"]])); content.append(10)
    try content.write(to: file)
    let live = LiveStatusReader(root: folder, provider: .codex)
    let result = await live.update(paths: [dir.path])
    try expect(result.first?.id == "directory-event" && result.first?.status == .running)
}

func liveCursorsDrainBurstsAndPreservePartialLines() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let dir = folder.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("burst.jsonl")
    var initial = try meta("burst"); initial.append(10); try initial.write(to: file)
    let engine = try CodexIndex(root: folder, database: folder.appendingPathComponent("index.sqlite"))
    _ = try await engine.scanStep()
    let live = LiveStatusReader(root: folder, provider: .codex)
    await live.seedSources(await engine.liveStatusSeeds())
    let start = Date()
    var append = try json(["type": "event_msg", "timestamp": start.ISO8601Format(), "payload": ["type": "task_started"]]); append.append(10)
    for _ in 0..<6 {
        append.append(try json(["type": "synthetic_padding", "payload": ["text": String(repeating: "x", count: 500_000)]])); append.append(10)
    }
    let ended = try json(["type": "event_msg", "timestamp": start.addingTimeInterval(1).ISO8601Format(), "payload": ["type": "task_complete"]])
    append.append(ended) // Intentionally unfinished JSONL record.
    var handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
    var result = await live.update(paths: [file.path], now: start.addingTimeInterval(2))
    for _ in 0..<10 { if !(await live.hasPendingUpdates) { break }; result = await live.update(paths: [], now: start.addingTimeInterval(2)) }
    let pending = await live.hasPendingUpdates; try expect(!pending); try expect(result.first?.status == .running)
    // An hourly snapshot cannot rewind the live cursor to its earlier EOF.
    await live.seedSources(await engine.liveStatusSeeds())
    handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
    result = await live.update(paths: [file.path], now: start.addingTimeInterval(2))
    try expect(result.first?.status == .idle)
    let usage = try await engine.snapshot().usage.tokens.total; try expect(usage == 0)
}

func liveDiscoveryDrainsAllFilesAndResetsReplacedLogs() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let dir = folder.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    for i in 0..<37 {
        var content = try meta("session-\(i)"); content.append(10)
        content.append(try json(["type": "event_msg", "timestamp": now.ISO8601Format(), "payload": ["type": "task_started"]])); content.append(10)
        try content.write(to: dir.appendingPathComponent("\(i).jsonl"))
    }
    let live = LiveStatusReader(root: folder, provider: .codex)
    var result = await live.update(paths: [folder.path], now: now)
    for _ in 0..<10 { if !(await live.hasPendingUpdates) { break }; result = await live.update(paths: [], now: now) }
    try expect(result.count == 37); let pending = await live.hasPendingUpdates; try expect(!pending)
    let file = dir.appendingPathComponent("0.jsonl")
    var replacement = try meta("replacement"); replacement.append(10)
    replacement.append(try json(["type": "event_msg", "timestamp": now.ISO8601Format(), "payload": ["type": "task_complete"]])); replacement.append(10)
    try replacement.write(to: file, options: .atomic)
    result = await live.update(paths: [file.path], now: now)
    try expect(result.contains { $0.id == "replacement" && $0.status == .idle })
    try expect(!result.contains { $0.id == "session-0" })
}

func sessionMergingKeepsFreshLiveEvidence() throws {
    let now = Date()
    let stale = SessionRecord(id: "same", status: .idle, observedAt: now.addingTimeInterval(-60))
    let fresh = SessionRecord(id: "same", status: .running, observedAt: now)
    let other = SessionRecord(id: "new-session", status: .running, observedAt: now)
    let result = SessionRecord.latest([fresh, other, stale], now: now)
    try expect(result.count == 2); try expect(result.first { $0.id == "same" }?.status == .running)
}

private actor ObservedFileEvents {
    private var pending: Set<String> = []
    func add(_ paths: [String]) { pending.formUnion(paths) }
    func take() -> [String] { let paths = Array(pending); pending.removeAll(); return paths }
}

func nativeFileEventsReachLiveStatusReader() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let events = ObservedFileEvents()
    let watcher = try SourceWatcher(root: folder) { paths in Task { await events.add(paths) } }
    defer { watcher.stop() }
    let dir = folder.appendingPathComponent("sessions/2026/11/09")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var content = try meta("native-event"); content.append(10)
    content.append(try json(["type": "event_msg", "timestamp": Date().ISO8601Format(), "payload": ["type": "task_started"]])); content.append(10)
    try content.write(to: dir.appendingPathComponent("native.jsonl"))
    let live = LiveStatusReader(root: folder, provider: .codex)
    for _ in 0..<60 {
        let paths = await events.take()
        let observed = await live.update(paths: paths)
        if observed.contains(where: { $0.id == "native-event" && $0.status == .running }) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CheckFailure("Native filesystem events did not reach the live session reader")
}

func skippedLiveRecordsRemainUnknown() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let dir = folder.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("oversized.jsonl")
    var initial = try meta("oversized"); initial.append(10); try initial.write(to: file)
    let engine = try CodexIndex(root: folder, database: folder.appendingPathComponent("index.sqlite"))
    _ = try await engine.scanStep()
    let live = LiveStatusReader(root: folder, provider: .codex)
    await live.seedSources(await engine.liveStatusSeeds())
    let now = Date()
    var append = try json(["type": "event_msg", "timestamp": now.ISO8601Format(), "payload": ["type": "task_started"]]); append.append(10)
    append.append(try json(["type": "event_msg", "timestamp": now.addingTimeInterval(1).ISO8601Format(), "payload": ["type": "task_complete", "last_agent_message": String(repeating: "x", count: 1_100_000)]])); append.append(10)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
    var result = await live.update(paths: [file.path], now: now.addingTimeInterval(2))
    try expect(result.first?.status == .unknown)
    // The usage reader accepts up to 2 MiB per line and can safely refine the
    // exact same cursor once it has decoded the previously skipped completion.
    _ = try await engine.scanStep(now: now.addingTimeInterval(2))
    await live.seedSources(await engine.liveStatusSeeds())
    result = await live.update(paths: [], now: now.addingTimeInterval(2))
    try expect(result.first?.status == .idle)
}

func completionTrackerSeedsWithoutHistoricalNotifications() throws {
    let now = Date(); var tracker = ActivityTracker()
    let idle = SessionRecord(id:"old",status:.idle,observedAt:now)
    let seed = tracker.ingest([idle],bootstrapping:false,now:now)
    try expect(seed.completed == 0); try expect(seed.unread == 0)
    let active = SessionRecord(id:"new",status:.running,observedAt:now.addingTimeInterval(1))
    let began = tracker.ingest([idle,active],bootstrapping:false,now:now.addingTimeInterval(1))
    try expect(began.started); try expect(began.mode == .working)
}
func completionTrackerKeepsOtherWorkAndAcknowledgesUnread() throws {
    let now = Date(); var tracker = ActivityTracker()
    let a = SessionRecord(id:"a",status:.running,observedAt:now)
    let b = SessionRecord(id:"b",status:.tool,observedAt:now)
    _ = tracker.ingest([a,b],bootstrapping:false,now:now)
    var ended = a; ended.status = .idle; ended.observedAt = now.addingTimeInterval(1)
    let partial = tracker.ingest([ended,b],bootstrapping:false,now:now.addingTimeInterval(1))
    try expect(partial.completed == 1); try expect(partial.mode == .working); try expect(partial.unread == 1)
    let duplicate = tracker.ingest([ended,b],bootstrapping:false,now:now.addingTimeInterval(2))
    try expect(duplicate.completed == 0); try expect(duplicate.unread == 1)
    var endedB = b; endedB.status = .idle; endedB.observedAt = now.addingTimeInterval(3)
    let done = tracker.ingest([ended,endedB],bootstrapping:false,now:now.addingTimeInterval(3))
    try expect(done.mode == .completed); try expect(done.unread == 2)
    let ack = tracker.acknowledge(now:now.addingTimeInterval(4)); try expect(ack.unread == 0); try expect(ack.mode == .idle)
    _ = tracker.ingest([a,b],bootstrapping:false,now:now.addingTimeInterval(5))
    try expect(tracker.current(now:now.addingTimeInterval(5)).mode == .idle)
}
func completionTrackerDistinguishesFailureAndRestoresUnread() throws {
    let now = Date(); var tracker = ActivityTracker()
    let active = SessionRecord(id:"a",status:.running,observedAt:now)
    _ = tracker.ingest([active],bootstrapping:false,now:now)
    var failed = active; failed.status = .error; failed.observedAt = now.addingTimeInterval(1)
    let error = tracker.ingest([failed],bootstrapping:false,now:now.addingTimeInterval(1))
    try expect(error.completed == 0); try expect(error.mode == .attention)
    var receipts = CompletionReceipts(); receipts.unread = 2
    var restored = ActivityTracker(receipts:receipts)
    let cold = restored.ingest([],bootstrapping:true,now:now); try expect(cold.mode == .completed)
    let ready = restored.ingest([],bootstrapping:false,now:now); try expect(ready.mode == .completed); try expect(ready.unread == 2)
}

func staleOrUnknownEvidenceShowsIdleIcon() throws {
    let now = Date(); var tracker = ActivityTracker()
    let cold = tracker.ingest([SessionRecord(id: "boot", status: .running, observedAt: now)], bootstrapping: true, now: now)
    try expect(cold.mode == .working); try expect(cold.active == 1)
    let stale = SessionRecord(id: "stale", status: .running, observedAt: now.addingTimeInterval(-600))
    let unknown = SessionRecord(id: "unknown", status: .unknown, observedAt: now)
    var fresh = ActivityTracker()
    let update = fresh.ingest([stale, unknown], bootstrapping: false, now: now)
    try expect(update.mode == .idle); try expect(update.active == 0); try expect(update.attention == 0)
}
func workingCountExcludesWaitingAndStaleSessions() throws {
    let now = Date(); var tracker = ActivityTracker()
    let states: [SessionStatus] = [.running, .tool, .waitingInput, .waitingApproval, .idle, .unknown, .error]
    var sessions = states.enumerated().map { SessionRecord(id: "count-\($0.offset)", status: $0.element, observedAt: now) }
    sessions.append(SessionRecord(id: "stale", status: .running, observedAt: now.addingTimeInterval(-181)))
    let current = tracker.ingest(sessions, bootstrapping: false, now: now)
    try expect(current.active == 2); try expect(current.attention == 3)
    try expect(tracker.current(now: now.addingTimeInterval(181)).active == 0)
    sessions[2].status = .running; sessions[2].observedAt = now.addingTimeInterval(1)
    let resumed = tracker.ingest(sessions, bootstrapping: false, now: now.addingTimeInterval(1))
    try expect(resumed.started); try expect(resumed.active == 3)
    sessions[1].status = .idle; sessions[1].observedAt = now.addingTimeInterval(2)
    let done = tracker.ingest(sessions, bootstrapping: false, now: now.addingTimeInterval(2))
    try expect(done.active == 2); try expect(done.completed == 1); try expect(done.unread == 1)
}

func historyBucketsUseLocalMidnightAndCachedLedger() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
    let sessions = folder.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
    let file = sessions.appendingPathComponent("test.jsonl")
    var data = try meta(); data.append(10)
    data.append(try tokens(last:false,time:"2026-11-05T15:59:00Z")); data.append(10)
    data.append(try tokens(input:200,output:20,last:false,time:"2026-11-05T16:00:00Z")); data.append(10)
    try data.write(to:file)
    let index = try CodexIndex(root:folder,database:folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    _ = try await index.scanStep(now:now)
    var shanghai = Calendar(identifier:.gregorian); shanghai.timeZone = TimeZone(identifier:"Asia/Shanghai")!
    var utc = shanghai; utc.timeZone = TimeZone(secondsFromGMT:0)!
    let local = try await index.history(year:2026,calendar:shanghai,now:now)
    try expect(local.days.count == 2); try expect(local.days.allSatisfy { $0.tokens.total == 110 })
    let universal = try await index.history(year:2026,calendar:utc,now:now)
    try expect(universal.days.count == 1); try expect(universal.days[0].tokens.total == 220)
    let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
    var appended = try tokens(input:300,output:30,last:false,time:"2026-11-06T01:00:00Z"); appended.append(10)
    try handle.write(contentsOf:appended); try handle.close()
    let cached = try await index.history(year:2026,calendar:utc,now:now)
    try expect(cached.days.reduce(0) { $0 + $1.tokens.total } == 220)
    await index.invalidate(); _ = try await index.scanStep(now:now)
    let refreshed = try await index.history(year:2026,calendar:utc,now:now)
    try expect(refreshed.days.reduce(0) { $0 + $1.tokens.total } == 330)
}
func historyHandlesRepeatedDSTHour() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let sessions = folder.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
    var data = try meta(); data.append(10)
    data.append(try tokens(last:false,time:"2026-11-01T05:30:00Z")); data.append(10)
    data.append(try tokens(input:200,output:20,last:false,time:"2026-11-01T06:30:00Z")); data.append(10)
    try data.write(to:sessions.appendingPathComponent("test.jsonl"))
    let index = try CodexIndex(root:folder,database:folder.appendingPathComponent("cache.sqlite"))
    let now = try require(parseTimestamp("2026-11-02T12:00:00Z")); _ = try await index.scanStep(now:now)
    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"America/New_York")!
    let history = try await index.history(year:2026,calendar:calendar,now:now)
    try expect(history.days.count == 1); try expect(history.days[0].tokens.total == 220)
    try expect(calendar.component(.day,from:history.days[0].date) == 1)
}
func heatmapIncludesLeapDayAndSeparatesFuture() throws {
    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z"))
    let leap = UsageHeatmap(year:2012,days:[],calendar:calendar,now:now)
    try expect(leap.cells.count == 366); try expect(leap.weeks == 54); try expect(leap.cells.first?.weekday == 6)
    try expect(leap.cells.filter { calendar.component(.month,from:$0.date)==2 && calendar.component(.day,from:$0.date)==29 }.count == 1)
    var a = UsageDay(date:try require(parseTimestamp("2026-11-06T01:00:00Z")))
    a.add(TokenUsage(input:1000,cached:800,output:200,reasoning:100),model:"codex")
    var b = UsageDay(date:try require(parseTimestamp("2026-11-06T01:30:00Z")))
    b.add(TokenUsage(input:1100,cached:800,cacheWrite:100,output:200),model:"claude")
    var future = UsageDay(date:try require(parseTimestamp("2026-11-07T01:00:00Z")))
    future.add(TokenUsage(input:9999,output:1))
    let map = UsageHeatmap(year:2026,days:[a,b,future],calendar:calendar,now:now)
    try expect(map.total == 2500); try expect(map.activeDays == 1); try expect(map.peak == 2500)
    let today = try require(map.cells.first { calendar.isDate($0.date,inSameDayAs:now) })
    try expect(today.usage.tokens.total == 2500); try expect(today.level == 4)
    try expect(map.cells.filter(\.future).allSatisfy { $0.usage.tokens.total == 0 && $0.level == 0 })
}

func claudeProjectStaysAnchoredWhenDirectoryChanges() throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let project = folder.appendingPathComponent("stable-project")
    try FileManager.default.createDirectory(at:project.appendingPathComponent("src"),withIntermediateDirectories:true)
    // Worktrees also use a .git file instead of a directory.
    try Data("gitdir: /synthetic/main/.git/worktrees/example".utf8).write(to:project.appendingPathComponent(".git"))
    var parser = ClaudeParser(fileID:"session")
    func record(_ cwd: String, _ time: String) throws -> Data { try json(["type":"user","sessionId":"session","cwd":cwd,"timestamp":time,"message":["content":"synthetic"]]) }
    _ = parser.consume(try record(project.appendingPathComponent("src").path,"2026-11-06T01:00:00Z"),offset:0)
    try expect(parser.state.session.project == "stable-project")
    let key = parser.state.session.key
    _ = parser.consume(try record(project.appendingPathComponent("functions").path,"2026-11-06T01:01:00Z"),offset:1)
    _ = parser.consume(try record(folder.appendingPathComponent("another-project").path,"2026-11-06T01:02:00Z"),offset:2)
    try expect(parser.state.session.project == "stable-project")
    try expect(parser.state.session.projectDirectory == project.path)
    try expect(parser.state.session.directory == folder.appendingPathComponent("another-project").path)
    try expect(parser.state.session.key == key)
    _ = parser.consume(try record(project.appendingPathComponent("src").path,"2026-11-06T01:00:00Z"),offset:3)
    try expect(parser.state.session.directory == folder.appendingPathComponent("another-project").path)
}
func cachedProjectMetadataRecoversFromInitialDirectory() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let projects = folder.appendingPathComponent("projects/p"); try FileManager.default.createDirectory(at:projects,withIntermediateDirectories:true)
    let initial = folder.appendingPathComponent("original-project")
    let moved = folder.appendingPathComponent("other-project/functions")
    let file = projects.appendingPathComponent("session.jsonl")
    var data = try json(["type":"user","sessionId":"session","cwd":initial.path,"timestamp":"2026-11-06T01:00:00Z","message":["content":"synthetic"]]); data.append(10)
    data.append(try json(["type":"user","sessionId":"session","cwd":moved.path,"timestamp":"2026-11-06T01:01:00Z","message":["content":"synthetic"]])); data.append(10)
    try data.write(to:file)
    let last = try require(parseTimestamp("2026-11-06T01:01:00Z"))
    var legacy = SessionRecord(id:"session",project:"functions",directory:moved.path,status:.running,observedAt:last)
    legacy.provider = .claude
    // Existing cache JSON has no new optional metadata fields.
    var object = try require(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as? [String:Any])
    object.removeValue(forKey:"projectDirectory"); object.removeValue(forKey:"directoryObservedAt")
    let decoded = try JSONDecoder().decode(SessionRecord.self,from:json(object))
    let restored = SessionProject.restoring(decoded,from:file,provider:.claude)
    try expect(restored.project == "original-project")
    try expect(restored.directory == moved.path)
    try expect(restored.status == .running && restored.observedAt == last)
    let reader = LiveStatusReader(root:folder,provider:.claude); await reader.seed([file.path:legacy])
    let result = await reader.update(paths:[file.path],now:last)
    try expect(result.first?.project == "original-project")
    try expect(result.first?.directory == moved.path)
}
func projectAnchorSurvivesIndexRestart() async throws {
    let folder = try temporary(); defer { try? FileManager.default.removeItem(at:folder) }
    let logs = folder.appendingPathComponent("projects/p"); try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
    let file = logs.appendingPathComponent("c1.jsonl")
    var row = try claudeRow(output:50,final:true); row.append(10); try row.write(to:file)
    let database = folder.appendingPathComponent("cache.sqlite")
    let index = try CodexIndex(root:folder,database:database,provider:.claude)
    let now = try require(parseTimestamp("2026-11-06T02:00:00Z")); let first = try await index.scanStep(now:now)
    let project = try require(first.sessions.first?.project)
    let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
    var change = try json(["type":"user","sessionId":"c1","cwd":"/synthetic/other/functions","timestamp":"2026-11-06T01:02:00Z","message":["content":"synthetic"]]); change.append(10)
    try handle.write(contentsOf:change); try handle.close()
    let restarted = try CodexIndex(root:folder,database:database,provider:.claude)
    let next = try await restarted.scanStep(now:now)
    try expect(next.sessions.first?.project == project)
    try expect(next.sessions.first?.directory == "/synthetic/other/functions")
    try expect(next.usage.tokens.total == first.usage.tokens.total)
}

private struct CheckFailure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
private func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard try condition() else { throw CheckFailure("Expected condition failed at \(file):\(line)") }
}
private func expectAsync(_ condition: () async throws -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
    guard try await condition() else { throw CheckFailure("Expected async condition failed at \(file):\(line)") }
}
private func require<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure("Required value is nil") }; return value }
private func expectThrows(_ work: () throws -> Any) throws {
    do { _ = try work() } catch is QuotaFailure { return }
    throw CheckFailure("Expected QuotaFailure")
}
func claudeQuotaWindowsAndBilling() throws {
    let data = try json(["five_hour": ["utilization": 25.5, "resets_at": "2026-11-06T10:00:00Z"],
                         "seven_day": ["utilization": 70], "seven_day_opus": ["utilization": 101],
                         "extra_usage": ["is_enabled": true, "used_credits": 1250, "monthly_limit": 5000]])
    let value = try ClaudeQuotaDecoder.decode(data, binding: "synthetic")
    try expect(value.windows.count == 3)
    try expect(value.windows[0].remainingPercent == 74 && value.windows[0].resetsAt != nil)
    try expect(value.windows[1].remainingPercent == 30 && value.windows[2].remainingPercent == 0)
    let billing = try require(value.claudeBilling)
    try expect(billing.remainingBudget?.amount == 37.5)
    try expect(billing.spent?.amount == 12.5 && billing.spent?.currency == "USD")
    try expect(value.creditBalance == nil && !value.unlimitedCredits)
    try expect(try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(value)) == value)
}
func claudeQuotaMissingValuesStayUnknown() throws {
    let value = try ClaudeQuotaDecoder.decode(json(["five_hour": ["utilization": true], "seven_day": NSNull(),
        "extra_usage": ["is_enabled": true, "used_credits": NSNull(), "monthly_limit": NSNull()]]), binding: "synthetic")
    try expect(value.windows.isEmpty)
    try expect(value.claudeBilling?.remainingBudget == nil)
    try expect(value.claudeBilling?.spent == nil)
    try expectThrows { try ClaudeQuotaDecoder.decode(json(["seven_day": ["utilization": -2]]), binding: "synthetic") }
    try expectThrows { try ClaudeQuotaDecoder.decode(Data("[]".utf8), binding: "synthetic") }
    try expectThrows { try ClaudeQuotaDecoder.decode(Data(repeating: 32, count: 1024 * 1024 + 1), binding: "synthetic") }
}
func claudeBillingDisabledAndUnsupportedCurrency() throws {
    let disabled = try ClaudeQuotaDecoder.decode(json(["extra_usage": ["is_enabled": false]]), binding: "synthetic")
    try expect(disabled.claudeBilling?.enabled == false && disabled.claudeBilling?.remainingBudget == nil)
    let other = try ClaudeQuotaDecoder.decode(json(["extra_usage": ["is_enabled": true, "currency": "JPY", "used_credits": 100, "monthly_limit": 500]]), binding: "synthetic")
    try expect(other.claudeBilling?.spent?.currency == "JPY")
    let legacy = try JSONDecoder().decode(QuotaSnapshot.self, from: json(["binding": "synthetic", "capturedAt": 0, "windows": [], "unlimitedCredits": false]))
    try expect(legacy.claudeBilling == nil)
    try expect(QuotaFailure(.noCredentials).message(for: .claude).contains("Claude"))
    try expect(QuotaFailure(.credentialAccess).invalidatesSnapshot)
}

func claudeClientCachesAndInvalidatesCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credential = directory.appendingPathComponent("synthetic.json")
    let cache = directory.appendingPathComponent("quota.json")
    try json(["claudeAiOauth": ["accessToken": "synthetic-only", "expiresAt": 4102444800000]]).write(to: credential)
    let client = ClaudeQuotaClient(root: directory, cacheFile: cache, transport: { request in
        guard request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage",
              request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20" else { throw CheckFailure("Unexpected endpoint") }
        return (try json(["seven_day": ["utilization": 20]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, credentialData: { try Data(contentsOf: credential) })
    let value = try await client.refresh()
    try expect(value.windows.first?.remainingPercent == 80)
    try await expectAsync { await client.lastKnown() == value }
    let persisted = try String(contentsOf: cache, encoding: .utf8)
    try expect(!persisted.contains("synthetic-only") && !persisted.contains("accessToken"))
    try json(["claudeAiOauth": ["accessToken": "changed-account", "expiresAt": 4102444800000]]).write(to: credential)
    try await expectAsync { await client.lastKnown() == nil }
    try json(["claudeAiOauth": ["accessToken": "", "expiresAt": 0]]).write(to: credential)
    do { _ = try await client.refresh(); throw CheckFailure("Empty credential accepted") }
    catch let failure as QuotaFailure { try expect(failure.code == .noCredentials) }
    // Stored expiry is advisory; the server is authoritative (matching Orca).
    try json(["claudeAiOauth": ["accessToken": "expired", "expiresAt": 1]]).write(to: credential)
    let advisory = try await client.refresh()
    try expect(advisory.windows.first?.remainingPercent == 80)
}
func claudeClientHandlesAuthorizationAndRateLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try json(["claudeAiOauth": ["accessToken": "synthetic-only", "expiresAt": 4102444800000]])
    for (status, code) in [(401, QuotaFailure.Code.authorization), (403, .missingScope), (429, .rateLimited), (500, .server)] {
        let client = ClaudeQuotaClient(root: directory, cacheFile: directory.appendingPathComponent("quota.json"), transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }, credentialData: { data })
        do { _ = try await client.refresh(); throw CheckFailure("HTTP failure accepted") }
        catch let failure as QuotaFailure {
            try expect(failure.code == code)
            if status == 429 { try expect(failure.retryAt != nil) }
        }
        if status == 429 {
            do { _ = try await client.refresh(manual: true); throw CheckFailure("Rate limit bypassed") }
            catch let failure as QuotaFailure { try expect(failure.code == .rateLimited) }
        }
    }
}

func claudeKeychainOutputDecodes() throws {
    let plain = try require(ClaudeQuotaDecoder.keychainPayload(Data("{\"claudeAiOauth\":{}}\n".utf8)))
    try expect(String(decoding: plain, as: UTF8.self) == "{\"claudeAiOauth\":{}}")
    let hex = try require(ClaudeQuotaDecoder.keychainPayload(Data("7b7d\n".utf8)))
    try expect(String(decoding: hex, as: UTF8.self) == "{}")
    try expect(ClaudeQuotaDecoder.keychainPayload(Data("\n".utf8)) == nil)
    try expect(ClaudeQuotaDecoder.keychainPayload(Data("not-json".utf8)) == nil)
}

func claudeModernSpendAndWindowFormats() throws {
    let value = try ClaudeQuotaDecoder.decode(json([
        "five_hour": ["used_percentage": 10, "resets_at": 1793952000],
        "seven_day": ["utilization": 20, "resets_at": "1793952000000"],
        "limits": [["kind": "weekly_scoped", "percent": 40, "scope": ["model": ["display_name": "Fable"]]]],
        "spend": ["enabled": true, "used": ["amount_minor": 12345, "exponent": 3, "currency": "USD"],
                  "cap": ["money": ["amount_minor": 50000, "exponent": 3, "currency": "USD"]],
                  "balance": ["amount_minor": 900, "exponent": 2, "currency": "USD"]],
        "extra_usage": ["is_enabled": true, "used_credits": 1, "monthly_limit": 2]
    ]), binding: "synthetic")
    try expect(value.windows.count == 3 && value.windows[0].resetsAt == value.windows[1].resetsAt)
    try expect(value.windows[2].name == "Fable")
    try expect(value.claudeBilling?.spent?.amount == 12.345 && value.claudeBilling?.limit?.amount == 50)
    try expect(value.claudeBilling?.balance?.amount == 9)
    let legacy = try ClaudeQuotaDecoder.decode(json(["extra_usage": ["is_enabled": true, "currency": "JPY", "decimal_places": 0, "used_credits": 100, "monthly_limit": 500]]), binding: "synthetic")
    try expect(legacy.claudeBilling?.spent?.amount == 100)
    let mixed = try ClaudeQuotaDecoder.decode(json(["spend": ["enabled": true, "used": ["amount_minor": 100, "currency": "USD"], "limit": ["amount_minor": 200, "currency": "EUR"]]]), binding: "synthetic")
    try expect(mixed.claudeBilling?.remainingBudget == nil)
    let invalid = try ClaudeQuotaDecoder.decode(json(["extra_usage": ["is_enabled": true, "decimal_places": -1, "used_credits": 100]]), binding: "synthetic")
    try expect(invalid.claudeBilling?.spent == nil)
}

@main struct Checks {
    static func main() async {
        var failures = 0
        do { try await skippedLiveRecordsRemainUnknown(); print("PASS skippedLiveRecordsRemainUnknown") } catch { failures += 1; print("FAIL skippedLiveRecordsRemainUnknown: \(error)") }
        let nativeEvents = CommandLine.arguments.contains("--native-file-events")
        if nativeEvents {
            do { try await nativeFileEventsReachLiveStatusReader(); print("PASS nativeFileEventsReachLiveStatusReader") } catch { failures += 1; print("FAIL nativeFileEventsReachLiveStatusReader: \(error)") }
        }
        do { try await liveCursorsDrainBurstsAndPreservePartialLines(); print("PASS liveCursorsDrainBurstsAndPreservePartialLines") } catch { failures += 1; print("FAIL liveCursorsDrainBurstsAndPreservePartialLines: \(error)") }
        do { try await liveDiscoveryDrainsAllFilesAndResetsReplacedLogs(); print("PASS liveDiscoveryDrainsAllFilesAndResetsReplacedLogs") } catch { failures += 1; print("FAIL liveDiscoveryDrainsAllFilesAndResetsReplacedLogs: \(error)") }
        do { try sessionMergingKeepsFreshLiveEvidence(); print("PASS sessionMergingKeepsFreshLiveEvidence") } catch { failures += 1; print("FAIL sessionMergingKeepsFreshLiveEvidence: \(error)") }
        do { try await codexLiveStatusKeepsLifecycleAcrossLargeWrites(); print("PASS codexLiveStatusKeepsLifecycleAcrossLargeWrites") } catch { failures += 1; print("FAIL codexLiveStatusKeepsLifecycleAcrossLargeWrites: \(error)") }
        do { try await liveDirectoryEventsDiscoverNewSessions(); print("PASS liveDirectoryEventsDiscoverNewSessions") } catch { failures += 1; print("FAIL liveDirectoryEventsDiscoverNewSessions: \(error)") }
        do { try claudeKeychainOutputDecodes(); print("PASS claudeKeychainOutputDecodes") } catch { failures += 1; print("FAIL claudeKeychainOutputDecodes: \(error)") }
        do { try claudeModernSpendAndWindowFormats(); print("PASS claudeModernSpendAndWindowFormats") } catch { failures += 1; print("FAIL claudeModernSpendAndWindowFormats: \(error)") }
        do { try await claudeClientCachesAndInvalidatesCredentials(); print("PASS claudeClientCachesAndInvalidatesCredentials") } catch { failures += 1; print("FAIL claudeClientCachesAndInvalidatesCredentials: \(error)") }
        do { try await claudeClientHandlesAuthorizationAndRateLimit(); print("PASS claudeClientHandlesAuthorizationAndRateLimit") } catch { failures += 1; print("FAIL claudeClientHandlesAuthorizationAndRateLimit: \(error)") }
        do { try claudeQuotaWindowsAndBilling(); print("PASS claudeQuotaWindowsAndBilling") } catch { failures += 1; print("FAIL claudeQuotaWindowsAndBilling: \(error)") }
        do { try claudeQuotaMissingValuesStayUnknown(); print("PASS claudeQuotaMissingValuesStayUnknown") } catch { failures += 1; print("FAIL claudeQuotaMissingValuesStayUnknown: \(error)") }
        do { try claudeBillingDisabledAndUnsupportedCurrency(); print("PASS claudeBillingDisabledAndUnsupportedCurrency") } catch { failures += 1; print("FAIL claudeBillingDisabledAndUnsupportedCurrency: \(error)") }
        do { try cachedAndReasoningAreSubsets(); print("PASS cachedAndReasoningAreSubsets") } catch { failures += 1; print("FAIL cachedAndReasoningAreSubsets: \(error)") }
        do { try timestampSupportsWholeAndFractionalSeconds(); print("PASS timestampSupportsWholeAndFractionalSeconds") } catch { failures += 1; print("FAIL timestampSupportsWholeAndFractionalSeconds: \(error)") }
        do { try cumulativeRepetitionDoesNotChargeAgain(); print("PASS cumulativeRepetitionDoesNotChargeAgain") } catch { failures += 1; print("FAIL cumulativeRepetitionDoesNotChargeAgain: \(error)") }
        do { try cumulativeOnlyEventsProduceDeltas(); print("PASS cumulativeOnlyEventsProduceDeltas") } catch { failures += 1; print("FAIL cumulativeOnlyEventsProduceDeltas: \(error)") }
        do { try counterResetCanUseRecordedRequestDelta(); print("PASS counterResetCanUseRecordedRequestDelta") } catch { failures += 1; print("FAIL counterResetCanUseRecordedRequestDelta: \(error)") }
        do { try unpairedRequestRecordsAreNotDoubleCounted(); print("PASS unpairedRequestRecordsAreNotDoubleCounted") } catch { failures += 1; print("FAIL unpairedRequestRecordsAreNotDoubleCounted: \(error)") }
        do { try remoteCompactionWorksInEitherRecordOrder(); print("PASS remoteCompactionWorksInEitherRecordOrder") } catch { failures += 1; print("FAIL remoteCompactionWorksInEitherRecordOrder: \(error)") }
        do { try localCompactionLateAdvanceRetractsExtraRecord(); print("PASS localCompactionLateAdvanceRetractsExtraRecord") } catch { failures += 1; print("FAIL localCompactionLateAdvanceRetractsExtraRecord: \(error)") }
        do { try partialLineWaitsForNewline(); print("PASS partialLineWaitsForNewline") } catch { failures += 1; print("FAIL partialLineWaitsForNewline: \(error)") }
        do { try oversizedLineTailCannotBecomeARecord(); print("PASS oversizedLineTailCannotBecomeARecord") } catch { failures += 1; print("FAIL oversizedLineTailCannotBecomeARecord: \(error)") }
        do { try quotaWindowIsDataDrivenAndInvalidSiblingsAreSkipped(); print("PASS quotaWindowIsDataDrivenAndInvalidSiblingsAreSkipped") } catch { failures += 1; print("FAIL quotaWindowIsDataDrivenAndInvalidSiblingsAreSkipped: \(error)") }
        do { try missingQuotaNeverMeansZeroOrAnotherAccount(); print("PASS missingQuotaNeverMeansZeroOrAnotherAccount") } catch { failures += 1; print("FAIL missingQuotaNeverMeansZeroOrAnotherAccount: \(error)") }
        do { try await persistedIndexSurvivesRestartAndTruncation(); print("PASS persistedIndexSurvivesRestartAndTruncation") } catch { failures += 1; print("FAIL persistedIndexSurvivesRestartAndTruncation: \(error)") }
        do { try await forkReplayIsExcludedButOwnRequestsRemain(); print("PASS forkReplayIsExcludedButOwnRequestsRemain") } catch { failures += 1; print("FAIL forkReplayIsExcludedButOwnRequestsRemain: \(error)") }
        do { try await compactionCopiesKeepOriginalSpendDay(); print("PASS compactionCopiesKeepOriginalSpendDay") } catch { failures += 1; print("FAIL compactionCopiesKeepOriginalSpendDay: \(error)") }
        do { try await archivedCopyDoesNotDoubleCountSession(); print("PASS archivedCopyDoesNotDoubleCountSession") } catch { failures += 1; print("FAIL archivedCopyDoesNotDoubleCountSession: \(error)") }
        do { try claudeCacheAccountingAndIdentity(); print("PASS claudeCacheAccountingAndIdentity") } catch { failures += 1; print("FAIL claudeCacheAccountingAndIdentity: \(error)") }
        do { try await claudeStreamUpdatesAndCrossFileCopies(); print("PASS claudeStreamUpdatesAndCrossFileCopies") } catch { failures += 1; print("FAIL claudeStreamUpdatesAndCrossFileCopies: \(error)") }
        do { try claudeQuestionLifecycleAndBookkeeping(); print("PASS claudeQuestionLifecycleAndBookkeeping") } catch { failures += 1; print("FAIL claudeQuestionLifecycleAndBookkeeping: \(error)") }
        do { try await liveStatusUpdatesWithoutRefreshingUsage(); print("PASS liveStatusUpdatesWithoutRefreshingUsage") } catch { failures += 1; print("FAIL liveStatusUpdatesWithoutRefreshingUsage: \(error)") }
        do { try completionTrackerSeedsWithoutHistoricalNotifications(); print("PASS completionTrackerSeedsWithoutHistoricalNotifications") } catch { failures += 1; print("FAIL completionTrackerSeedsWithoutHistoricalNotifications: \(error)") }
        do { try completionTrackerKeepsOtherWorkAndAcknowledgesUnread(); print("PASS completionTrackerKeepsOtherWorkAndAcknowledgesUnread") } catch { failures += 1; print("FAIL completionTrackerKeepsOtherWorkAndAcknowledgesUnread: \(error)") }
        do { try completionTrackerDistinguishesFailureAndRestoresUnread(); print("PASS completionTrackerDistinguishesFailureAndRestoresUnread") } catch { failures += 1; print("FAIL completionTrackerDistinguishesFailureAndRestoresUnread: \(error)") }
        do { try await historyBucketsUseLocalMidnightAndCachedLedger(); print("PASS historyBucketsUseLocalMidnightAndCachedLedger") } catch { failures += 1; print("FAIL historyBucketsUseLocalMidnightAndCachedLedger: \(error)") }
        do { try await historyHandlesRepeatedDSTHour(); print("PASS historyHandlesRepeatedDSTHour") } catch { failures += 1; print("FAIL historyHandlesRepeatedDSTHour: \(error)") }
        do { try heatmapIncludesLeapDayAndSeparatesFuture(); print("PASS heatmapIncludesLeapDayAndSeparatesFuture") } catch { failures += 1; print("FAIL heatmapIncludesLeapDayAndSeparatesFuture: \(error)") }
        do { try claudeProjectStaysAnchoredWhenDirectoryChanges(); print("PASS claudeProjectStaysAnchoredWhenDirectoryChanges") } catch { failures += 1; print("FAIL claudeProjectStaysAnchoredWhenDirectoryChanges: \(error)") }
        do { try await cachedProjectMetadataRecoversFromInitialDirectory(); print("PASS cachedProjectMetadataRecoversFromInitialDirectory") } catch { failures += 1; print("FAIL cachedProjectMetadataRecoversFromInitialDirectory: \(error)") }
        do { try await projectAnchorSurvivesIndexRestart(); print("PASS projectAnchorSurvivesIndexRestart") } catch { failures += 1; print("FAIL projectAnchorSurvivesIndexRestart: \(error)") }
        do { try staleOrUnknownEvidenceShowsIdleIcon(); print("PASS staleOrUnknownEvidenceShowsIdleIcon") } catch { failures += 1; print("FAIL staleOrUnknownEvidenceShowsIdleIcon: \(error)") }
        do { try workingCountExcludesWaitingAndStaleSessions(); print("PASS workingCountExcludesWaitingAndStaleSessions") } catch { failures += 1; print("FAIL workingCountExcludesWaitingAndStaleSessions: \(error)") }
        print("\(44 + (nativeEvents ? 1 : 0)) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}

import Foundation

public enum ActivityMode: String, Sendable { case idle, working, completed, attention, uncertain }
public struct ActivityUpdate: Sendable {
    public var mode: ActivityMode
    public var active: Int
    public var attention: Int
    public var unread: Int
    public var started: Bool
    public var completed: Int
}
public struct CompletionReceipts: Codable, Sendable {
    public var unread: Int = 0
    public var identifiers: [String] = []
    public init() {}
}

/// Monotonic observations prevent an hourly history refresh from replaying
/// notifications. Launch seeds a baseline; only subsequently observed work
/// ending successfully creates an unread completion.
public struct ActivityTracker: Sendable {
    public private(set) var receipts: CompletionReceipts
    private var observations: [String: SessionRecord] = [:]
    private var initialized = false
    public init(receipts: CompletionReceipts = CompletionReceipts()) {
        self.receipts = receipts
        self.receipts.unread = min(999, max(0, receipts.unread))
        self.receipts.identifiers = Array(receipts.identifiers.suffix(128))
    }
    public mutating func ingest(_ sessions: [SessionRecord], bootstrapping: Bool, now: Date = Date()) -> ActivityUpdate {
        var started = false, completed = 0
        let detect = initialized
        for session in sessions {
            guard session.observedAt <= now.addingTimeInterval(30) else { continue }
            let previous = observations[session.key]
            if let previous, session.observedAt < previous.observedAt { continue }
            if detect {
                if session.status.isWorking, previous?.status.isWorking != true,
                   now.timeIntervalSince(session.observedAt) <= 120 { started = true }
                if session.status == .idle, previous?.status.isActive == true {
                    let id = stableHash(session.key + "|" + String(session.observedAt.timeIntervalSince1970))
                    if !receipts.identifiers.contains(id) {
                        receipts.identifiers.append(id); receipts.identifiers = Array(receipts.identifiers.suffix(128))
                        receipts.unread = min(999, receipts.unread + 1); completed += 1
                    }
                }
            }
            observations[session.key] = session
        }
        observations = observations.filter { $0.value.observedAt > now.addingTimeInterval(-86400) }
        if !bootstrapping { initialized = true }
        var result = current(now: now)
        result.started = started; result.completed = completed
        return result
    }
    public mutating func acknowledge(now: Date = Date()) -> ActivityUpdate {
        receipts.unread = 0
        return current(now: now)
    }
    public func current(now: Date = Date()) -> ActivityUpdate {
        let attention = observations.values.filter { $0.status.needsAttention || ($0.status == .error && now.timeIntervalSince($0.observedAt) < 180) }.count
        let active = observations.values.filter { $0.status.isWorking && now.timeIntervalSince($0.observedAt) < 180 }.count
        let uncertain = observations.values.contains { $0.status == .unknown || ($0.status.isActive && !$0.status.needsAttention && now.timeIntervalSince($0.observedAt) >= 180) }
        let mode: ActivityMode = !initialized ? .uncertain : attention > 0 ? .attention : active > 0 ? .working : receipts.unread > 0 ? .completed : uncertain ? .uncertain : .idle
        return ActivityUpdate(mode: mode, active: active, attention: attention, unread: receipts.unread, started: false, completed: 0)
    }
}

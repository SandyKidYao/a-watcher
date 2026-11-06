import Foundation
import CoreFoundation
import CryptoKit

public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case codex, claude
    public var name: String { self == .codex ? "Codex" : "Claude Code" }
}

public enum SessionStatus: String, Codable, Sendable {
    case running, tool, waitingApproval, waitingInput, idle, interrupted, error, ended, unknown
    public var label: String {
        switch self {
        case .running: "正在工作"
        case .tool: "使用工具"
        case .waitingApproval: "等待批准"
        case .waitingInput: "等待输入"
        case .idle: "本轮完成"
        case .interrupted: "已中断"
        case .error: "发生错误"
        case .ended: "会话已结束"
        case .unknown: "状态待确认"
        }
    }
    public var isActive: Bool { [.running, .tool, .waitingApproval, .waitingInput].contains(self) }
    public var isWorking: Bool { self == .running || self == .tool }
    public var needsAttention: Bool { self == .waitingApproval || self == .waitingInput }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 { input.addingReportingOverflow(output).overflow ? Int64.max : input + output }
    public init(input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input; self.cached = min(cached, input); self.cacheWrite = min(cacheWrite, max(0, input - self.cached))
        self.output = output; self.reasoning = min(reasoning, output)
    }
    static func read(_ object: [String: Any]?) -> TokenUsage? {
        guard let object, let input = integer(object["input_tokens"]), let output = integer(object["output_tokens"]), !input.addingReportingOverflow(output).overflow else { return nil }
        return TokenUsage(input: input, cached: integer(object["cached_input_tokens"]) ?? 0,
                          cacheWrite: integer(object["cache_write_input_tokens"]) ?? integer(object["cache_creation_input_tokens"]) ?? 0,
                          output: output, reasoning: integer(object["reasoning_output_tokens"]) ?? 0)
    }
    func delta(from old: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(0, input - old.input), cached: max(0, cached - old.cached), cacheWrite: max(0, cacheWrite - old.cacheWrite), output: max(0, output - old.output), reasoning: max(0, reasoning - old.reasoning))
    }
    var fingerprint: String { "\(input):\(cached):\(cacheWrite):\(output):\(reasoning)" }
}

public struct UsageRecord: Codable, Sendable, Equatable {
    public var key: String
    public var sessionID: String
    public var ordinal: Int64
    public var timestamp: Date
    public var model: String
    public var tier: String
    public var tokens: TokenUsage
    public var compaction: Bool = false
    public var removal: Bool = false
    public var finalized: Bool = true
}

public struct SessionRecord: Codable, Sendable, Equatable, Identifiable {
    public var provider: AgentProvider = .codex
    public var key: String { provider.rawValue + ":" + id }
    public var id: String
    public var project: String
    public var directory: String
    public var projectDirectory: String?
    public var directoryObservedAt: Date?
    public var model: String
    public var parentID: String?
    public var status: SessionStatus
    public var observedAt: Date
    public var source: String
    public var tool: String?
    public init(id: String = "", project: String = "Codex", directory: String = "", model: String = "unknown", parentID: String? = nil, status: SessionStatus = .unknown, observedAt: Date = .distantPast, source: String = "日志", tool: String? = nil) {
        self.id = id; self.project = project; self.directory = directory; self.model = model; self.parentID = parentID
        self.status = status; self.observedAt = observedAt; self.source = source; self.tool = tool
    }
}

public struct UsageGroup: Sendable, Identifiable {
    public var name: String
    public var tokens: Int64
    public var id: String { name }
}
public struct UsageSummary: Sendable {
    public var tokens = TokenUsage()
    public var byModel: [UsageGroup] = []
    public var byProject: [UsageGroup] = []
    public var records: Int = 0
    public var excludedReplayRecords: Int = 0
    public var skippedLines: Int = 0
    public var unresolvedForks: Int = 0
    public var compressedFiles: Int = 0
    public var incompleteRequests: Int = 0
    public var indexing: Bool = false
    public var filesDone: Int = 0
    public var filesTotal: Int = 0
    public var isPartial: Bool { indexing || skippedLines > 0 || unresolvedForks > 0 || compressedFiles > 0 || incompleteRequests > 0 }
    public init() {}
}
public struct IndexSnapshot: Sendable {
    public var sessions: [SessionRecord] = []
    public var usage = UsageSummary()
    public var error: String?
    public init() {}
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var seconds: Int64?
    public var usedPercent: Double
    public var resetsAt: Date?
    public var remainingPercent: Int { Int(max(0, 100 - usedPercent).rounded(.down)) }
    public var shortLabel: String {
        guard let seconds, seconds > 0 else { return name }
        if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        return "\(seconds / 60)m"
    }
}
public struct QuotaSnapshot: Codable, Sendable, Equatable {
    public var binding: String
    public var capturedAt: Date
    public var windows: [QuotaWindow]
    public var creditBalance: String?
    public var unlimitedCredits: Bool
}

public func stableHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
func integer(_ value: Any?) -> Int64? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    guard d.isFinite, d >= 0, d < Double(Int64.max), d.rounded(.towardZero) == d else { return nil }
    return n.int64Value
}
func percentage(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
    return n.doubleValue
}
public func parseTimestamp(_ text: String?) -> Date? {
    guard let text else { return nil }
    return (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))
        ?? (try? Date(text, strategy: .iso8601))
}

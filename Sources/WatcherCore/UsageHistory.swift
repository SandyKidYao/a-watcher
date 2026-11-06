import Foundation

public struct UsageDay: Sendable, Equatable, Identifiable {
    public var date: Date
    public var tokens = TokenUsage()
    public var records = 0
    public var models: [String: Int64] = [:]
    public var id: Date { date }
    public init(date: Date) { self.date = date }
    public mutating func merge(_ other: UsageDay) {
        add(other.tokens, records: other.records)
        for (name, count) in other.models {
            let sum = (models[name] ?? 0).addingReportingOverflow(count)
            models[name] = sum.overflow ? Int64.max : sum.partialValue
        }
    }
    public mutating func add(_ usage: TokenUsage, records: Int = 1, model: String? = nil) {
        func sum(_ a: Int64, _ b: Int64) -> Int64 { let value = a.addingReportingOverflow(b); return value.overflow ? Int64.max : value.partialValue }
        tokens = TokenUsage(input: sum(tokens.input, usage.input), cached: sum(tokens.cached, usage.cached),
            cacheWrite: sum(tokens.cacheWrite, usage.cacheWrite), output: sum(tokens.output, usage.output), reasoning: sum(tokens.reasoning, usage.reasoning))
        self.records += records
        if let model { models[model] = sum(models[model] ?? 0, usage.total) }
    }
}
public struct UsageHistory: Sendable {
    public var days: [UsageDay] = []
    public var firstRecordedAt: Date?
    public var isPartial = true
    public init() {}
}

public struct HeatmapCell: Sendable, Equatable, Identifiable {
    public var date: Date
    public var week: Int
    public var weekday: Int
    public var level: Int
    public var usage: UsageDay
    public var future: Bool
    public var id: Date { date }
}
public struct UsageHeatmap: Sendable, Equatable {
    public var cells: [HeatmapCell]
    public var weeks: Int
    public var total: Int64
    public var activeDays: Int
    public var peak: Int64
    public init(year: Int, days: [UsageDay], calendar: Calendar, now: Date = Date()) {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else {
            cells = []; weeks = 0; total = 0; activeDays = 0; peak = 0; return
        }
        let offset = (calendar.component(.weekday, from: start) + 5) % 7 // Monday first
        let today = calendar.startOfDay(for: now)
        let indexed = Dictionary(days.map { day in
            var normalized = day; normalized.date = calendar.startOfDay(for: day.date)
            return (normalized.date, normalized)
        }, uniquingKeysWith: { first, second in
            var merged = first; merged.merge(second)
            return merged
        })
        let positive = indexed.values.filter { $0.date >= start && $0.date < end && $0.date <= today && $0.tokens.total > 0 }.map(\.tokens.total).sorted()
        var result: [HeatmapCell] = [], date = start, index = 0, sum: Int64 = 0
        while date < end {
            let future = date > today
            let usage = future ? UsageDay(date: date) : indexed[date] ?? UsageDay(date: date)
            let rank = positive.partitioningIndex { $0 > usage.tokens.total }
            let level = usage.tokens.total == 0 ? 0 : max(1, min(4, Int(ceil(Double(rank) / Double(max(1, positive.count)) * 4))))
            result.append(HeatmapCell(date: date, week: (index + offset) / 7, weekday: (index + offset) % 7, level: level, usage: usage, future: future))
            let nextSum = sum.addingReportingOverflow(usage.tokens.total); sum = nextSum.overflow ? Int64.max : nextSum.partialValue
            index += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }; date = next
        }
        cells = result; weeks = (index + offset + 6) / 7; total = sum
        activeDays = positive.count; peak = positive.last ?? 0
    }
}
private extension Array where Element == Int64 {
    func partitioningIndex(where predicate: (Int64) -> Bool) -> Int {
        var lower = 0, upper = count
        while lower < upper { let middle = (lower + upper) / 2; if predicate(self[middle]) { upper = middle } else { lower = middle + 1 } }
        return lower
    }
}

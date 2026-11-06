import Foundation

public struct ReadCursor: Codable, Sendable {
    public var offset: UInt64 = 0
    public var dropping: Bool = false
    public init(offset: UInt64 = 0, dropping: Bool = false) { self.offset = offset; self.dropping = dropping }
}
public struct ReadResult: Sendable {
    public var cursor: ReadCursor
    public var skipped: Int = 0
    public var bytesRead: Int = 0
}

/// Bounded reads and autorelease scopes matter even when all records are streamed.
/// Only complete normal lines advance the committed offset. An oversized partial
/// line persists its discard state so later appends cannot turn its tail into JSON.
public enum LineReader {
    public static func read(_ url: URL, cursor: ReadCursor, byteBudget: Int = 8 * 1024 * 1024,
                            lineLimit: Int = 2 * 1024 * 1024,
                            consume: (Data, UInt64) throws -> Void) throws -> ReadResult {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: cursor.offset)
        var result = ReadResult(cursor: cursor)
        var pending = Data(), lineStart = cursor.offset, absolute = cursor.offset
        var dropping = cursor.dropping
        while result.bytesRead < byteBudget {
            let didRead: Bool = try autoreleasepool {
                guard let chunk = try file.read(upToCount: min(65536, byteBudget - result.bytesRead)), !chunk.isEmpty else { return false }
                result.bytesRead += chunk.count
                var begin = chunk.startIndex
                while let end = chunk[begin...].firstIndex(of: 10) {
                    let part = chunk[begin..<end]
                    if !dropping, pending.count + part.count <= lineLimit {
                        pending.append(contentsOf: part)
                        if !pending.isEmpty { try consume(pending, lineStart) }
                    } else { result.skipped += 1 }
                    absolute += UInt64(end - begin + 1)
                    lineStart = absolute; result.cursor = ReadCursor(offset: absolute)
                    pending.removeAll(keepingCapacity: false); dropping = false; begin = end + 1
                }
                let tail = chunk[begin...]
                absolute += UInt64(tail.count)
                if !dropping {
                    if pending.count + tail.count > lineLimit { dropping = true; pending.removeAll(keepingCapacity: false) }
                    else { pending.append(contentsOf: tail) }
                }
                if dropping { result.cursor = ReadCursor(offset: absolute, dropping: true) }
                return true
            }
            if !didRead { break }
        }
        return result
    }
}

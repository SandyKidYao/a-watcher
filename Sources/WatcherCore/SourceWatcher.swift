import Foundation
import CoreServices

public final class SourceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let queue = DispatchQueue(label: "a-watcher.files", qos: .utility, autoreleaseFrequency: .workItem)
    private let changed: @Sendable ([String]) -> Void
    public init(root: URL, changed: @escaping @Sendable ([String]) -> Void) throws {
        self.changed = changed
        self.root = root
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, context, count, paths, eventFlags, _ in
            guard let context else { return }
            let object = Unmanaged<SourceWatcher>.fromOpaque(context).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescan = (0..<count).contains { eventFlags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0 }
            let relevant = rescan ? [object.root.path] : list.enumerated().compactMap { index, path -> String? in
                let directory = eventFlags[index] & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                return directory || path.hasSuffix(".jsonl") || path.hasSuffix(".jsonl.zst") || path.hasSuffix("auth.json") ? path : nil
            }
            if !relevant.isEmpty { object.changed(relevant) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        guard let stream else { throw StoreError.database(-1) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil; throw StoreError.database(-1) }
    }
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
        queue.sync {} // Drain callbacks before releasing their unretained context.
        FSEventStreamRelease(stream)
    }
    deinit { stop() }
}

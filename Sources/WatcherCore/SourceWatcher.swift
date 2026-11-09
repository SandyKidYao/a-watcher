import Foundation
import CoreServices
import Darwin

public final class SourceWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let queue = DispatchQueue(label: "a-watcher.files", qos: .utility, autoreleaseFrequency: .workItem)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let changed: @Sendable ([String]) -> Void
    // FSEvents discovers files, but can coalesce away later writes while a
    // producer keeps a log open. Vnode sources observe those appends directly.
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var stopped = false
    private let fileLimit = 64
    public init(root: URL, changed: @escaping @Sendable ([String]) -> Void) throws {
        self.changed = changed
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        queue.setSpecific(key: queueKey, value: 1)
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
    public func watchFiles(_ paths: [String]) {
        queue.async { [weak self] in self?.registerFiles(paths) }
    }
    private func registerFiles(_ paths: [String]) {
        guard !stopped else { return }
        let incoming = Set(paths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            return url.pathExtension == "jsonl" && url.path.hasPrefix(root.path + "/") ? url.path : nil
        })
        guard !incoming.isSubset(of: Set(fileSources.keys)) else { return }
        let candidates = incoming.union(fileSources.keys).compactMap { path -> (String, Date)? in
            guard let date = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (path, date)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let keep = Set(candidates.prefix(fileLimit).map(\.0))
        for path in Array(fileSources.keys) where !keep.contains(path) { fileSources.removeValue(forKey: path)?.cancel() }
        for path in keep where fileSources[path] == nil {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue } // FSEvents/unknown-state fallback remains available.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped, let events = self.fileSources[path]?.data else { return }
                if !events.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.fileSources.removeValue(forKey: path)?.cancel()
                    self.changed([self.root.path])
                } else { self.changed([path]) }
            }
            fileSources[path] = source
            source.resume()
            // Catch writes between the index snapshot and vnode registration.
            changed([path])
        }
    }
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
        let cancelFiles = {
            self.stopped = true
            self.fileSources.values.forEach { $0.cancel() }; self.fileSources.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { cancelFiles() }
        else { queue.sync(execute: cancelFiles) }
        // Drain callbacks before releasing their unretained context. A final
        // weak callback may release the owner on this queue: never sync to self.
        FSEventStreamRelease(stream)
    }
    deinit { stop() }
}

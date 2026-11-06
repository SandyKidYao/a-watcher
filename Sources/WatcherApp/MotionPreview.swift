import AppKit
import ImageIO
import UniformTypeIdentifiers
import WatcherCore

/// Synthetic, native animation validation. Runs only with --export-motion.
@MainActor enum MotionPreview {
    static func export(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 94, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.backgroundColor = .white; host.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 94, height: 44)); root.wantsLayer = true
        host.contentView = root
        let icon = ActivityIconView(frame: NSRect(x: 8, y: 11, width: 42, height: 22))
        let row = WorkingGlyphView(frame: NSRect(x: 68, y: 12, width: 16, height: 20))
        root.addSubview(icon); root.addSubview(row); host.orderFrontRegardless()
        let now = Date(); var tracker = ActivityTracker()
        var sessions = [SessionRecord(id: "motion-a", status: .running, observedAt: now), SessionRecord(id: "motion-b", status: .tool, observedAt: now)]
        let update = tracker.ingest(sessions, bootstrapping: false, now: now)
        let blue = NSColor(calibratedRed: 0.14, green: 0.37, blue: 0.66, alpha: 1)
        icon.apply(update); row.apply(moving: MotionMonitor.shared.enabled, color: blue)
        try? await Task.sleep(for: .milliseconds(400))
        var menuSamples: [[CGFloat]] = [], rowSamples: [[CGFloat]] = []
        let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("working-motion.gif") as CFURL, UTType.gif.identifier as CFString, 20, nil)
        if let gif { CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
        for _ in 0..<20 {
            menuSamples.append(icon.presentationScales); rowSamples.append(row.presentationScales)
            if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 376, pixelsHigh: 176, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                let cg = context.cgContext; cg.setFillColor(NSColor.white.cgColor); cg.fill(CGRect(x: 0, y: 0, width: 376, height: 176)); cg.scaleBy(x: 4, y: 4)
                (root.layer?.presentation() ?? root.layer)?.render(in: cg)
                if let image = bitmap.cgImage, let gif { CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.065]] as CFDictionary) }
            }
            try? await Task.sleep(for: .milliseconds(65))
        }
        let gifWritten = gif.map { CGImageDestinationFinalize($0) } ?? false
        icon.apply(update, animate: false); row.apply(moving: false, color: blue)
        let reducedStopped = icon.workRepeatCounts.isEmpty && row.animationCount == 0 && icon.displayedCount == "2"
        icon.apply(update); row.apply(moving: MotionMonitor.shared.enabled, color: blue)
        let resumed = !MotionMonitor.shared.enabled || (icon.workRepeatCounts.count == 3 && row.animationCount == 3)
        for i in sessions.indices { sessions[i].status = .idle; sessions[i].observedAt = now.addingTimeInterval(3) }
        icon.apply(tracker.ingest(sessions, bootstrapping: false, now: now.addingTimeInterval(3)))
        row.removeFromSuperview()
        let stopped = icon.workRepeatCounts.isEmpty && icon.displayedCount.isEmpty && row.animationCount == 0
        host.close()
        let menuMoves = Set(menuSamples.map { $0.map { Int($0 * 100) } }).count > 1
        let rowMoves = Set(rowSamples.map { $0.map { Int($0 * 100) } }).count > 1
        let report: [String: Any] = ["synthetic": true, "nativePresentationSamples": 20, "motionEnabled": MotionMonitor.shared.enabled, "menuMoved": menuMoves, "rowMoved": rowMoves, "staticFallbackKeepsCount": reducedStopped, "resumesWithoutNewSession": resumed, "completionAndDetachStopMotion": stopped, "gifWritten": gifWritten, "passed": (!MotionMonitor.shared.enabled || (menuMoves && rowMoves)) && reducedStopped && resumed && stopped && gifWritten]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("motion-check.json")) }
    }
}

import AppKit
import SwiftUI
import Combine
import WatcherCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var panel: NSPopover?
    private var model: WatcherModel?
    private var activity = ActivityTracker()
    private var activityIcon: ActivityIconView?
    private var receiptsURL: URL?
    private var expiryTask: Task<Void, Never>?
    private var expiryAt: Date?
    private var motionSubscription: AnyCancellable?
    private var activityLog: URL?
    private var lastLoggedActivity = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchArgs = CommandLine.arguments
        if let i = launchArgs.firstIndex(of: "--export-motion"), launchArgs.count > i + 1 {
            let directory = URL(fileURLWithPath: launchArgs[i + 1])
            Task { await MotionPreview.export(to: directory); NSApp.terminate(nil) }
            return
        }
        if let i = launchArgs.firstIndex(of: "--export-icon-states"), launchArgs.count > i + 1 {
            let directory = URL(fileURLWithPath: launchArgs[i + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            exportIconStates(to: directory); NSApp.terminate(nil); return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let activityIcon = ActivityIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        item.length = 28
        activityIcon.frame.origin.x = 2
        item.button?.addSubview(activityIcon); self.activityIcon = activityIcon
        item.button?.setAccessibilityLabel("Agent Watcher，查看两种 Agent 的工作状态")
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        let model = WatcherModel()
        self.model = model
        receiptsURL = model.dataDirectory.appendingPathComponent("completion-\(stableHash(model.root.path + "|" + model.claudeRoot.path).prefix(16)).json")
        if let url = receiptsURL, let data = try? Data(contentsOf: url), data.count <= 65536,
           let receipts = try? JSONDecoder().decode(CompletionReceipts.self, from: data) { activity = ActivityTracker(receipts: receipts) }
        activityIcon.apply(activity.current(), animate: false)
        motionSubscription = MotionMonitor.shared.$enabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }
        model.resize = { [weak self] height in self?.panel?.contentSize = NSSize(width: self?.model?.panelWidth ?? 320, height: height) }
        model.changed = { [weak self] in self?.updateStatus() }
        model.start()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--activity-log"), args.count > i + 1 { activityLog = URL(fileURLWithPath: args[i + 1]) }
        if args.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.toggle() } }
        if let i = args.firstIndex(of: "--export-preview"), args.count > i + 1 {
            let directory = URL(fileURLWithPath: args[i + 1])
            Task { await self.exportPreviews(to: directory) }
        }
        if let i = args.firstIndex(of: "--smoke-seconds"), args.count > i + 1, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(5, seconds)) { NSApp.terminate(nil) }
        }
    }
    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "退出 a-watcher", action: #selector(quit), keyEquivalent: "q"); quit.target = self
            menu.addItem(quit)
            if let button = item?.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
            return
        }
        if panel?.isShown == true { panel?.close(); return }
        guard let model, let button = item?.button else { return }
        model.opened()
        let hadUnread = activity.receipts.unread > 0
        activityIcon?.apply(activity.acknowledge(), animate: false)
        if hadUnread { saveReceipts() }
        updateStatus()
        let panel = NSPopover(); panel.behavior = .transient; panel.animates = false; panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: WatcherPanel(model: model))
        panel.contentSize = NSSize(width: model.panelWidth, height: model.panelHeight)
        self.panel = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func updateStatus() {
        guard let model else { return }
        let update = activity.ingest(model.allSessions, bootstrapping: model.isIndexing)
        let iconWidth = ActivityIconView.width(for: update.active)
        if item?.length != iconWidth + 4 { item?.length = iconWidth + 4; activityIcon?.frame.size.width = iconWidth }
        activityIcon?.apply(update)
        let note = update.unread > 0 ? "，\(update.unread) 个完成未读" : ""
        let text = "Agent Watcher，\(update.active) 个确认工作中，\(update.attention) 个需要处理" + note + (update.mode == .uncertain ? "，部分状态待确认" : "")
        if item?.button?.toolTip != text { item?.button?.toolTip = text; item?.button?.setAccessibilityLabel(text) }
        if update.completed > 0 { saveReceipts() }
        if let activityLog {
            let signature = "\(update.mode.rawValue):\(update.active):\(update.unread):\(update.started):\(update.completed)"
            if signature != lastLoggedActivity {
                lastLoggedActivity = signature
                let event: [String: Any] = ["mode": update.mode.rawValue, "active": update.active, "attention": update.attention, "unread": update.unread, "started": update.started, "completed": update.completed,
                    "workAnimationCount": activityIcon?.workRepeatCounts.count ?? 0, "displayedCount": activityIcon?.displayedCount ?? "", "motionReduced": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled]
                if var data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) {
                    data.append(10)
                    if !FileManager.default.fileExists(atPath: activityLog.path) { FileManager.default.createFile(atPath: activityLog.path, contents: nil) }
                    if let file = try? FileHandle(forWritingTo: activityLog) { _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close() }
                }
            }
        }
        // One deadline for stale status evidence; no repeating animation timer.
        let next = model.allSessions.filter { $0.status.isActive && !$0.status.needsAttention }
            .map { $0.observedAt.addingTimeInterval(181) }.filter { $0 > Date() }.min()
        if let next {
            if let expiryAt, expiryAt <= next { return }
            expiryTask?.cancel(); expiryAt = next
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
                self?.expiryAt = nil
                self?.model?.objectWillChange.send()
                self?.updateStatus()
            }
        } else { expiryTask?.cancel(); expiryTask = nil; expiryAt = nil }
    }
    private func saveReceipts() {
        guard let url = receiptsURL, let data = try? JSONEncoder().encode(activity.receipts) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop(); expiryTask?.cancel()
        motionSubscription = nil
    }
    /// Render this application's own native view for offline visual QA. This
    /// does not capture the desktop or automate any other application.
    private func exportPreviews(to directory: URL) async {
        guard let model else { return }
        for _ in 0..<100 {
            if model.index.usage.filesTotal > 0, !model.isIndexing, model.claudeIndex.usage.filesTotal > 0, !model.quotaBusy { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if panel?.isShown != true { toggle() }
        for (name, page) in [("home", PanelPage.home), ("quota", .quota), ("usage", .usage), ("status-legend", .legend)] {
            model.navigate(page)
            try? await Task.sleep(for: .milliseconds(300))
            renderPanel(to: directory.appendingPathComponent("\(name).png"))
        }
        panel?.contentViewController?.view.window?.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("status-legend-dark.png"))
        panel?.contentViewController?.view.window?.appearance = nil
        model.showQuota(.claude)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("claude-quota.png"))
        model.quotaProvider = .codex
        if let session = model.allSessions.first(where: { model.projectedStatus($0) == .unknown }) ?? model.allSessions.first {
            model.navigate(.session(session.key))
            try? await Task.sleep(for: .milliseconds(300))
            renderPanel(to: directory.appendingPathComponent("session.png"))
        }
        model.navigate(.history)
        for _ in 0..<50 { if !model.historyLoading { break }; try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("history.png"))
        model.selectHistoryScope(.claude)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("history-claude.png"))
        panel?.contentViewController?.view.window?.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("history-dark.png"))
        panel?.contentViewController?.view.window?.appearance = nil
        model.selectHistoryScope(nil)
        model.selectedProvider = .claude; model.navigate(.home)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("claude-sessions.png"))
        model.selectedProvider = nil
        model.showUsage(.claude)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("claude-usage.png"))
        if let button = item?.button { renderView(button, to: directory.appendingPathComponent("menubar-single.png")) }
        exportIconStates(to: directory)
        model.navigate(.home)
        panel?.contentViewController?.view.window?.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("home-dark.png"))
        panel?.contentViewController?.view.window?.appearance = nil
        let report: [String: Any] = ["nativeViewRendering": true, "manualClickTest": false,
            "filesIndexed": model.index.usage.filesTotal, "sessions": model.allSessions.count,
            "claudeFilesIndexed": model.claudeIndex.usage.filesTotal, "claudeSessions": model.claudeIndex.sessions.count, "claudeQuotaQueried": false,
            "quotaWindows": model.quota?.windows.count ?? 0, "quotaError": model.quotaError?.code.rawValue ?? "none",
            "partialUsage": model.index.usage.isPartial]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("render-result.json"), options: .atomic)
        }
        // Explicit synthetic rendering cases. Stop live updates first so these
        // cannot be mixed with real observations or written to the ledger.
        model.stop()
        model.index = IndexSnapshot(); model.claudeIndex = IndexSnapshot()
        model.readyProviders = Set(AgentProvider.allCases)
        model.quota = nil; model.quotaError = QuotaFailure(.offline)
        model.navigate(.home)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("fixture-empty.png"))
        let names = ["项目名称很长时仍需保留右侧状态与时间", "a-watcher-with-a-very-long-project-name", "completed-project", "silent-project"]
        model.index.sessions = names.enumerated().map { i, name in
            SessionRecord(id: "render-fixture-\(i)", project: name, status: [SessionStatus.waitingInput, .tool, .idle, .running][i], observedAt: Date().addingTimeInterval(i == 3 ? -600 : -10))
        }
        model.navigate(.home)
        try? await Task.sleep(for: .milliseconds(300))
        renderPanel(to: directory.appendingPathComponent("fixture-long-names.png"))
        panel?.close()
    }
    private func exportIconStates(to directory: URL) {
        let now = Date(); var sample = ActivityTracker()
        var session = SessionRecord(id: "visual-fixture", status: .running, observedAt: now)
        let idle = sample.ingest([], bootstrapping: false, now: now)
        let working = sample.ingest([session], bootstrapping: false, now: now)
        var multi = ActivityTracker()
        let twelve = (0..<12).map { SessionRecord(id: "visual-\($0)", status: .running, observedAt: now) }
        let many = multi.ingest(twelve, bootstrapping: false, now: now)
        session.status = .idle; session.observedAt = now.addingTimeInterval(1)
        let done = sample.ingest([session], bootstrapping: false, now: now.addingTimeInterval(1))
        for (name, state) in [("idle", idle), ("working", working), ("working-12", many), ("completed", done)] {
            let width = ActivityIconView.width(for: state.active)
            let icon = ActivityIconView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            icon.appearance = NSAppearance(named: .aqua); icon.apply(state, animate: false)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 4), pixelsHigh: 88, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            let cg = context.cgContext
            cg.setFillColor(NSColor.white.cgColor); cg.fill(CGRect(x: 0, y: 0, width: width * 4, height: 88)); cg.scaleBy(x: 4, y: 4)
            icon.layer?.render(in: cg)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent("wave-\(name).png"), options: .atomic) }
        }
    }
    private func renderPanel(to url: URL) {
        guard let view = panel?.contentViewController?.view else { return }
        renderView(view, to: url)
    }
    private func renderView(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url, options: .atomic) }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === panel else { return }
        panel?.contentViewController = nil; panel = nil; model?.closed()
    }
}

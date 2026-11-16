import AppKit
import Combine
import WatcherCore

enum PanelPage: Equatable { case home, detail, history, help, session(String) }

@MainActor final class WatcherModel: ObservableObject {
    @Published var historyScope: AgentProvider?
    @Published var historyYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    @Published var historySelection = Calendar.current.startOfDay(for: Date())
    @Published var historyMap = UsageHeatmap(year: Calendar(identifier: .gregorian).component(.year, from: Date()), days: [], calendar: Calendar(identifier: .gregorian))
    @Published var historyLoading = false
    @Published var historyError: String?
    @Published var historyPartial = true
    @Published var historyYears: [Int] = [Calendar(identifier: .gregorian).component(.year, from: Date())]
    private var historySources: [AgentProvider: UsageHistory] = [:]
    private var historyTask: Task<Void, Never>?
    private var panelVisible = false
    var historyCalendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; return calendar }
    @Published var snapshots: [AgentProvider: IndexSnapshot] = [:]
    @Published var selectedProvider: AgentProvider?
    /// Agent shown on the detail page: account quota and local usage together.
    @Published var detailProvider = AgentProvider.codex
    @Published var readyProviders: Set<AgentProvider> = []
    @Published var quotas: [AgentProvider: QuotaSnapshot] = [:]
    @Published var quotaErrors: [AgentProvider: QuotaFailure] = [:]
    @Published private(set) var scanErrors: [AgentProvider: String] = [:]
    @Published private(set) var watchErrors: [AgentProvider: String] = [:]
    @Published var quotaBusy = false
    @Published var days = 1
    @Published var detailUsage = UsageSummary()
    @Published var page = PanelPage.home
    @Published var showAllSessions = false
    let sessionDirectories: [AgentProvider: URL]
    let roots: [AgentProvider: URL]
    let dataDirectory: URL
    var offline = false
    private var quotaClients: [AgentProvider: any AgentQuotaClient] = [:]
    private var quotaCheckedAt: [AgentProvider: Date] = [:]
    private var engines: [AgentProvider: AgentIndex] = [:]
    private var bridgeWatches: [AgentProvider: SourceWatcher] = [:]
    private var feeds: [AgentProvider: any AgentStatusFeed] = [:]
    @Published private var evidenceByAgent: [AgentProvider: [String: SessionRecord]] = [:]
    private var watchers: [AgentProvider: SourceWatcher] = [:]
    private var liveReaders: [AgentProvider: LiveStatusReader] = [:]
    private var statusTasks: [AgentProvider: Task<Void, Never>] = [:]
    private var pendingPaths: [AgentProvider: Set<String>] = [:]
    @Published var statisticsUpdatedAt: Date?
    private var scanTasks: [AgentProvider: Task<Void, Never>] = [:]
    private var quotaTask: Task<Void, Never>?
    private var cadence: Task<Void, Never>?
    private var rescanRequested: Set<AgentProvider> = []
    private var lifecycle: AnyCancellable?
    var resize: ((CGFloat) -> Void)?
    var changed: (() -> Void)?

    init() {
        let args = CommandLine.arguments
        func option(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i + 1 else { return nil }; return args[i + 1] }
        sessionDirectories = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.compactMap { provider in
            provider.source.sessionOverride(option("--" + provider.rawValue + "-session-dir")).map { (provider, $0) }
        })
        roots = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, $0.source.root(override: option("--" + $0.rawValue + "-home"))) })
        dataDirectory = URL(fileURLWithPath: option("--data-dir") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/a-watcher").path)
        for (provider, root) in roots {
            quotaClients[provider] = provider.source.quotaClient?(root, dataDirectory)
        }
    }
    var allSessions: [SessionRecord] {
        let sessions = snapshots.values.flatMap(\.sessions)
        let metadata = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        let live = evidenceByAgent.values.flatMap { $0.values }.compactMap { evidence -> SessionRecord? in
            guard now.timeIntervalSince(evidence.observedAt) < 86400 else { return nil }
            var session = metadata[evidence.key] ?? evidence
            if !evidence.status.isActive && session.observedAt > evidence.observedAt.addingTimeInterval(1) { return nil }
            session.status = evidence.status.isActive && now.timeIntervalSince(evidence.observedAt) >= 180 ? .unknown : evidence.status
            session.confirmedCompletions = evidence.confirmedCompletions
            session.observedAt = evidence.observedAt
            session.source = evidence.source
            return session
        }
        let liveKeys = Set(live.map(\.key))
        return (sessions.filter { !liveKeys.contains($0.key) } + live).sorted {
            let a = projectedStatus($0), b = projectedStatus($1)
            let x = a.needsAttention ? 0 : a.isActive ? 1 : 2, y = b.needsAttention ? 0 : b.isActive ? 1 : 2
            return x == y ? $0.observedAt > $1.observedAt : x < y
        }
    }
    var filteredSessions: [SessionRecord] { allSessions.filter { selectedProvider == nil || $0.provider == selectedProvider } }
    var visibleSessions: ArraySlice<SessionRecord> { filteredSessions.prefix(showAllSessions ? filteredSessions.count : 5) }
    var panelWidth: CGFloat { page == .history ? 760 : 320 }
    var panelHeight: CGFloat { page == .history ? 540 : page == .help ? 560 : page == .detail ? 520 : page == .home ? CGFloat(86 + max(1, min(visibleSessions.count, showAllSessions ? 9 : 5)) * 36 + (isIndexing ? 24 : 0)) : 460 }
    var todayTokenText: String {
        guard filesTotal > 0, !(usagePartial && snapshots.values.allSatisfy { $0.usage.records == 0 }) else { return "—" }
        return compactNumber(snapshots.values.reduce(0) { $0.addingReportingOverflow($1.usage.tokens.total).overflow ? Int64.max : $0 + $1.usage.tokens.total })
    }
    var filesTotal: Int { snapshots.values.reduce(0) { $0 + $1.usage.filesTotal } }
    var filesDone: Int { snapshots.values.reduce(0) { $0 + $1.usage.filesDone } }
    var usagePartial: Bool { isIndexing || !scanErrors.isEmpty || snapshots.values.contains { $0.usage.isPartial } }
    var isIndexing: Bool { readyProviders.count < AgentProvider.allCases.count || snapshots.values.contains { $0.usage.indexing } }
    var activeCount: Int { allSessions.filter { projectedStatus($0).isWorking }.count }
    var attentionCount: Int { allSessions.filter { projectedStatus($0).needsAttention }.count }
    func snapshot(_ provider: AgentProvider) -> IndexSnapshot { snapshots[provider] ?? IndexSnapshot() }
    func activeCount(_ provider: AgentProvider) -> Int { allSessions.filter { $0.provider == provider && projectedStatus($0).isWorking }.count }
    func projectedStatus(_ session: SessionRecord) -> SessionStatus {
        if [.running, .tool].contains(session.status), Date().timeIntervalSince(session.observedAt) > 180 { return .unknown }
        return session.status == .tool ? .running : session.status
    }
    func statusHelp(_ session: SessionRecord) -> String {
        if projectedStatus(session) == .unknown, [.running, .tool].contains(session.status) {
            return "上次确认仍在工作是 \(shortAge(session.observedAt)) 前。超过 3 分钟没有新的状态记录，无法确认现在是否仍在工作；这不表示已经完成。"
        }
        return projectedStatus(session) == .idle ? "本轮工作已完成，会话仍可继续" : projectedStatus(session).label
    }
    func start() {
        Task {
            for (provider, client) in quotaClients { quotas[provider] = await client.lastKnown() }
            for provider in AgentProvider.allCases {
                guard let source = roots[provider] else { continue }
                let override = sessionDirectories[provider]
                let cacheSource = override.map { source.path + "|" + $0.path } ?? source.path
                let database = dataDirectory.appendingPathComponent("index-\(provider.rawValue)-\(stableHash(cacheSource).prefix(16))-v2.sqlite")
                do {
                    engines[provider] = try await Task.detached(priority: .utility) { try AgentIndex(root: source, database: database, provider: provider, sessionDirectory: override) }.value
                    liveReaders[provider] = LiveStatusReader(root: source, provider: provider, sessionDirectory: override)
                    let watched = override ?? source.appendingPathComponent(provider.source.watchDirectory)
                    if FileManager.default.fileExists(atPath: watched.path) {
                        do {
                            watchers[provider] = try SourceWatcher(root: watched) { [weak self] paths in
                                Task { @MainActor [weak self] in
                                    self?.requestStatus(provider, paths: paths)
                                    if let auth = provider.source.quotaAuthFile, paths.contains(source.appendingPathComponent(auth).path) { self?.refreshQuota() }
                                }
                            }
                        } catch { watchErrors[provider] = "\(provider.name) 自动监听不可用，可手动刷新" }
                    }
                    if let feed = provider.source.statusFeed?(source, dataDirectory) { startBridge(feed, provider: provider) }
                    requestScan(provider)
                } catch { scanErrors[provider] = "\(provider.name) 索引暂不可用"; readyProviders.insert(provider) }
            }
            refreshQuota(); scheduleRefresh()
        }
        lifecycle = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestScan(); self?.refreshQuota() }
        }
    }
    private func startBridge(_ feed: any AgentStatusFeed, provider: AgentProvider) {
        let directory = feed.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            feeds[provider] = feed
            bridgeWatches[provider] = try SourceWatcher(root: directory) { [weak self] paths in
                Task { @MainActor in await self?.updateBridge(provider, paths: paths) }
            }
            Task { await updateBridge(provider, paths: [directory.path]) }
        } catch { watchErrors[provider] = "\(provider.name) 实时状态监听不可用" }
    }
    private func updateBridge(_ provider: AgentProvider, paths: [String]) async {
        guard let feed = feeds[provider] else { return }
        evidenceByAgent[provider] = await feed.update(paths: paths, now: Date())
        changed?(); resize?(panelHeight)
    }
    func requestScan(_ provider: AgentProvider? = nil) {
        guard let provider else { AgentProvider.allCases.forEach { requestScan($0) }; return }
        guard let engine = engines[provider] else { return }
        rescanRequested.insert(provider)
        guard scanTasks[provider] == nil else { return }
        scanTasks[provider] = Task { [weak self] in
            guard let self else { return }
            repeat {
                rescanRequested.remove(provider); await engine.invalidate()
                do {
                    var pending = false
                    repeat {
                        try Task.checkCancellation()
                        var next = try await engine.scanStep(days: 1)
                        if let reader = liveReaders[provider] {
                            await reader.seedSources(await engine.liveStatusSeeds())
                            let fresh = await reader.update(paths: [])
                            watchers[provider]?.watchFiles(await reader.takeWatchPaths())
                            next.sessions = SessionRecord.latest(next.sessions + snapshot(provider).sessions + fresh)
                        }
                        readyProviders.insert(provider)
                        scanErrors[provider] = nil
                        snapshots[provider] = next
                        if page == .detail, detailProvider == provider { detailUsage = try await engine.snapshot(days: days).usage }
                        changed?(); resize?(panelHeight); pending = next.usage.indexing
                        if pending { try await Task.sleep(for: .milliseconds(80)) }
                    } while pending
                } catch is CancellationError { break }
                catch { scanErrors[provider] = "\(provider.name) 本机统计更新失败"; readyProviders.insert(provider); break }
            } while rescanRequested.contains(provider) && !Task.isCancelled
            statisticsUpdatedAt = Date()
            scanTasks[provider] = nil
            if page == .history, panelVisible { loadHistory() }
        }
    }
    func requestStatus(_ provider: AgentProvider, paths: [String]) {
        pendingPaths[provider, default: []].formUnion(paths)
        guard statusTasks[provider] == nil, let reader = liveReaders[provider] else { return }
        statusTasks[provider] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            repeat {
                let paths = Array((pendingPaths[provider] ?? []).prefix(16))
                pendingPaths[provider]?.subtract(paths)
                let fresh = await reader.update(paths: paths)
                watchers[provider]?.watchFiles(await reader.takeWatchPaths())
                let merged = SessionRecord.latest(snapshot(provider).sessions + fresh)
                snapshots[provider, default: IndexSnapshot()].sessions = merged
                changed?(); resize?(panelHeight)
                await Task.yield()
                if pendingPaths[provider]?.isEmpty ?? true, !(await reader.hasPendingUpdates) { break }
            } while !Task.isCancelled
            statusTasks[provider] = nil
        }
    }
    func selectDays(_ value: Int) {
        days = value
        let provider = detailProvider
        guard let engine = engines[provider] else { return }
        Task {
            if let result = try? await engine.snapshot(days: value), days == value, detailProvider == provider { detailUsage = result.usage }
        }
    }
    func accountQuota(_ provider: AgentProvider) -> QuotaSnapshot? { quotas[provider] }
    func accountQuotaError(_ provider: AgentProvider) -> QuotaFailure? { quotaErrors[provider] }
    func showDetail(_ provider: AgentProvider) { detailProvider = provider; navigate(.detail) }
    func refreshQuota(manual: Bool = false) {
        guard !offline, quotaTask == nil else { return }
        quotaBusy = true
        quotaTask = Task { [weak self] in
            guard let self else { return }
            for (provider, client) in quotaClients {
                let interval = provider.source.automaticQuotaInterval
                if !manual, quotaErrors[provider]?.code == .credentialAccess || Date().timeIntervalSince(quotaCheckedAt[provider] ?? .distantPast) < interval { continue }
                quotaCheckedAt[provider] = Date()
                if !manual, quotaErrors[provider] == nil, let cached = await client.lastKnown(), Date().timeIntervalSince(cached.capturedAt) < 3600 {
                    quotas[provider] = cached
                    continue
                }
                do {
                    quotas[provider] = try await client.refresh(manual: manual)
                    quotaErrors[provider] = nil
                } catch let error as QuotaFailure {
                    quotaErrors[provider] = error
                    quotas[provider] = error.invalidatesSnapshot ? nil : await client.lastKnown()
                } catch { if !Task.isCancelled { quotaErrors[provider] = QuotaFailure(.offline) } }
            }
            quotaBusy = false; quotaTask = nil; changed?(); resize?(panelHeight)
        }
    }
    func opened() {
        panelVisible = true
        page = .home; showAllSessions = false; days = 1
        refreshQuota()
        resize?(panelHeight)
    }
    func closed() { panelVisible = false; historyTask?.cancel(); historyLoading = false; page = .home }
    func navigate(_ page: PanelPage) {
        if page != .history { historyTask?.cancel(); historyLoading = false }
        self.page = page
        if page == .detail { detailUsage = snapshot(detailProvider).usage; selectDays(days) }
        if page == .history, panelVisible { loadHistory() }
        resize?(panelHeight)
    }
    var selectedHistoryDay: UsageDay { historyMap.cells.first { historyCalendar.isDate($0.date, inSameDayAs: historySelection) }?.usage ?? UsageDay(date: historySelection) }
    func selectedHistoryUsage(_ provider: AgentProvider) -> UsageDay {
        historySources[provider]?.days.first { historyCalendar.isDate($0.date, inSameDayAs: historySelection) } ?? UsageDay(date: historySelection)
    }
    func historyValue(_ provider: AgentProvider) -> String {
        let day = selectedHistoryUsage(provider)
        if day.records == 0 && (historySources[provider]?.isPartial != false || scanErrors[provider] != nil) { return "—" }
        return compactNumber(day.tokens.total)
    }
    var historyBounds: ClosedRange<Date> {
        let start = historyCalendar.date(from: DateComponents(year: historyYear, month: 1, day: 1))!
        let end = historyCalendar.date(byAdding: .day, value: -1, to: historyCalendar.date(byAdding: .year, value: 1, to: start)!)!
        return start...min(end, historyCalendar.startOfDay(for: Date()))
    }
    func applyShowcaseHistory(_ sources: [AgentProvider: UsageHistory]) {
        historySources = sources; historyLoading = false; historyPartial = false; historyError = nil
        historySelection = historyCalendar.startOfDay(for: Date()); rebuildHistory()
    }
    func selectHistoryScope(_ provider: AgentProvider?) { historyScope = provider; rebuildHistory() }
    func selectHistoryYear(_ year: Int) {
        guard year != historyYear else { return }
        historyYear = year; historySources.removeAll()
        historySelection = historyBounds.upperBound
        rebuildHistory(); loadHistory(selectLatest: true)
    }
    func loadHistory(selectLatest: Bool = false) {
        guard !offline, panelVisible, page == .history else { return }
        historyTask?.cancel(); historyLoading = true; historyError = nil
        let year = historyYear, calendar = historyCalendar, initialSelection = historySelection
        historyTask = Task { [weak self] in
            guard let self else { return }
            var result: [AgentProvider: UsageHistory] = [:], readFailed = false
            for provider in AgentProvider.allCases {
                guard let engine = engines[provider] else { readFailed = true; continue }
                do { result[provider] = try await engine.history(year: year, calendar: calendar) }
                catch { result[provider] = UsageHistory(); readFailed = true }
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, historyYear == year else { return }
            historySources = result
            let current = calendar.component(.year, from: Date())
            let earliest = result.values.compactMap(\.firstRecordedAt).map { calendar.component(.year, from: $0) }.min() ?? current
            historyYears = Array(max(1900, min(earliest, current))...current).reversed()
            historyError = readFailed ? "部分历史读取失败，请重试" : nil
            rebuildHistory()
            if selectLatest, historySelection == initialSelection, let latest = historyMap.cells.last(where: { !$0.future && $0.usage.records > 0 }) { historySelection = latest.date }
            historyLoading = false; historyTask = nil
        }
    }
    private func rebuildHistory() {
        let providers = historyScope.map { [$0] } ?? AgentProvider.allCases
        var combined: [Date: UsageDay] = [:]
        for provider in providers {
            for day in historySources[provider]?.days ?? [] { combined[day.date, default: UsageDay(date: day.date)].merge(day) }
        }
        historyMap = UsageHeatmap(year: historyYear, days: Array(combined.values), calendar: historyCalendar)
        historyPartial = providers.contains { historySources[$0]?.isPartial != false || snapshot($0).usage.indexing || scanErrors[$0] != nil } || historyError != nil
    }
    func openSession(_ session: SessionRecord) {
        if let bundleID = session.provider.source.applicationID, let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: application, configuration: .init())
        } else { NSWorkspace.shared.open(URL(fileURLWithPath: session.projectDirectory ?? (session.directory.isEmpty ? (roots[session.provider]?.path ?? NSHomeDirectory()) : session.directory))) }
    }
    func stop() { bridgeWatches.values.forEach { $0.stop() }; historyTask?.cancel(); scanTasks.values.forEach { $0.cancel() }; statusTasks.values.forEach { $0.cancel() }; quotaTask?.cancel(); cadence?.cancel(); watchers.values.forEach { $0.stop() }; watchers.removeAll(); lifecycle = nil }
    private func scheduleRefresh() {
        cadence = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                requestScan(); refreshQuota()

            }
        }
    }
}

func compactNumber(_ number: Int64) -> String {
    if number >= 1_000_000_000 { return String(format: "%.2fB", Double(number) / 1_000_000_000) }
    if number >= 1_000_000 { return String(format: "%.2fM", Double(number) / 1_000_000) }
    if number >= 1_000 { return String(format: "%.1fK", Double(number) / 1_000) }
    return String(number)
}
func shortAge(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

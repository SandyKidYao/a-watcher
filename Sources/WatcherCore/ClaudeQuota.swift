import Foundation

/// Existing login only: never refresh, write credentials, or invoke a login process.
struct ClaudeCredentials: Sendable {
    let token: String
    let binding: String
    let canRenew: Bool

    static func decode(_ data: Data, root: URL, now: Date = Date()) throws -> Self {
        guard data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw QuotaFailure(.noCredentials) }
        // As in Orca, the usage server decides whether a stored access token is valid.
        let refreshExpiry = integer(oauth["refreshTokenExpiresAt"])
        let canRenew = !(oauth["refreshToken"] as? String ?? "").isEmpty &&
            (refreshExpiry == nil || Double(refreshExpiry!) / 1000 > now.timeIntervalSince1970)
        return Self(token: token, binding: stableHash(root.path + "|" + stableHash(token)), canRenew: canRenew)
    }

    static func read(root: URL) throws -> Self {
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.resolvingSymlinksInPath()
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        let storage = override.map { $0.isEmpty ? defaultRoot.path : $0 } ?? environment["CLAUDE_CONFIG_DIR"].flatMap { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == root ? $0 : nil } ?? root.path
        let custom = override.map { !$0.isEmpty } ?? (environment["CLAUDE_CONFIG_DIR"] != nil || root != defaultRoot)
        let suffix = custom ? "-" + stableHash(storage.precomposedStringWithCanonicalMapping).prefix(8) : ""
        let user = environment["USER"] ?? NSUserName()
        let keychainUser = user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) == nil ? "claude-code-user" : user
        // As in Orca: Claude Code writes this item through /usr/bin/security, so read it the same way.
        if let data = try keychainPassword(service: "Claude Code-credentials" + suffix, account: keychainUser) { return try decode(data, root: root) }
        let file = URL(fileURLWithPath: storage).appendingPathComponent(".credentials.json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw QuotaFailure(.noCredentials) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024 * 1024 + 1) else { throw QuotaFailure(.credentialAccess) }
        return try decode(data, root: root)
    }

    /// Runs `security find-generic-password -w` once; nil means the item does not exist (exit 44).
    static func keychainPassword(service: String, account: String) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw QuotaFailure(.credentialAccess) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
        defer { deadline.cancel() }
        var data = Data()
        let handle = output.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 2 * 1024 * 1024 { process.terminate(); process.waitUntilExit(); throw QuotaFailure(.credentialAccess) }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw QuotaFailure(.credentialAccess) }
        switch process.terminationStatus {
        case 0: guard let payload = ClaudeQuotaDecoder.keychainPayload(data) else { throw QuotaFailure(.credentialAccess) }; return payload
        case 44: return nil
        default: throw QuotaFailure(.credentialAccess)
        }
    }
}

public enum ClaudeQuotaDecoder {
    /// `security -w` prints the secret plus a newline, or hex when the stored bytes are not printable.
    public static func keychainPayload(_ output: Data) -> Data? {
        var text = String(decoding: output, as: UTF8.self)
        while text.last?.isNewline == true { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if text.first == "{" { return Data(text.utf8) }
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: text.count / 2); var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return bytes
    }
    public static func decode(_ data: Data, binding: String, now: Date = Date()) throws -> QuotaSnapshot {
        guard data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaFailure(.invalidResponse) }
        var windows: [QuotaWindow] = []
        let lanes: [(String, String, Int64)] = [("five_hour", "Claude", 18000), ("seven_day", "Claude", 604800),
            ("seven_day_opus", "Opus", 604800), ("seven_day_sonnet", "Sonnet", 604800), ("seven_day_oauth_apps", "OAuth apps", 604800)]
        for (key, name, seconds) in lanes {
            guard let lane = object[key] as? [String: Any], let used = percentage(lane["utilization"]) ?? percentage(lane["used_percentage"]) else { continue }
            windows.append(QuotaWindow(id: key, name: name, seconds: seconds, usedPercent: used,
                                       resetsAt: resetDate(lane["resets_at"])))
        }
        // New model-scoped windows are exposed in limits instead of fixed top-level keys.
        if let limits = object["limits"] as? [[String: Any]] {
            for (index, lane) in limits.prefix(32).enumerated() where lane["kind"] as? String == "weekly_scoped" {
                guard let used = percentage(lane["percent"]),
                      let scope = lane["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String, !name.isEmpty,
                      !windows.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
                windows.append(QuotaWindow(id: "scoped-\(index)", name: String(name.prefix(64)), seconds: 604800,
                                           usedPercent: used, resetsAt: resetDate(lane["resets_at"])))
            }
        }
        let billing = decodeBilling(object)
        guard !windows.isEmpty || billing != nil else { throw QuotaFailure(.invalidResponse) }
        return QuotaSnapshot(binding: binding, capturedAt: now, windows: windows, creditBalance: nil, unlimitedCredits: false, claudeBilling: billing)
    }
    private static func resetDate(_ value: Any?) -> Date? {
        let number = percentage(value) ?? (value as? String).flatMap(Double.init)
        if let number, number.isFinite, number >= 0 {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        return parseTimestamp(value as? String)
    }
    private static func currency(_ value: Any?) -> String? {
        guard let value = value as? String, value.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else { return nil }
        return value.uppercased()
    }
    private static func money(_ value: Any?, defaultCurrency: String?) -> ClaudeMoney? {
        if let amount = percentage(value), let defaultCurrency { return ClaudeMoney(amount: amount, currency: defaultCurrency) }
        guard let fields = value as? [String: Any], let minor = percentage(fields["amount_minor"]),
              let code = currency(fields["currency"]) ?? (fields["currency"] == nil ? defaultCurrency : nil) else { return nil }
        let exponent = fields["exponent"] == nil ? 2 : integer(fields["exponent"])
        guard let exponent, exponent <= 6 else { return nil }
        return ClaudeMoney(amount: minor / pow(10, Double(exponent)), currency: code)
    }
    private static func decodeBilling(_ object: [String: Any]) -> ClaudeBilling? {
        if let spend = object["spend"] as? [String: Any] {
            let cap = (spend["cap"] as? [String: Any])?["money"]
            let candidates = [spend["used"], spend["limit"], cap, spend["balance"]]
            let code = candidates.compactMap { ($0 as? [String: Any]).flatMap { currency($0["currency"]) } }.first ?? "USD"
            let spent = money(spend["used"], defaultCurrency: code)
            let limit = money(spend["limit"], defaultCurrency: code) ?? money(cap, defaultCurrency: code)
            let balance = money(spend["balance"], defaultCurrency: code)
            if spent != nil || limit != nil || balance != nil {
                return ClaudeBilling(enabled: spend["enabled"] as? Bool, spent: spent, limit: limit, balance: balance)
            }
        }
        guard let extra = object["extra_usage"] as? [String: Any] else { return nil }
        let code = currency(extra["currency"]) ?? (extra["currency"] == nil || extra["currency"] is NSNull ? "USD" : nil)
        func legacy(_ key: String) -> ClaudeMoney? {
            var fields: [String: Any] = ["amount_minor": extra[key] ?? NSNull()]
            if let exponent = extra["decimal_places"] { fields["exponent"] = exponent }
            return money(fields, defaultCurrency: code)
        }
        let enabled = extra["is_enabled"] as? Bool, spent = legacy("used_credits"), limit = legacy("monthly_limit")
        guard enabled != nil || spent != nil || limit != nil else { return nil }
        return ClaudeBilling(enabled: enabled, spent: spent, limit: limit, balance: nil)
    }

}

private final class ClaudeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer token through redirects.
    }
}

public actor ClaudeQuotaClient {
    private let root: URL
    private let cacheFile: URL
    private let credentialData: (@Sendable () throws -> Data)?
    private let transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private var cached: QuotaSnapshot?
    private var flight: Task<QuotaSnapshot, Error>?
    private var flightBinding: String?
    private var flightID: UUID?
    private var lastBinding: String?
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var rateLimited = false
    public init(root: URL, cacheFile: URL, transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                credentialData: (@Sendable () throws -> Data)? = nil) {
        self.root = root; self.cacheFile = cacheFile; self.transport = transport; self.credentialData = credentialData
    }
    private func readCredentials() async throws -> ClaudeCredentials {
        if let credentialData { return try ClaudeCredentials.decode(credentialData(), root: root) }
        let root = self.root
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try ClaudeCredentials.read(root: root) }) }
        }
    }
    public func lastKnown() async -> QuotaSnapshot? {
        guard let credentials = try? await readCredentials() else { cached = nil; return nil }
        if cached == nil, let data = try? Data(contentsOf: cacheFile) { cached = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
        guard cached?.binding == credentials.binding else { cached = nil; return nil }
        return cached
    }
    public func refresh(manual: Bool = false) async throws -> QuotaSnapshot {
        let credentials = try await readCredentials()
        if lastBinding != credentials.binding {
            if cached?.binding != credentials.binding { cached = nil }
            lastBinding = credentials.binding; nextAttempt = .distantPast; failures = 0; rateLimited = false
        }
        if let flight, flightBinding == credentials.binding { return try await flight.value }
        if let flight { flight.cancel() }
        if Date() < nextAttempt, (!manual || rateLimited) { throw QuotaFailure(rateLimited ? .rateLimited : .offline, retryAt: nextAttempt) }
        let transport = self.transport
        let task = Task<QuotaSnapshot, Error> {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
            let session = URLSession(configuration: configuration, delegate: ClaudeRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("a-watcher/0.1", forHTTPHeaderField: "User-Agent")
            let body: Data; let response: URLResponse
            do {
                if let transport { (body, response) = try await transport(request) }
                else { (body, response) = try await session.data(for: request) }
            }
            catch { if Task.isCancelled { throw CancellationError() }; throw QuotaFailure(.offline) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw QuotaFailure(.invalidResponse) }
            switch http.statusCode {
            case 200: return try ClaudeQuotaDecoder.decode(body, binding: credentials.binding)
            case 401: throw QuotaFailure(credentials.canRenew ? .expiredCredential : .authorization)
            case 403: throw QuotaFailure(.missingScope)
            case 429:
                let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 120
                throw QuotaFailure(.rateLimited, retryAt: Date().addingTimeInterval(max(1, min(seconds, 86400))))
            default: throw QuotaFailure(.server)
            }
        }
        let id = UUID()
        flight = task; flightBinding = credentials.binding; flightID = id
        defer { if flightID == id { flight = nil; flightBinding = nil; flightID = nil } }
        do {
            let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard try await readCredentials().binding == credentials.binding else { cached = nil; throw QuotaFailure(.accountChanged) }
            cached = snapshot; failures = 0; rateLimited = false; nextAttempt = .distantPast
            // Derived quota only; never serialize credentials or raw account response.
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: cacheFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
            }
            return snapshot
        } catch {
            if flightID == id, let failure = error as? QuotaFailure {
                if failure.invalidatesSnapshot { cached = nil }
                failures = min(6, failures + 1); rateLimited = failure.code == .rateLimited
                nextAttempt = failure.retryAt ?? Date().addingTimeInterval(min(1800, 30 * pow(2, Double(failures))))
            }
            throw error
        }
    }
}

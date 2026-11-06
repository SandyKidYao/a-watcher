import Foundation

public struct QuotaFailure: Error, Sendable, Equatable {
    public enum Code: String, Sendable { case noCredentials, expiredCredential, authorization, accountChanged, offline, rateLimited, invalidResponse, server }
    public var code: Code
    public var retryAt: Date?
    public init(_ code: Code, retryAt: Date? = nil) { self.code = code; self.retryAt = retryAt }
    public var message: String {
        switch code {
        case .noCredentials: "请先登录 Codex"
        case .expiredCredential: "请在 Codex 中刷新登录"
        case .authorization: "Codex 登录需要更新"
        case .accountChanged: "账户已变更，请刷新"
        case .offline: "连接不可用，保留上次额度"
        case .rateLimited: "查询限流，稍后重试"
        case .invalidResponse: "额度格式暂不支持"
        case .server: "额度服务暂不可用"
        }
    }
    public var invalidatesSnapshot: Bool { [.noCredentials, .expiredCredential, .authorization, .accountChanged].contains(code) }
}

private struct CodexCredentials: Sendable {
    let token: String
    let accountID: String?
    let binding: String
    static func read(root: URL, now: Date = Date()) throws -> Self {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")), data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else { throw QuotaFailure(.noCredentials) }
        let pieces = token.split(separator: ".")
        if pieces.count == 3 {
            var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            if let payload = Data(base64Encoded: base64), let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let expiry = integer(claims["exp"]), Double(expiry) < now.timeIntervalSince1970 { throw QuotaFailure(.expiredCredential) }
        }
        let id = tokens["account_id"] as? String
        return Self(token: token, accountID: id, binding: stableHash(root.standardizedFileURL.resolvingSymlinksInPath().path + "|" + (id ?? stableHash(token))))
    }
}

public enum QuotaDecoder {
    public static func decode(_ data: Data, binding: String, accountID: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        guard data.count <= 1024 * 1024, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaFailure(.invalidResponse) }
        if let accountID, let returned = root["account_id"] as? String, returned != accountID { throw QuotaFailure(.accountChanged) }
        var windows: [QuotaWindow] = []
        func add(_ rate: [String: Any], prefix: String, name: String) {
            for lane in ["primary_window", "secondary_window"] {
                guard let window = rate[lane] as? [String: Any], let used = percentage(window["used_percent"]) else { continue }
                windows.append(QuotaWindow(id: prefix + ":" + lane, name: name, seconds: integer(window["limit_window_seconds"]), usedPercent: used,
                                           resetsAt: integer(window["reset_at"]).map { Date(timeIntervalSince1970: Double($0)) }))
            }
        }
        if let rate = root["rate_limit"] as? [String: Any] { add(rate, prefix: "codex", name: "Codex") }
        if let extra = root["additional_rate_limits"] as? [[String: Any]] {
            for (index, entry) in extra.prefix(32).enumerated() {
                if let rate = entry["rate_limit"] as? [String: Any] {
                    let name = String((entry["limit_name"] as? String ?? entry["limit_id"] as? String ?? "模型窗口").prefix(128))
                    add(rate, prefix: "extra-\(index)", name: name)
                }
            }
        }
        if let review = root["code_review_rate_limit"] as? [String: Any] { add(review, prefix: "review", name: "Code review") }
        let credits = root["credits"] as? [String: Any]
        let balance = (credits?["balance"] as? String).map { String($0.prefix(64)) }
        guard !windows.isEmpty || balance != nil || credits?["unlimited"] as? Bool == true else { throw QuotaFailure(.invalidResponse) }
        return QuotaSnapshot(binding: binding, capturedAt: now, windows: windows, creditBalance: balance, unlimitedCredits: credits?["unlimited"] as? Bool ?? false)
    }
}

private final class QuotaRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "chatgpt.com" ? request : nil)
    }
}

public actor CodexQuotaClient {
    private let root: URL
    private let cacheFile: URL
    private var cached: QuotaSnapshot?
    private var flight: Task<QuotaSnapshot, Error>?
    private var flightBinding: String?
    private var flightID: UUID?
    private var lastBinding: String?
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var rateLimited = false
    public init(root: URL, cacheFile: URL) { self.root = root; self.cacheFile = cacheFile }
    public func lastKnown() -> QuotaSnapshot? {
        guard let credentials = try? CodexCredentials.read(root: root) else { cached = nil; return nil }
        if cached == nil, let data = try? Data(contentsOf: cacheFile) { cached = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
        guard cached?.binding == credentials.binding else { cached = nil; return nil }
        return cached
    }
    public func refresh(manual: Bool = false) async throws -> QuotaSnapshot {
        let credentials = try CodexCredentials.read(root: root)
        if lastBinding != credentials.binding {
            if cached?.binding != credentials.binding { cached = nil }
            lastBinding = credentials.binding; nextAttempt = .distantPast; failures = 0; rateLimited = false
        }
        if let flight, flightBinding == credentials.binding { return try await flight.value }
        if let flight { flight.cancel() }
        if Date() < nextAttempt, (!manual || rateLimited) { throw QuotaFailure(rateLimited ? .rateLimited : .offline, retryAt: nextAttempt) }
        let task = Task<QuotaSnapshot, Error> {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
            let session = URLSession(configuration: configuration, delegate: QuotaRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            if let id = credentials.accountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
            request.setValue("a-watcher/0.1", forHTTPHeaderField: "User-Agent")
            let body: Data; let response: URLResponse
            do { (body, response) = try await session.data(for: request) }
            catch { if Task.isCancelled { throw CancellationError() }; throw QuotaFailure(.offline) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw QuotaFailure(.invalidResponse) }
            switch http.statusCode {
            case 200: return try QuotaDecoder.decode(body, binding: credentials.binding, accountID: credentials.accountID)
            case 401, 403: throw QuotaFailure(.authorization)
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
            let snapshot = try await task.value
            guard try CodexCredentials.read(root: root).binding == credentials.binding else { cached = nil; throw QuotaFailure(.accountChanged) }
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

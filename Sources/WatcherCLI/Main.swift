import Foundation
import WatcherCore

@main struct WatcherCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i + 1 else { return nil }; return args[i + 1] }
        guard let provider = AgentProvider(rawValue: option("--provider") ?? "codex") else { print("未知 Agent"); exit(2) }
        let root = provider.source.root(override: option("--" + provider.rawValue + "-home"))
        let directory = URL(fileURLWithPath: option("--data-dir") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/a-watcher").path)
        let override = provider.source.sessionOverride(option("--" + provider.rawValue + "-session-dir"))
        let name = String(stableHash(override.map { root.path + "|" + $0.path } ?? root.path).prefix(16))
        do {
            switch args.first {
            case "quota":
                guard let client = provider.source.quotaClient?(root, directory) else { print("额度取决于模型服务商"); exit(1) }
                let snapshot = try await client.refresh(manual: true)
                let data = try JSONEncoder().encode(snapshot)
                print(String(decoding: data, as: UTF8.self))
            case "scan":
                let index = try AgentIndex(root: root, database: directory.appendingPathComponent("index-\(provider.rawValue)-\(name)-v2.sqlite"), provider: provider, sessionDirectory: override)
                var snapshot: IndexSnapshot
                repeat { snapshot = try await index.scanStep(days: Int(option("--days") ?? "1") ?? 1) } while snapshot.usage.indexing
                let usage = snapshot.usage
                let result: [String: Any] = ["tokens": (usage.records == 0 && (usage.isPartial || usage.filesTotal == 0)) ? NSNull() as Any : usage.tokens.total, "input": usage.tokens.input, "cached": usage.tokens.cached,
                    "output": usage.tokens.output, "reasoning": usage.tokens.reasoning, "records": usage.records,
                    "sessions": snapshot.sessions.count, "partial": usage.isPartial, "skippedLines": usage.skippedLines,
                    "incompleteRequests": usage.incompleteRequests, "unresolvedForks": usage.unresolvedForks, "compressedFiles": usage.compressedFiles,
                    "unreadableSources": usage.unreadableSources, "files": usage.filesTotal, "models": usage.byModel.map { ["model": $0.name, "tokens": $0.tokens] as [String: Any] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            case "doctor":
                var result: [String: Any] = ["provider": provider.rawValue, "localDirectory": FileManager.default.fileExists(atPath: root.path),
                    "sessionsDirectory": FileManager.default.fileExists(atPath: (override ?? root.appendingPathComponent(provider.source.directories[0])).path),
                    "claudeLocalEnabled": true, "claudeQuotaEnabled": true]
                if let file = provider.source.quotaAuthFile { result["credentialFile"] = FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) }

                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            default:
                print("watcherctl scan|quota|doctor [--provider codex|claude|pi] [--codex-home PATH] [--claude-home PATH] [--pi-home PATH] [--pi-session-dir PATH] [--data-dir PATH] [--days N]")
            }
        } catch let failure as QuotaFailure {
            FileHandle.standardError.write(Data("\(failure.message(for: provider))\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("本机索引操作失败：\(type(of: error))\n".utf8)); exit(1)
        }
    }
}

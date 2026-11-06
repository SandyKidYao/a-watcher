import Foundation
import WatcherCore

@main struct WatcherCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i + 1 else { return nil }; return args[i + 1] }
        let provider: AgentProvider = option("--provider") == "claude" ? .claude : .codex
        let codexRoot = URL(fileURLWithPath: option("--codex-home") ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        let root = provider == .codex ? codexRoot : URL(fileURLWithPath: option("--claude-home") ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
        let directory = URL(fileURLWithPath: option("--data-dir") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/a-watcher").path)
        let name = String(stableHash(root.standardizedFileURL.resolvingSymlinksInPath().path).prefix(16))
        do {
            switch args.first {
            case "quota":
                guard provider == .codex else { print("Claude 额度实地查询已暂缓"); return }
                let client = CodexQuotaClient(root: root, cacheFile: directory.appendingPathComponent("quota-\(name).json"))
                let snapshot = try await client.refresh(manual: true)
                let data = try JSONEncoder().encode(snapshot)
                print(String(decoding: data, as: UTF8.self))
            case "scan":
                let index = try CodexIndex(root: root, database: directory.appendingPathComponent("index-\(provider.rawValue)-\(name)-v2.sqlite"), provider: provider)
                var snapshot: IndexSnapshot
                repeat { snapshot = try await index.scanStep(days: Int(option("--days") ?? "1") ?? 1) } while snapshot.usage.indexing
                let usage = snapshot.usage
                let result: [String: Any] = ["tokens": usage.tokens.total, "input": usage.tokens.input, "cached": usage.tokens.cached,
                    "output": usage.tokens.output, "reasoning": usage.tokens.reasoning, "records": usage.records,
                    "sessions": snapshot.sessions.count, "partial": usage.isPartial, "skippedLines": usage.skippedLines,
                    "incompleteRequests": usage.incompleteRequests, "unresolvedForks": usage.unresolvedForks, "compressedFiles": usage.compressedFiles,
                    "files": usage.filesTotal, "models": usage.byModel.map { ["model": $0.name, "tokens": $0.tokens] as [String: Any] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            case "doctor":
                var result: [String: Any] = ["provider": provider.rawValue, "localDirectory": FileManager.default.fileExists(atPath: root.path),
                    "sessionsDirectory": FileManager.default.fileExists(atPath: root.appendingPathComponent(provider == .codex ? "sessions" : "projects").path),
                    "claudeLocalEnabled": true, "claudeQuotaEnabled": false]
                if provider == .codex { result["credentialFile"] = FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path) }

                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            default:
                print("watcherctl scan|quota|doctor [--provider codex|claude] [--codex-home PATH] [--claude-home PATH] [--data-dir PATH] [--days N]")
            }
        } catch let failure as QuotaFailure {
            FileHandle.standardError.write(Data("\(failure.message)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("本机索引操作失败：\(type(of: error))\n".utf8)); exit(1)
        }
    }
}

---
status: draft
version: 1
date: 2026-11-06
---

# 数据来源与技术证据

## 三条数据链路

| 数据 | 首选路线 | 辅助 / 降级 | 不能据此承诺 |
| --- | --- | --- | --- |
| 工作状态 | Codex、Claude Code 的生命周期 hooks | 本地会话事件、有限的进程存在性核对 | 仅有进程或日志 mtime 不能证明 Agent 正在思考或等待批准 |
| 本地用量 | 读取本机 JSONL，逐文件增量解析 | 受支持的本地元数据索引辅助会话发现 | 本机统计不等于全账户跨设备用量 |
| 订阅额度 | 账户侧提供的当前窗口快照 | 日志内额度快照只可标为历史观测 | token 数不能推算真实订阅剩余额度 |

用户已确认两种 Agent 都是官方订阅账户。API Key / 中转账户不是本轮主接入路线。

## 可借鉴项目

### ccusage

已下载源码到临时目录并检查 Rust 适配器；本次 checkout 为 `615bd802bc5c50246b84e98406f20ab048e27cf6`。当前工程已含 Rust workspace，不能继续把它视为只有 TypeScript 的工具。

借鉴逐来源解析、流式记录修正、累计值与增量值区分，以及父子日志回放去重。a-watcher 不需要后台反复启动 ccusage；可以参考规则独立实现。对比测试时固定版本、时区、日期范围和统计口径。

证据：[Rust workspace](https://github.com/ccusage/ccusage/blob/615bd802bc5c50246b84e98406f20ab048e27cf6/rust/Cargo.toml)、[Codex parser](https://github.com/ccusage/ccusage/blob/615bd802bc5c50246b84e98406f20ab048e27cf6/rust/adapters/codex/src/parser.rs)、[Claude daily](https://github.com/ccusage/ccusage/blob/615bd802bc5c50246b84e98406f20ab048e27cf6/rust/adapters/claude/src/daily.rs)。

### CodeIsland

公开 README 和 bridge 源码显示了“hook → 原生 bridge → Unix socket → 原生界面”的路线。这对低空闲开销有价值。只借鉴事件输送方式，不引入它的交互审批、远程和伴侣设备系统。

证据：[工作原理与接入说明](https://github.com/wxtsky/CodeIsland#how-it-works)、[bridge 源码](https://github.com/wxtsky/CodeIsland/blob/main/Sources/CodeIslandBridge/main.swift)。完整克隆未完成；本轮为在线源码阅读，未运行该应用或做它的性能测试。

### CodexBar

它把账户额度与本机费用扫描分开，并处理凭据、来源选择和失败后的快照。可借鉴账户绑定、过期标记、刷新退避；不直接依赖整套程序。

证据：[Codex 数据源](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)、[Claude 数据源](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)、[刷新策略](https://github.com/steipete/CodexBar/blob/main/docs/refresh-loop.md)。完整克隆未完成；文档中的第三方接口行为需在本机再验证。以上 main 链接可变化，实施时应补锁定提交。

## Codex

- 本地：默认 `~/.codex/sessions/`，尊重用户配置的 `CODEX_HOME`，也应覆盖归档目录和版本变动。JSONL 中可见 `session_meta`、`turn_context`、`event_msg`、`token_usage_record`。
- 状态：当前官方已提供 hooks，不应沿用“Codex 只有 notify 可用”的旧判断。优先验证 `SessionStart`、`UserPromptSubmit`、工具事件、`PermissionRequest`、`Stop`、`Interrupt`、`SessionEnd`。
- 精确状态接入要经过 Codex 自身的 hook 信任流程；a-watcher 不能代写其信任记录。
- 额度：官方 app-server 有 `account/rateLimits/read` 和更新通知。首个验证路线为临时 stdio 请求；不默认常驻第二个 app-server，也不假设新启动实例会广播其他实例的会话状态。
- 若短生命周期 app-server 资源超预算，再评估原生 HTTP 兼容适配。CodexBar 使用的账户 endpoint 不是本项目已验证的稳定公开 API。

证据：[官方 hooks](https://learn.chatgpt.com/docs/hooks)、[官方 app-server 账户接口](https://learn.chatgpt.com/docs/app-server#auth-endpoints)。当前文档建议本地开源接入向 Sign in with ChatGPT 迁移；对外分发前单独核实适用的认证路线，不能把个人本机可用等同于任何商业场景均适用。

## Claude Code

- 本地：默认 `~/.claude/projects/**/*.jsonl`，支持 `CLAUDE_CONFIG_DIR` 和显式设置的目录。
- 状态：用官方生命周期 hooks；批准等待与用户输入等待分别记录，具体宿主支持情况需要实测。
- 额度：拟验证官方订阅的 OAuth usage 路线。凭据可能在 macOS Keychain，而不是 `.credentials.json`。访问权限、scope、过期和轮换均可能造成不可用。
- CodexBar 展示了 OAuth API、CLI PTY 和 Web 的多条来源。首期优先最小账户查询；不为了获取额度默认常驻 Claude PTY 或启动浏览器引擎。PTY 作为受控诊断候选，启用前测量子进程开销。
- CLI 负责自己的登录与刷新；本工具不自行覆盖共享凭据。未获允许或读取失败时，显示明确的恢复入口。

证据：[Claude 官方 hooks](https://code.claude.com/docs/en/hooks)、[CodexBar Claude 接入说明](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)。第三方额度接口不是 Anthropic 对外稳定 API 的承诺；目前未发出任何账户请求。

## 本机只读核查

2026-11-06，Apple Silicon，macOS 26.5.2；Swift 6.3.3；Codex CLI 0.162.1；Claude Code 2.1.300。Rust 工具链入口存在，未据此验证可成功构建。

| 检查 | 结果 | 限制 |
| --- | --- | --- |
| 默认会话目录 | Codex、Claude 均存在 | 此次未枚举自定义根目录 |
| 近期日志结构 | 每种抽查 3 个文件，每文件最多末尾 1 MiB | 只输出记录类型和字段名，不复制会话正文 |
| Codex 用量字段 | 累计、上次请求、缓存、推理、额度窗口字段可见 | 未完成真实统计与去重验证 |
| Claude 用量字段 | 输入、输出、缓存读写、message/request 标识字段可见 | 未完成真实统计与流式最终记录验证 |
| Claude 已有 hooks | 已配置多种生命周期事件 | 后续接入必须合并，不覆盖现有命令 |
| Codex 本机协议 | 已通过 `generate-json-schema` 导出至临时目录 | 支持请求不等于实际账户查询成功 |

本机生成 schema 包含额度请求、多窗口信息、`thread/status/changed` 以及等待批准/等待输入标志。它证明当前二进制协议形状，不证明可以无侵入订阅所有其他 Codex 进程。

## 仍需验证的高风险点

1. 现有 Codex 桌面、CLI、Claude 实际宿主对 hooks 的触发与重载行为。
2. 两个官方账户额度的认证路径及权限提示，尤其 Claude Keychain。
3. Codex 临时额度 helper 的全进程峰值与回收时间。
4. 流式更新、父子回放、压缩/归档、跨日与计数重置后的统计一致性。

许可证：ccusage checkout 中为 MIT；CodeIsland 与 CodexBar 公开项目标为 MIT。若后续复制或改编源代码，逐文件确认并保留相应声明。a-watcher 自身许可证仍待决定，本轮未拷贝第三方实现。

---
status: completed-with-open-items
date: 2026-11-06
---

# 技术验证记录

用户已授权完成剩余验证，验证通过后开始开发。实验发现 Claude 额度权限缺口后，用户已明确回复“Claude 先不要管，先把 Codex 接通”。此前等待已解除，当前正式实现只接入 Codex，Claude 保留为后续事项。

## 账户额度：真实请求

### Codex：两条只读路径均已读通

- 官方 app-server stdio：`account/read`、`account/rateLimits/read` 成功；helper 已回收。返回窗口长度为 10,080 分钟，证明界面不能硬编码双窗口。
- 原生 URLSession：`GET https://chatgpt.com/backend-api/wham/usage` 返回 HTTP 200，窗口 604,800 秒，与 RPC 结果一致。现有 `auth.json` 仅在内存读取；不改凭据，不自动刷新共享文件，拒绝跨域重定向。
- RPC helper 峰值 **RSS** 为 205.28 MiB。这是 RSS，不是 physical footprint，不能直接拿它断言超过 footprint 门槛。它仍说明引入探测进程有明显成本，默认采用原生请求更符合最小进程结构；原生网络路径的完整应用峰值还要在集成后测量。
- 原生 endpoint 为兼容性适配，不承诺永久稳定；保持单独适配器与清晰失败状态。官方账户接口参考：[OpenAI app-server](https://learn.chatgpt.com/docs/app-server#auth-endpoints)。

证据：[RPC 结果](codex-quota-result.json)、[原生查询结果](codex-native-result.json)。报告不含 token、账户标识、邮箱或完整响应。

### Claude：当前凭据缺少额度权限

- `claude auth status` 确认 first-party、OAuth token 登录；进程环境提供 `CLAUDE_CODE_OAUTH_TOKEN`，未输出或保存其值。
- 使用该已有凭据请求 `https://api.anthropic.com/api/oauth/usage` 返回 **HTTP 403**，响应明确涉及 scope。调用 Agent 的 token 可用，不代表可读 usage。
- 默认 `.credentials.json` 不存在。两次禁止交互的 Keychain 实验未及时完成，均已终止并设置进程硬时限；不能宣称 Keychain 读取成功，也不继续后台反复尝试。
- 当前可实施的显示为“额度待授权”，不显示 0%、不复用别的账户、不为了绕过权限读取浏览器 cookies。恢复需用户选择官方登录/授权来源；不让用户在聊天中发送 token。
- 接入路线参考：[Claude 认证](https://code.claude.com/docs/en/authentication)、[CodexBar Claude 数据源](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)。不同账户来源不能在未确认身份时混用。

证据：[Claude 查询结果](claude-quota-result.json)。此项目前未通过。

若用户选择先补授权，可在自己的终端运行 `env -u CLAUDE_CODE_OAUTH_TOKEN claude auth login`，由 Claude 的官方流程完成订阅账户登录，再选择该登录来源验证额度。该命令仅针对本次登录进程排除环境 token，不修改 shell 配置；登录是否授予 usage 所需权限仍以之后的真实请求为准。a-watcher 不代填密码、不要求在聊天粘贴 token，也不将一次登录成功等同于额度接入成功。

## 原生 UI 对照

同一台 Apple Silicon Mac、macOS 26.5.2、Swift 6.3.3，`swiftc -O`。相同 300 × 400 的弹层和 12 条静态内容（其中 10 个合成会话）。分别编译纯 AppKit 与 AppKit + NSHostingView / SwiftUI；纯 AppKit 二进制不导入 SwiftUI。

| 场景 | AppKit footprint | 混合 SwiftUI footprint |
| --- | ---: | ---: |
| 首次打开前 | 11.36 MiB | 11.28 MiB |
| 打开弹层 | 18.69 MiB | 19.33 MiB |
| 关闭并释放面板后 | 18.39 MiB | 19.28 MiB |

这是单轮、静态样机，差值不足以支持放弃 SwiftUI 的工程决定；不等于完整应用性能。10 分钟空闲 CPU（单核口径）实测：AppKit 0.0066%，混合 SwiftUI 0.0067%；两者均低于 0.1% 目标。各自连续测量超过 600 秒，样机已退出。原生应用还要测活动更新、网络与索引的合计开销。

证据：[AppKit](appkit-baseline.json)、[混合 SwiftUI](appkit-swiftui-baseline.json)。

## 事件 bridge 与状态来源

- 用自编译原生 bridge 向本用户私有 Unix socket 发送 60 个合成 hook 事件，全部送达。
- 事件包括会话开始、输入、工具开始/结束、批准等待、结束；两种 provider 使用同一事件信封。单次启动到送达 p95 约 5.17 ms、中位数约 3.40 ms。
- 校验 socket 所有者与对端 UID；仅提取白名单元数据，合成的 prompt / tool command 私密标记未进入事件。bridge 无 stdout 决策输出，缺 socket 时正常退出，观察器不改变批准结果。
- 实际近期 Codex JSONL 已观察到开始、结束、工具与中断事件；Claude 日志已观察到 usage 与结束字段。现有 Agent hooks 未改动。
- **尚未验证新 hooks 在两种真实宿主中产生所有等待状态**。IPC 合成测试不冒充真实端到端事件测试。Codex 非托管 hooks 仍需其自身信任流程，不能替用户写信任记录。参考：[Codex hooks](https://learn.chatgpt.com/docs/hooks)、[Claude hooks](https://code.claude.com/docs/en/hooks)。

证据：[bridge](bridge-result.json)、[Codex 结构](codex-log-shapes.json)、[Claude 结构](claude-log-shapes.json)、[近期日志只读检查](log-stream-result.json)。

## 大文件读取与内存

本机默认根目录约有 582 MiB Codex 日志和 1,202 MiB Claude 日志。选择各自最大的文件，合计读取 327,184,621 字节（约 312 MiB），不保存正文。

初版虽逐块读取，但 Foundation 读取对象不在逐块 autoreleasepool 中，峰值达到 333.34 MiB。增加逐块释放边界后，同一数据、同一统计探针峰值降为 **12.81 MiB**，耗时约 11.99 秒。

探针设置单行 2 MiB 保护，跳过 56 条超大行。因此该结果证明有界读取可行，**不证明所有 token 已完整统计**。正式版需呈现覆盖范围与跳过数量，进一步验证元数据投影或更合适的解析上限，不得将部分小计标为精确总计。

证据：[原始失败结果](swift-stream-naive-result.json)、[修正结果](swift-stream-result.json)。实验代码留在被忽略的 `.xiaobai/project-init/spikes/`，不是正式实现。

## 计价与监听的补充调研

近期本机模型包括 `gpt-6.1-sol`、`claude-opus-5-5` 与 `codex-auto-review`。已核对 [OpenAI 价格文档](https://developers.openai.com/api/docs/pricing) 与 [Claude Opus 5.5 价格说明](https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5)。正式计价需保留模型、上下文档位、服务档位、缓存 TTL；未知项不直接套默认价格，自动评审别名不猜有效模型，显示已定价小计或未定价。

FSEvents 的丢失/合并事件须有界恢复扫描：[Apple 指南](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)。仅收到文件变更不足以推断批准等待；不使用全目录秒级轮询替代状态事件。

## 尚未通过的项目

1. Claude 真实账户额度权限。
2. 两种 Agent 实际宿主的完整 hook / 介入状态端到端验证。
3. 全量统计对重复、fork、compaction、大行、跨日的正确性回归；当前只是读取与字段探针。
4. 完整应用峰值、动态 10 会话 CPU、8 小时稳定性、休眠恢复及 Intel 实机。

这些限制不伪装成通过；开发若开始也应区分已证实路径、待接入能力与后续验收项。

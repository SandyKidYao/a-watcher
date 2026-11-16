# Pi Coding Agent 接入调研 · 2026-11-16

初步调研建议先支持持久化会话与本机 token 历史；需要准确菜单栏状态的用户再启用 Pi 扩展。两条路径均不需要 a-watcher 启动 Pi 或引入第三方运行库。

**证据范围。** 本机默认目录 ~/.pi/agent/sessions/ 下抽查 1 个 v3 JSONL，每文件最多查看前 200 条、单行上限 1 MiB。89 条 assistant 记录均有 totalTokens、input、output、cacheRead、cacheWrite；结束原因包括 74 条 toolUse、13 条 stop、2 条 error。只输出字段计数，未访问凭据。当前 shell 的 PATH 没有 pi，因此未做真实运行、交互或版本验证。以下扩展行为依据上游 main（所查 package.json 为 1.5.2），不由本机 v3 文件格式推断。

| 能力 | 接入建议与边界 |
|---|---|
| 项目和会话 | 读取头部 id、初始 cwd，复用 SessionProject 解析 Git 根。仅监听已知会话目录；支持显式指定目录，不全盘查找。自定义路径未纳入、未落盘会话均不在文件索引覆盖范围。 |
| 用量账本 | 读取 assistant.message 的 usage（JSON 路径为 message.usage）和独立 type: usage 条目，后者包括缓存预热；优先采用 totalTokens，不重复加缓存。按事件本地日期入账。compaction.tokensBefore 不是新增用量。无可用计数、大行跳过、无权限或回填未完成标为部分或未知。 |
| 分支与恢复 | 同文件的不同分支可包含实际发生的独立请求，不能只统计当前分支。fork/clone 可以携带旧条目，按来源谱系与保留的 entry ID 去重；不能假定短 ID 全局唯一。缺父文件且无法确认归属时降级。为文件改写、截断和重新导入验证幂等性。 |
| 实时状态 | 普通日志可以佐证发生过调用，不能证明工具仍在运行、正在等用户，或 stop 后不会自动继续。仅有历史记录时不计入工作数，不生成完成提醒。可选扩展只发送会话标识、状态和时间等元数据给本地 App，拒绝转发原始事件。 |
| 账户额度 | Pi 可用不同服务商、账户和认证方式；会话 usage 是本机调用量。没有可通用于这些来源的 Pi 七日百分比。footer 用虚线环进入详情，注明「取决于服务商」，不读 auth.json、不复用其他 Agent 的额度。 |

**实时验证重点。** agent_start 与工具执行归入工作中；ui_prompt_start 表示扩展界面等待用户，应优先排除出工作数；ui_prompt_end 后重新确认运行状态。agent_end 之后仍可能重试、压缩或处理排队消息；用 agent_settled 判断不再自动继续，再按终态区分完成、取消和失败。旧版缺少事件时回退。扩展异常退出或超过 3 分钟无新证据，只降为待确认，不产生完成勾；长任务可在确认仍忙时更新轻量存活证据。验证真实终端的成功、重试、等待、取消、长工具调用及进程被杀，再承诺实时支持。

**对仓库的影响。** Models.swift 的 AgentProvider、WatcherModel.swift 的来源/额度/快照选择、LiveStatusReader.swift 的目录与解析器、SQLiteStore.swift 的记录分派以及 BrandAssets.swift 和 UsageHistoryView.swift 均含双 Agent 假设。首版应让三种来源显式分派，共享有界逐行读取和缓存账本，确保 Pi 不会落入 Claude 分支。用不含正文的合成样本验证分支去重、缓存计数、按日汇总和部分统计；年度历史页只查询账本。以上为实现前的调研。后续已在 Pi 1.5.2 实测，另确认 toolResult、compaction 和 branch_summary 也可带 usage；最终实现和覆盖范围见 [接入验证](../dev/pi-agent.md)。

上游依据：[包及版本](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/package.json)、[会话格式](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)、[落盘和分支实现](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts)、[扩展事件](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)、[服务商和凭据](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md)。

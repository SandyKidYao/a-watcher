# Codex 会话间歇漏追踪排查（2026-11-09）

## 范围与结论

用户反馈 VSCode 和 Codex 客户端的会话有时不再被追踪，并要求参考 CodeIsland。只读检查本机日志的头部元数据、文件属性及有界尾部；未保存或输出聊天正文、工具输入和凭据。源码修复与验证在本地完成，未提交、发布或替换 `/Applications/a-watcher.app`。

本机样本中，VSCode 的 `codex_vscode` 和客户端的 `Codex Desktop` 会话均存在于当前 `.codex/sessions`。本轮没有发现“必须按客户端二选一目录”的证据，但不能由此排除其他时间使用自定义 CODEX_HOME、权限或文件事件丢失等问题。

确定复现的缺陷：

1. 旧实时读取器每次仅回放末尾 64 KiB。已缓存会话新写入的开始/完成事件若被大记录挤出尾部，界面会保留上一轮状态；统计刷新前可能持续不更新。合成测试以生命周期事件后追加 100 KB 记录复现了丢开始/丢完成。最近 20 份真实日志的有界抽样中（19 份 Desktop、1 份 VSCode），1 份 Desktop 在 64 KiB 内没有生命周期事件，而 2 MiB 内存在。这里只报告元数据和聚合数；该抽样不能证明所有历史故障都由此造成。
2. FSEvents 的目录/恢复信号经过下游 `.jsonl` 过滤后被丢弃，无法通过目录信号补发现会话。合成日期目录事件稳定复现了新会话不出现。
3. 小时统计逐批返回的 sessions 会直接替换实时列表；索引落后时可能暂时隐藏新会话或用旧状态覆盖新状态。按会话身份和观察时间合并，避免这种回退。

## CodeIsland 对照

本次只读查看开源仓库，锁定提交 `03c77e9457f0adc56fa036caf4925e4a576b453b`，未运行其程序或安装其 hooks。

- [CodexDiscovery.swift](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIsland/Discovery/CodexDiscovery.swift)：区分 Desktop 与其他 app-server 客户端；通过 state_5.sqlite 获取 rollout_path；向后分块查生命周期而非只看固定尾部；有多 root 和进程信息辅助发现。
- [AppState+CodexAppServer.swift](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIsland/AppState+CodexAppServer.swift) 与 [CodexAppServerClient.swift](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIslandCore/CodexAppServerClient.swift)：还有 app-server 子进程及通知接入。
- [README](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/README.md)：hook → bridge → socket 传输生命周期事件；Codex hooks 需要用户审阅和信任。

本次借鉴其避免固定尾部盲区、多渠道证据不能互相覆盖的思路，独立实现有界增量读取。未引入其实现代码、常驻 app-server 或自动写入 hooks。精确等待批准/输入等状态仍取决于来源证据；仅修改日志读取不能等同于主动 hooks 的完整能力。

## 修复实现

- 统计引擎提供内存派生种子：会话元数据、已解析游标和文件身份。实时读取从已知游标继续，正常追加不反复回放日志尾部，也不写统计账本。
- 保留完整行边界；未写完的行留待下次，超过单行上限时降为未知，不把跳过的证据解释为工作或完成。之后完整统计若能解读更大行，可在相同游标处补充状态。
- 每轮实时读取总预算 4 MiB、单文件 2 MiB，读取器内部积压队列分批处理；未处理完的文件不会因 16/32 路径上限而静默丢失。新出现的大文件只取有界头尾，未观测区间不能保证状态时保留未知，随后由索引种子或新事件补足。
- 文件替换或截断后重新初始化游标；路径使用规范化真实路径。
- FSEvents 保留目录事件；MustScanSubDirs、RootChanged、UserDropped、KernelDropped、EventIdsWrapped 均转为来源根目录恢复请求。恢复只枚举来源目录元数据并排队，不扫描无关插件/认证目录，不触发额外用量全扫描。
- 统计与实时更新按 provider + session ID 合并，保留较新的证据与最近新增会话。

## 验证记录

先添加两个复现测试，在旧实现上均失败，再完成修复。覆盖大写入中的开始/完成、目录发现、多 MiB 写入积压、37 文件批次、未完成行、过期种子、原子替换、跳过大行的未知降级及较新状态合并。

`bash Scripts/check.sh` 运行默认自包含检查；`bash Scripts/check.sh --native-file-events` 额外运行真实 FSEvents → 实时读取器的临时文件集成检查。外层限制下 FSEvents 创建返回错误，因此真实事件检查为显式选项；已在正常 macOS 会话中通过。此测试使用纯合成日志，不连接真实 Agent 或账户。SwiftPM 沙箱受限时可设置 `AW_SPM_NO_SANDBOX=1`。

最终验证：默认检查 44 项核心行为 + 8 项更新校验全部通过；正常 macOS 会话中再加真实 FSEvents 检查，共 45 + 8 项通过。`AW_SPM_NO_SANDBOX=1 bash Scripts/build.sh` Release 构建通过，应用 deep / strict 签名验证通过，`git diff --check` 通过。

不把合成文件事件检查当成 VSCode/客户端的长时间真实使用验收，也未声称执行鼠标、键盘或辅助功能测试。后续仍应在两个客户端各进行实际长任务与跨休眠验证。

用户随后已明确授权发布 v0.7.1，并通过本机 v0.7.0 的 Sparkle 更新流程进行安装与重启验证，再核对 VSCode 和 Codex 客户端的会话追踪。该阶段实际结果将在验证后补记。

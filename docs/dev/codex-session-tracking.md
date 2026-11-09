# Codex 会话间歇漏追踪排查（2026-11-09）

## 范围与结论

用户反馈 VSCode 和 Codex 客户端的会话有时不再被追踪，并要求参考 CodeIsland。只读检查本机日志的头部元数据、文件属性及有界尾部；未保存或输出聊天正文、工具输入和凭据。初轮修复已按授权发布 v0.7.1；本机通过 Sparkle 升级后，真实会话验收暴露了第二层文件通知问题。补充修复目前只在源码中，尚未安装或发布，详见下文。

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

用户随后已明确授权发布 v0.7.1，并通过本机 v0.7.0 的 Sparkle 更新流程进行安装与重启验证，再核对 VSCode 和 Codex 客户端的会话追踪。实际结果如下。

## v0.7.1 发布与真实验收

- [v0.7.1](https://github.com/SandyKidYao/a-watcher/releases/tag/v0.7.1) 已发布，源码提交 `63e9b00f319ab7edcdf018c6aacde6f404555ef3`。[Release](https://github.com/SandyKidYao/a-watcher/actions/runs/42590741653) 与 [Check](https://github.com/SandyKidYao/a-watcher/actions/runs/42590741768) 均成功。
- 用户自行在 Sparkle 窗口下载安装并重启，AI 随后只读核对：`/Applications/a-watcher.app` 短版本与 build 均为 0.7.1，运行进程从旧 PID 78633 换成 86657，arm64，deep / strict 签名验证通过。
- 从公开 latest 下载清单、从固定 tag 下载 zip，并以源码可信公钥验签通过。安装的主程序、watcherctl、Info.plist、Sparkle 二进制 SHA-256 均与公开签名包逐字节一致。这确认了升级结果，不冒充 AI 点击完成了安装。
- 用户在 VSCode 启动了约 60 秒的只读任务并展开面板，AI 通过原生辅助功能读取 a-watcher 真实界面及详情会话编号，再与日志元数据对照；未读取 VSCode 的聊天 UI 或输出提示词。
- **追踪验收未通过**：VSCode 会话后缀 `574dde88` 已记录 `task_complete`（本地时间 17:16:32），界面仍显示“正在工作”、最近记录 17:15；当前 Desktop 会话后缀 `ed9ad601` 日志仍持续写入工具事件，界面记录却停留在 17:11 并显示“状态待确认”。没有点击刷新来掩盖该差异，也没有把两端追踪宣称正常。

## 补充定位：持续打开日志的追加事件

先前真实 FSEvents 测试覆盖的是创建文件，并未覆盖持有写句柄的连续追加。新增 `nativeOpenLogAppendsRemainObservable` 保持写句柄打开，首轮追加完成事件能够被观察；排空事件并再次追加开始事件，原 v0.7.1 的目录 FSEvents 监听在 6 秒内没有推进状态，测试稳定失败。与本机实际观察相符：发现新文件成功，持续写入的同一文件后续状态停滞。

补充实现（v0.7.2）：

- FSEvents 继续负责目录发现与恢复；增加只读 `O_EVTONLY | O_CLOEXEC` 文件描述符与 DispatchSource vnode 写入通知，覆盖持有写句柄的日志追加。
- 启动即用索引游标种子注册已有日志，实时发现的日志也会注册；注册完成主动发出一次读取信号，补上快照与注册之间的写入空档。
- 每个来源最多保留 64 个文件监听，按文件修改时间优先保留近期文件；修改时间仅用于监听资源排序，不作为工作状态证据。取消、替换、删除及停用时关闭描述符。没有引入计时扫描、常驻 CLI、hooks、聊天正文缓存或新的第三方运行依赖。
- 被资源上限排除或描述符打开失败的文件仍走 FSEvents / 过期未知回退，不能声称无上限地精确追踪任意数量会话。
- `Check` 与 `Release` 两条 macOS CI 将直接执行 `Scripts/check.sh --native-file-events`，使创建与持有句柄追加两项原生集成检查都成为必跑检查。

补充实现已通过 46 项核心/原生行为检查及 8 项更新校验（54 项），Release 构建与 deep / strict 签名验证通过，diff 空白检查通过。原生持续追加测试直接使用与应用相同的索引种子 → 注册监听 → 事件驱动读取路径，而非直接读取文件来冒充通知成功。

已发布 v0.7.1 和本机安装版未被覆盖；需安装新的补丁版本后，再做两端真实任务验收。当前证据不支持“会话追踪已完全正常”。用户随后已明确授权发布 v0.7.2，并要求发布后结束今天的工作；本轮只发布和复验公开产物，不执行本机升级或两个客户端的追加验收，不修改旧 tag 或附件。

# a-watcher

轻量的 macOS AI Agent 观察工具。当前交付 **双 Agent 本地监控版本 0.4.2**：Codex 与 Claude Code 的近期会话、工作状态和本机 token 用量均已接入。仅 Claude 剩余额度实地查询暂缓，不读取其凭据或尝试登录。

采用 Swift + AppKit + SwiftUI，系统 sqlite3 保存派生记录；没有第三方运行依赖、WebView 或常驻 CLI helper。菜单栏在工作时显示工作会话数与持续波形，完成显示勾与未读点，打开面板清除当前未读。面板一行展示两种官方图标及各自 7 日剩余额度圆环，首行显示本机今日合计 token 数字。没有设置入口或 footer；点击面板右上角电源按钮或右键菜单栏可退出。统计默认每小时更新，状态按文件事件轻量更新。

## 运行

需要 macOS 14+、Swift 6 工具链。已验证环境为 Apple Silicon / macOS 26.5.2 / Swift 6.3.3；其他版本和 Intel 尚未实机验证。Codex 应已在本机登录。

```sh
bash Scripts/check.sh
bash Scripts/build.sh
open build/a-watcher.app
```

已构建的应用位于 `build/a-watcher.app`。本地 ad-hoc 签名用于开发验证，尚未进行 Developer ID 公证或对外发布。

自定义 Codex 数据根目录：

```sh
open -n build/a-watcher.app --args --codex-home /your/codex-home
```

Codex 默认读取 `CODEX_HOME` 或 `~/.codex`；Claude 默认读取 `CLAUDE_CONFIG_DIR` 或 `~/.claude`，可用 `--claude-home PATH` 覆盖；通过 Finder 启动时不应假定会继承终端环境。应用派生缓存默认存于 `~/Library/Application Support/a-watcher/`，可通过 `--data-dir` 指定隔离目录。

## 已实现

- 真实订阅额度与重置时间，按服务端实际窗口显示，不硬编码为 5h / 7d。
- 两种 Agent 的本地会话与工作状态；Claude 额外识别工具调用、明确的等待输入和错误。最后确认工作中但超过 3 分钟无新状态记录时显示待确认；这不表示已经完成或停工。明确完成保持勾选。
- 会话名固定为初始目录所属 Git 项目（无 Git 标记则使用初始目录）；最新目录只在详情展示，排序仍按状态与最近活动变化。旧缓存仅修复项目元数据，不重算 token。
- 两种 Agent 分别查看今日、7 日、30 日本机 token；Claude 将缓存读写归入输入合计，同一消息流式更新与子会话复制去重。
- SQLite 增量游标和事务；重复快照、归档副本、fork 继承与 compaction 的核对。
- 文件事件状态监听、每小时后台统计与额度刷新、手动刷新、失败退避、账户绑定与过期提示。
- 320 pt 原生弹层、亮暗外观、状态图例、悬停反馈、⌘R 刷新与 Esc 返回。

## 历史用量

点击面板首行的 token 数字 或右上角网格图标，打开 GitHub 风格的年度每日热力图。支持按年、Codex / Claude / 合计筛选；悬停显示准确数值，点击日期或使用日期选择器查看当天明细。未来日期单独显示，缺少记录不冒充真实零消耗。历史页仅查询已缓存账本，不触发额外日志扫描。

## 当前边界

这不是整个一期的完成声明。精确的等待批准/等待输入 hooks、通知、开机启动、费用估算和精确会话跳转尚未交付。不会修改现有 Codex hooks、信任设置或凭据。

目前跳过超过 2 MiB 的单行，尚未读取 `.jsonl.zst` 压缩归档；找不到父会话的 fork 保守排除。上述情况会明确显示 **部分统计**，数值是可确认小计。额度属于账户范围，本机用量属于当前数据根目录范围，不做混同。

## 诊断与检查

```sh
build/a-watcher.app/Contents/MacOS/watcherctl doctor
build/a-watcher.app/Contents/MacOS/watcherctl quota
build/a-watcher.app/Contents/MacOS/watcherctl scan --days 7
build/a-watcher.app/Contents/MacOS/watcherctl scan --provider claude --days 7
```

CLI 不输出凭据或邮箱。`--data-dir` 可将诊断缓存写入指定目录。`Scripts/check.sh` 使用自包含 Swift 行为检查器，不要求本机安装完整 Xcode。受外层沙箱限制时可设置 `AW_SPM_NO_SANDBOX=1`；这只影响 SwiftPM 构建，不改变应用权限。

- [Impeccable UI review 与修订](docs/design/2026-11-06-impeccable-review.md)
- [当前双 Agent 开发记录](docs/dev/dual-agent.md)
- [历史热力图与验证](docs/dev/history-heatmap.md)
- [首个 Codex 版本记录](docs/dev/codex-first.md)
- [官方图标来源](Resources/Brand/README.md)
- [阶段路线](docs/roadmap.md)
- [原始一期范围](docs/product/v1.md)
- [技术验证](docs/tech/spikes/2026-11-06-validation.md)
- [交互规范](docs/design/design.md)
- [资源目标](docs/tech/performance.md)

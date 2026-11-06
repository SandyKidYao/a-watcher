---
status: accepted
date: 2026-11-06
supersedes: 0001-native-macos.md
---

# ADR 0002：AppKit 外壳与 SwiftUI 面板

采用 Swift 6：AppKit 创建 NSStatusItem、管理 NSPopover，SwiftUI 描述面板；关闭弹层时释放 hosting controller。解析、存储与网络在 WatcherCore，界面不运行 WebView。

原因：实际相同内容的样机中，纯 AppKit 与混合实现打开后的 footprint 分别约 18.69 / 19.33 MiB，10 分钟空闲 CPU 均低于 0.1%；单轮结果不支持为资源占用排除 SwiftUI。用户认可完成验证后开发，并明确先接通 Codex、暂缓 Claude，当前实现采用此组合。

本次技术选择已采用，不代表完整一期或性能长期验收通过。完整应用首次短时检查约 154 秒、峰值 footprint 48.74 MiB、末次样本 33.16 MiB；其后的约 108 秒 CPU 均值约 0.0174%（单核）。该次未记录末次采样时面板可见性，因此不能当作严格的关闭弹层基准。

CPU 以 Mach timebase 125/3 校正，并用进程 CPU 时钟交叉核对。数据见 [完整应用短时记录](../../dev/codex-first-runtime.json)、[计时校验](../../dev/cpu-counter-check.json)。

代价：只优先保证 macOS；未来跨平台保留领域模型/解析测试边界，目前不创建 Rust FFI。精确等待状态 hooks、通知、费用估算和压缩归档支持在后续阶段补齐。

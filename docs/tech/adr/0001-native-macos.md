---
status: superseded
version: 1
date: 2026-11-06
direction_confirmed_at: 2026-11-06
superseded_by: 0002-appkit-shell-swiftui-panel.md
---

# ADR 0001：macOS 原生 Swift + AppKit

## 提案

一期使用 **Swift + AppKit**。状态图标、弹层、列表和设置均优先用原生控件与小量自绘；核心不引入 WebView。用 Swift Package Manager 管理纯核心与工具，应用以原生 `.app` 打包。建议 macOS 14+、Apple Silicon 先验证；Intel 兼容性另做构建与实机验收。

这是基于约束的工程判断，不是已经跑过 Swift / Rust 对照测试的结论。

## 候选比较

| 方案 | 对本项目的优势 | 代价 | 当前判断 |
| --- | --- | --- | --- |
| Swift + AppKit | 直接接菜单栏、窗口、系统事件、Keychain；不需桥接 UI 或渲染引擎 | 跨平台需重写平台层；手工布局比声明式 UI 多 | 推荐 |
| Swift + SwiftUI | 开发设置和复杂视图快，同样可做原生工具 | 需要控制视图生命周期与重绘；实际资源差异需测量 | 保留局部采用空间，不先引入 |
| Rust 核心 + 原生 AppKit UI | 解析核心将来可复用，原生界面仍可轻量 | 两套工具链、FFI、内存与线程边界；首期未证明收益 | 等性能瓶颈或第二平台明确后再评估 |
| Rust + Tauri | UI 跨平台较方便 | WebView 及其进程仍有成本，额度适配和系统接入并不会自动跨平台 | 不适合当前“极低常驻开销优先”的默认路线 |

Rust 没有垃圾回收并不保证整个 UI 程序更小；Swift 的原生栈也不自动保证低资源。对于本工具，更关键的是没有秒级全盘扫描、没有持续动画、没有常驻额度 CLI、没有全量日志驻内存。

Tauri 使用 WebView 的结构依据：[官方架构](https://tauri.app/concept/architecture/)。这里没有引用未经同条件验证的内存数字。

## 依赖提案

- 核心使用 Foundation、Dispatch、CoreServices；网络用 URLSession。
- 系统 sqlite3 存储增量游标和聚合，先用薄封装；无需引入通用 ORM。
- AppKit、UserNotifications、ServiceManagement、Security 负责界面与系统集成。
- 原生短生命周期 hook bridge，与应用共享事件格式；不依赖用户安装 Python、Node 或 shell 管线完成转发。
- 一期实现依赖尽量为零；测试和构建工具可作为开发依赖。自动更新框架是否需要在分发阶段再定。

## 未来跨平台的保留空间

领域模型、解析器和测试用例不依赖 AppKit。数据获取、文件监听、凭据与 UI 分为可替换适配器。保留可移植的数据格式与合成样本，先不创建尚无消费者的 FFI 或通用插件系统。

## 何时重新选择 Rust

同一份合成数据和同一原生 UI 下，Swift 核心在剖析后仍无法满足 CPU/内存预算；或第二平台成为明确交付目标。届时比较解析核心，不把语言与 UI 引擎成本混为一谈。

## 接受条件

用户已于 2026-11-06 确认整体方案，Swift + AppKit 作为已确认的实现方向。原生空壳与完整监控链路尚未实测达到资源门槛，按本 ADR 的性能准入条件，状态暂保持 proposed；不重复要求用户选择技术方向。

## 实测补充（2026-11-06）

[原生样机验证](../spikes/2026-11-06-validation.md)中，纯 AppKit 打开后 footprint 约 18.69 MiB，混合 SwiftUI 约 19.33 MiB；两者 10 分钟空闲 CPU 均低于 0.1%。单轮静态数据不支持为了内存排除 SwiftUI。后续实现建议 AppKit 管理菜单栏和弹层生命周期、SwiftUI 描述面板，再对完整应用验证。当前尚未启动正式开发，Claude 额度权限仍待处理。

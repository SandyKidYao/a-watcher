# 自动更新（2026-11-09）

## 用户行为

- 自 0.7.0 起引入 Sparkle 2.10.1，版本与 SwiftPM 校验和锁定在 `Package.resolved`。这是用户授权的唯一第三方运行依赖例外。
- 默认每天检查一次稳定版。右键菜单栏图标可“检查更新…”或切换“自动检查更新”；开关由 Sparkle 持久化，启动不重置用户选择。
- 找到更新后由 Sparkle 原生窗口提示，用户确认下载与安装，再替换并重启。禁止静默自动安装。
- 首页和 footer 不增加控件；菜单栏工作数与状态不受更新影响。更新只重启 a-watcher，不控制 Agent 进程。
- 禁用发布说明视图（不使用 WebView）、JavaScript（Sparkle 默认关闭）与系统信息统计。检查与下载使用 GitHub HTTPS，不读取或附加 Agent 凭据、用量或聊天。
- 导出预览、展示样例、动效导出、smoke 模式不启动更新器。缺少合法公钥时不启动更新器，右键入口明确显示尚未配置。

## 构建与信任

`Scripts/build.sh` 保留 Sparkle framework 的 symlink、权限和上游签名，放到 `Contents/Frameworks`；主程序使用相对 rpath。保留 framework 自带的按需安装组件，没有新增常驻 CLI 或后台轮询进程。主程序仍是本地 ad-hoc 签名，构建后执行 deep / strict 签名验证。Apple Developer ID 签名与公证仍未配置，Sparkle 更新签名不能代替公证。

`Resources/Info.plist` 内嵌 Ed25519 公钥。下载包在解压前验证；清单也要求签名，签名失败不会随时间自动放宽。切勿随意替换公钥：已有安装版本信任的是其内嵌旧公钥。当前严格验签与 ad-hoc 分发下，丢失私钥可能需要用户手动重新安装。

更新清单地址固定为：

`https://github.com/SandyKidYao/a-watcher/releases/latest/download/appcast.xml`

清单中的安装包 URL 固定到具体 tag，不能使用 latest 安装包链接。CI 使用稳定 tag 的版本同时写入 `CFBundleShortVersionString` 与 `CFBundleVersion`，避免重跑工作流改变版本顺序。0.6.0 及更早版本没有更新器；用户需手动安装一次 0.7.0。0.7.0 起持续使用递增的 X.Y.Z，不再切回旧整数 build 计数。

## 签名密钥与发布前准备

本机已使用官方 `generate_keys --account dev.awatcher.app` 创建专用更新签名密钥，私钥保存在登录钥匙串，公钥已写入 plist。`bash Scripts/setup-updates.sh` 可在原机器重复运行；它不会覆盖不同的既有公钥，也不导出私钥。不要在新机器运行后把新的公钥直接覆盖旧公钥，应迁移原密钥。

首次公开发布前，仓库管理员须把同一私钥配置到仓库 Actions secret `SPARKLE_PRIVATE_KEY`，并保留安全备份。以下操作会导出私钥并上传 GitHub，仅在管理员明确授权后运行；不要粘贴私钥到聊天、提交到仓库或输出到日志：

```bash
# 先运行 setup-updates.sh，取得校验过的官方工具。
(
  set -euo pipefail
  umask 077
  AW_SECRET_DIR="$(mktemp -d)"
  trap 'rm -rf "$AW_SECRET_DIR"' EXIT
  .build/sparkle-tools/2.10.1/bin/generate_keys --account dev.awatcher.app -x "$AW_SECRET_DIR/private-key"
  gh secret set SPARKLE_PRIVATE_KEY --repo SandyKidYao/a-watcher < "$AW_SECRET_DIR/private-key"
)
```

2026-11-09 用户已明确授权将专用更新签名私钥存入 GitHub Actions Secret 并发布一次。已核对私钥对应应用内嵌公钥，将其存入 `SandyKidYao/a-watcher` 的 `SPARKLE_PRIVATE_KEY`，并删除权限受限的临时导出文件。私钥未写入仓库或日志。本次计划发布 v0.7.0，流水线须完成全部签名检查后方可上传产物。

## 发布流水线

1. 只处理稳定 `vX.Y.Z` tag，跳过预发布 release；手动运行时选择稳定 tag。发布顺序应递增，不应把旧版本重新标成 latest。
2. 预检 secret 与公钥，缺项立即失败。核心检查与更新校验测试通过后构建 app。
3. `bash Scripts/package-update.sh vX.Y.Z` 只打包已构建且版本匹配的 app，使用与框架同版本的官方工具生成签名清单。工具下载使用固定 SHA-256 校验。
4. 本地签名读取专用钥匙串；CI 只通过 stdin 传递 secret，不放入命令行。独立 CryptoKit 检查使用应用内嵌公钥验证清单签名、安装包签名、字节长度、版本和具体 tag URL，失败不复制到 dist。验证阶段不需要访问私钥。
5. 上传 zip、`appcast.xml`、`SHA256SUMS.txt`。只有完整签名包通过所有检查，才进入现有 GitHub Release 上传步骤。安装包本身带签名的清单是可信校验来源；SHA256SUMS 只是便于人工核对。

本地验证产物位于忽略目录 `dist/`；重新打包不等于发布。`Scripts/check.sh` 包含原有核心检查和独立的 8 项更新校验检查，不读取钥匙串或联网（首次 SwiftPM 解析需下载框架）。

## 验证范围

2026-11-09 本地结果：

- 原有核心行为 38 项通过；新增更新校验 8 项通过，覆盖正确签名包、等长度篡改、错误密钥、错误版本、错误长度、错误 URL、缺少包签名、清单篡改。
- Release 构建通过，主程序相对 rpath 与 Sparkle 动态链接已检查；应用包 deep / strict 签名验证通过，包含 Sparkle 及第三方授权文本。
- `dist/a-watcher-v0.7.0-macos-arm64.zip` 与 `dist/appcast.xml` 已使用真实本机签名密钥生成；官方工具和独立 CryptoKit 验证通过。官方 `sign_update --verify` 拒绝了修改后的清单；最终独立验证也验证了真实清单与安装包。产物未发布。
- 通过 `--smoke-seconds 5` 在正常桌面会话启动并自行退出，退出码为 0，验证打包框架可加载；该模式不启动更新器。外层受限沙箱内直接运行 AppKit 退出码为 134，随后在正常桌面会话验证成功。
- shell 语法、plist 与 diff 空白检查通过。

发布前仍需在真实稳定 Release 上完成一次“较旧安装 → 检查更新 → 下载 → 安装 → 重启”的完整验收，并验证安装目录不可写、网络不可用、取消与跳过更新等交互。本地签名、启动与脚本检查不能冒充鼠标、键盘或 VoiceOver 验收。

参考：[Sparkle 集成](https://sparkle-project.org/documentation/)、[程序化初始化](https://sparkle-project.org/documentation/programmatic-setup/)、[配置与签名策略](https://sparkle-project.org/documentation/customization/)。

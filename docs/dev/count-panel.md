# 0.4.0 计数动效与精简面板

依据用户 2026-11-06 标注截图直接调整；继续使用 Impeccable 的 Operate、animate 与 craft-floor 指引。最新用户意见覆盖先前禁止圆环、有限工作动画和保留 footer 的约定。

- 删除设置入口和页面。退出保留在菜单栏右键菜单。
- 今日两种 Agent 本机 token 合计移到首行，仅显示简写数字与必要的部分统计标记；无 footer。数字和网格均可进入历史。
- 7 日剩余额度以静态圆环表示；悬停和详情保留准确百分比。虚线环带短横表示未知，不表示零。Claude 额度仍未查询。
- 工具调用与模型执行都以工作波形展示；内部原始状态仍供解析和完成检测使用。
- 菜单栏显示工作会话数与持续波形，等待、完成、错误、过期记录不计数。1 位和 2 位数自适应宽度；完成保留原未读提醒。
- Core Animation 图层播放，不增加逐帧 SwiftUI timer 或日志扫描。减少动态效果、低电量和屏幕休眠时静止；列表消失/卸载时移除动画。

## 验证

30 项核心行为检查通过。新增工作计数检查覆盖工具计入、等待/错误/过期排除、恢复工作与部分完成。Release 构建及 codesign 校验通过。

`build/count-preview/` 已查看原生亮暗首页、额度、长项目名和菜单栏 1/12 数字渲染；首页约 320 × 308 pt，无 footer 截断。历史及原有缓存统计保留。

`build/count-motion/working-motion.gif` 是原生 Core Animation presentation layer 的合成示例，左侧菜单栏，右侧列表。20 次采样验证两者有实际变化、强制静态时保留计数、无需新会话即可恢复、完成/移除后停止。结果为 `count-motion-check.json`。未更改系统辅助功能设置；没有声称完成实际鼠标/VoiceOver 测试。

`count-runtime.json` 记录约 35 秒、真实本机记录、面板关闭的短测：工作计数 1/3 时观察到动画；后段应用自身 CPU 约单核 0.274%，末次 physical footprint 15.86 MiB，RSS 22.45 MiB。CPU 使用本机 Mach timebase 125/3 换算。未计入 WindowServer/GPU，不代替 10 分钟以上或长期资源验收。

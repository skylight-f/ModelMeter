# Feature-002: 1.0.1 Runtime 展示配置与趋势图 Tooltip

| 项         | 值         |
| ---------- | ---------- |
| Phase      | dev        |
| 优先级     | P1         |
| 负责人     | <待填>     |
| 目标日期   | <待填>     |
| 涉及子系统 | Sources/CodexUsageWidget, docs, Resources |

## 一句话描述

在 1.0.1 中默认展示 Codex 与 Claude Code 两个 Runtime，允许用户在设置中选择要展示的 Runtime，并为用量趋势中的近 7 日和半年图表补充 hover 详情浮窗。

## 背景

codexU 已从单一 Codex 统计扩展到 Codex 与 Claude Code 两个 Runtime。默认同时展示两者可以让新用户直接感知多 Runtime 能力，但实际使用中，用户可能只使用 Codex、只使用 Claude Code，或希望暂时隐藏某个 Runtime 来减少界面干扰。

如果展示范围不能配置，菜单栏 Runtime 浮窗、主窗口顶部 Runtime 切换、趋势/项目/工具等面板都会持续出现用户不关心的 Runtime。1.0.1 需要补齐一个轻量设置项，让用户控制哪些 Runtime 出现在 UI 中，同时通过“至少选择一个”的约束避免应用进入无可展示数据范围的状态。

另外，用量趋势中的近 7 日图表和半年用量图表当前只提供静态视觉反馈。用户鼠标 hover 到具体日期或图表节点时，无法看到当天 token、拆分口径、Runtime 范围或其他更细信息，只能依赖图形大致判断趋势。1.0.1 需要补充轻量 tooltip，让趋势图既适合扫视，也能在需要时查看单点详情。

## 关键决策

- 默认启用 Codex 与 Claude Code 两个 Runtime；没有历史配置的新安装与升级用户均展示两者。
- 设置窗口新增 Runtime 展示配置，支持分别勾选 Codex 与 Claude Code。
- 最少必须选择一个 Runtime；当用户尝试关闭最后一个已选 Runtime 时，应阻止保存或保持原选择，并给出清晰提示。
- Runtime 展示配置应影响菜单栏 Runtime 浮窗、主窗口顶部 Runtime 切换以及依赖当前 Runtime 范围的主要面板。
- 用量趋势中的近 7 日图表和半年用量图表需要支持鼠标 hover 详情浮窗。
- Tooltip 应至少说明当前点位对应的日期、Runtime 范围、总 token 和可用的 token 拆分；缺失数据时使用用户可理解的不可用说明。
- Tooltip 不应改变图表布局，不应遮挡当前 hover 点位的主要视觉反馈，并需要跟随浅色/深色外观。

## 开放问题

- 隐藏某个 Runtime 仅影响 UI 展示，还是也停止后台读取与聚合该 Runtime 的本地数据？
- 当当前选中的 Runtime 被隐藏时，主窗口应自动切到剩余 Runtime，还是在保存设置后提示用户确认切换？
- 近 7 日图表和半年图表 tooltip 的详细字段是否需要区分：例如近 7 日展示输入/缓存输入/输出拆分，半年图表展示当日总量、活跃线程数和相对强度等级？
- 是否需要为键盘聚焦或触控板点击提供等价的详情查看方式？

## 上下文索引

- 原始素材见 [context/_INDEX.md](context/_INDEX.md)

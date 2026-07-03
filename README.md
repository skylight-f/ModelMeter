# AgentDesk

[English](README.en.md)

AgentDesk 是一个 macOS 桌面小组件，用于监控多种 AI 编程工具的 token 用量、费用和任务状态。支持 Codex、MimoCode 等工具，自动发现数据源，提供实时的用量分析和成本追踪。

![AgentDesk 桌面小组件截图](docs/screenshot-0.3.0.png)

## 适合谁

- 使用 OpenAI Codex、MimoCode、Claude Code 等 AI 编程工具的开发者
- 需要追踪 AI 工具使用成本和效率的团队
- 想在桌面随时查看 AI 用量状态的用户

## 核心功能

### 用量概览
- **额度环形图**：展示 5 小时和 7 天额度的剩余比例和重置时间
- **Token 统计**：今日、近 7 天、累计的 token 用量，细分未缓存、缓存、输出
- **羊毛进度**：按 API 价格估算本月使用价值，追踪订阅成本回收

### 模型用量分析
- **详细表格**：每个模型的 token 用量、缓存率、费用、输出速度
- **价格信息**：支持 USD/CNY 双货币，自动识别国内外模型
- **搜索过滤**：按模型名称或提供商快速搜索
- **点击详情**：点击任意模型查看详细统计

### 用量趋势图
- **7 天趋势**：堆叠柱状图展示每日各模型用量
- **颜色区分**：不同模型使用不同颜色
- **Hover 交互**：鼠标悬停显示模型名称和 token 数

### 任务看板
- **四列布局**：进行中、待处理、定时、完成
- **自动分类**：根据活跃时间自动判断任务状态
- **状态标签**：High/Active/Medium/Idle/Cron/Done

### 数据源自动发现
- **智能检测**：自动扫描本地数据库，发现可用的数据源
- **多源支持**：Codex、MimoCode、Claude Code、Cursor、Windsurf
- **一键切换**：下拉菜单快速切换数据源

### 桌面集成
- **始终可见**：默认贴在桌面层，随时查看
- **快捷键切换**：`Command + U` 一键切换前台/桌面层
- **菜单栏图标**：点击快速切换显示状态

### 国际化与主题
- **双语支持**：中文/英文界面，手动切换
- **外观模式**：自动/浅色/深色，跟随系统或手动设置

## 功能详情

### 模型价格支持

| 提供商 | 模型示例 | 货币 | 输入价格 | 缓存价格 | 输出价格 |
|--------|----------|------|----------|----------|----------|
| OpenAI | gpt-5.4, gpt-5.4-mini | USD | $2.50 | $0.25 | $15.00 |
| MimoCode | mimo-auto, mimo-v2.5 | CNY | ¥2.00 | ¥0.50 | ¥8.00 |
| DeepSeek | deepseek-v4-pro | CNY | ¥4.00 | ¥1.00 | ¥16.00 |
| Qwen | qwen3.7-plus, qwen3.7-max | CNY | ¥0.80 | ¥0.20 | ¥4.00 |
| GLM | glm-5.2 | CNY | ¥2.00 | ¥0.50 | ¥8.00 |

### 输出速度统计

从数据库中计算每个模型的平均输出速度（tokens/秒）：

| 模型 | 平均速度 |
|------|----------|
| qwen3.7-max | ~40 tokens/s |
| deepseek-v4-pro | ~35 tokens/s |
| qwen3.7-plus | ~28 tokens/s |
| mimo-v2.5 | ~25 tokens/s |
| gpt-5.4 | ~13 tokens/s |

## 快捷键和操作

- `Command + U`：在桌面层和前台层之间切换小组件
- 菜单栏仪表图标：点击执行和 `Command + U` 相同的操作
- 顶部外观切换：在自动、浅色和深色模式之间切换
- 顶部 `中 | EN`：切换中文或英文界面
- 右上角刷新按钮：立即刷新所有数据
- 右上角切换按钮：切换前台/桌面层
- 右上角关闭按钮：退出 AgentDesk
- 拖动小组件背景：移动小组件位置
- 点击模型行：查看该模型的详细统计

## 安装

### 从 GitHub Release 下载

- Apple Silicon：`AgentDesk-<version>-mac-arm64.dmg`
- Intel：`AgentDesk-<version>-mac-x86_64.dmg`

1. 打开 DMG
2. 将 `AgentDesk.app` 拖到 `Applications` 文件夹
3. 从 `Applications` 打开 AgentDesk
4. 按下面的 **首次安装：隐私与安全** 步骤完成手动放行

### 首次安装：隐私与安全

AgentDesk 目前通过 GitHub Release 的 DMG 安装包分发，不经过 Mac App Store。第一次打开时，macOS 可能会拦截，需要手动允许：

1. 打开 `AgentDesk.app` 一次。如果系统提示无法打开，先取消弹窗
2. 打开 **系统设置 > 隐私与安全性**
3. 在 **安全性** 区域找到 `AgentDesk.app`，点击 **仍要打开**
4. 使用 Touch ID 或密码确认，然后点击 **打开**

也可以在 Finder 中右键点击 `AgentDesk.app`，选择 **打开**，再确认系统安全提示。

## 运行要求

- macOS 14 或更新版本
- 本机已安装至少一个支持的 AI 编程工具（Codex、MimoCode 等）
- 已登录相关账户，额度信息才会显示
- 从源码构建时需要 Xcode Command Line Tools

## 从源码构建

```sh
make build
```

运行：

```sh
make run
```

安装到 `/Applications`：

```sh
make install
```

检查本机数据源输出：

```sh
make probe
```

## 打包 DMG

```sh
make release
```

`make release` 会按当前构建机器的架构输出安装包。也可以显式打包指定架构：

```sh
make release-arm64
make release-intel
make release-all
```

产物会写入 `dist/`，例如：

```text
dist/AgentDesk-0.3.0-mac-arm64.dmg
dist/AgentDesk-0.3.0-mac-arm64.dmg.sha256
dist/AgentDesk-0.3.0-mac-x86_64.dmg
dist/AgentDesk-0.3.0-mac-x86_64.dmg.sha256
```

Developer ID 签名和 Apple notarization 流程见 [DISTRIBUTION.md](DISTRIBUTION.md)。

## 数据来源

### Codex
- 账户与额度：`codex app-server` 的 `account/read`、`account/rateLimits/read`、`account/usage/read`
- 本机 token 总量：`~/.codex/state_5.sqlite`
- 精细 token 拆分：`~/.codex/sessions/**/rollout-*.jsonl`
- 任务看板：本机 SQLite 中未归档和今日归档的 Codex 线程
- 定时任务：`~/.codex/automations/**/automation.toml`

### MimoCode
- 用量数据：`~/.local/share/mimocode/mimocode.db`
- 模型和提供商：从 `message` 表的 `data` JSON 中提取
- 吞吐量计算：基于 `time.created` 和 `time.completed` 字段

### 其他数据源
- Claude Code：`~/.claude/state.db`
- Cursor：`~/.cursor/state.vscsqlite`
- Windsurf：`~/.codeium/windsurf/state.vscsqlite`

## 项目结构

```
Sources/CodexUsageWidget/
├── main.swift          # 入口点、AppDelegate、AppKit 容器
├── Models.swift        # 数据模型定义
├── Providers.swift     # 数据源读取、UsageStore
├── Views.swift         # 所有 SwiftUI 视图组件
└── Utils.swift         # 工具函数、格式化、JSON 处理
```

## 常见问题

### AgentDesk 是官方 OpenAI 产品吗？

不是。AgentDesk 是一个非官方的本地 macOS 工具，用于读取多种 AI 编程工具的本地数据。

### AgentDesk 会上传我的数据吗？

不会。AgentDesk 只在本机读取数据，不上传任何 usage、线程或账户数据到第三方服务。

### 支持哪些 AI 编程工具？

目前支持：
- OpenAI Codex
- MimoCode
- Claude Code（即将完善）
- Cursor（即将完善）
- Windsurf（即将完善）

### 为什么有些模型显示 $0.00 费用？

这是因为该模型的定价信息尚未收录。AgentDesk 会显示估算费用，有实际价格的模型会显示准确金额。

### 支持 Intel Mac 吗？

支持。Intel Mac 下载 `AgentDesk-<version>-mac-x86_64.dmg`。从源码打包时使用 `make release-intel`。

## License

MIT. See [LICENSE](LICENSE).

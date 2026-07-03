# AgentDesk Design System

本文档定义 AgentDesk macOS 桌面看板的视觉设计体系。目标是让界面从“有玻璃效果的自定义看板”升级为更接近 Apple 原生设计语言的工业级系统：中性材质建立层级，高饱和品牌色负责关键强调，状态色和数据色保持语义清晰。

## 设计目标

- Apple 原生感：优先使用系统文本层级、系统材质、动态颜色和 SF Symbols，避免网页式大面积色块。
- 品牌一致性：主色贴合 AgentDesk logo 的蓝紫高饱和渐变，而不是当前偏青绿的数据仪表盘风格。
- 高信息密度：保持当前看板的信息容量，但让颜色只承担状态、数据和品牌强调，不干扰阅读。
- 动态适配：Light、Dark、High Contrast、Reduce Transparency、不同壁纸背景下都要稳定可读。
- 工业级维护：禁止组件内散落硬编码 RGB。所有颜色必须来自统一 token。

## 当前诊断

### 已有优势

- 使用 `.primary`、`.secondary`、`.tertiary` 作为文本层级，方向正确。
- macOS 26 使用 `GlassEffectContainer`，低版本使用 `NSVisualEffectView`，材质路线成立。
- 信息架构清楚：额度、token、趋势、任务看板有明确区域。
- SF Symbols 使用统一，和 macOS 原生生态一致。

### 主要问题

- 颜色没有 token 化：当前 Swift 文件中存在 21 组硬编码 `Color(red:green:blue:)`。
- 语义复用混乱：绿色同时代表 5h 额度、缓存、成功、正收益；橙色同时代表进行中、警告、输出、亏损。
- 主色偏离 logo：logo 主色是蓝紫高饱和渐变，界面主视觉却偏青绿和灰蓝。
- 材质叠加偏重：`Color.white.opacity(...)` 被大量用于卡片和轨道，在复杂壁纸上容易变脏或失去边界。
- 大面积染色过多：任务列和图表背景使用色彩填充时，容易削弱 Apple 风格的“安静内容层 + 克制强调”。

## Apple 风格原则

Apple 的颜色和材质体系强调适配性、语义和层级。落地到 AgentDesk，应遵循以下规则：

1. 先材质，后颜色。窗口、分组、卡片的层级由 material、fill、separator、shadow 建立，颜色只作为强调。
2. 色彩有职责边界。Brand、Status、Data、Task、Surface 分开维护，不跨角色复用。
3. 饱和但克制。高饱和色可以用于 logo、主额度环、关键数值和主操作，不用于大面积背景。
4. 避免玻璃叠玻璃。外层可以是 Liquid Glass 或 visual effect，内容卡片应使用薄 fill、separator 和 vibrancy，避免每层都套强玻璃。
5. 默认状态安静，交互状态发光。静态界面低对比、低噪音；hover、press、refresh、warning 才提高亮度或边框。
6. 文字不透明。文本尽量使用系统语义色，不使用自定义半透明色降低可读性。

官方参考：

- Apple HIG Color: https://developer.apple.com/design/human-interface-guidelines/color
- Apple HIG Materials: https://developer.apple.com/design/human-interface-guidelines/materials
- Apple HIG Dark Mode: https://developer.apple.com/design/human-interface-guidelines/dark-mode
- WWDC25 Liquid Glass: https://developer.apple.com/videos/play/wwdc2025/219/

## Logo 色彩抽样

从 `Resources/AgentDesk-icon.png` 抽取到的主要可见色：

| Role | Hex | 用途 |
| --- | --- | --- |
| Logo Blue Deep | `#1F59ED` | 品牌主色、主按钮、重点额度 |
| Logo Blue Vivid | `#2866F7` | 默认主强调色 |
| Logo Blue Light | `#4778FB` | 渐变中段、hover、图表高亮 |
| Logo Lavender | `#A195F4` | 辅助品牌色、7d 额度 |
| Logo Pink Violet | `#DAA3FA` | 高光、halo、轻量装饰 |
| Logo Pale Highlight | `#EAC7FB` | 高光边缘，不用于正文或状态 |

推荐主渐变：

```text
Codex Aurora: #1F59ED 0% -> #4778FB 42% -> #A195F4 72% -> #DAA3FA 100%
```

使用限制：主渐变只用于 logo 呼应、额度主环、主操作强调和极少量装饰高光。任务列、普通卡片、正文区域不得大面积使用渐变。

## 色彩 Token

### Brand

| Token | Light | Dark | 用途 |
| --- | --- | --- | --- |
| `brand.primary` | `#2866F7` | `#5E8CFF` | 主品牌色、主要强调 |
| `brand.primaryStrong` | `#1F59ED` | `#7BA0FF` | 主按钮 pressed、额度主环深色段 |
| `brand.secondary` | `#8B6DFF` | `#A195F4` | 辅助品牌色、7d 额度 |
| `brand.highlight` | `#DAA3FA` | `#E7B8FF` | 高光、ring glow、稀疏装饰 |
| `brand.tintFill` | `#2866F7` at 10% | `#5E8CFF` at 16% | 品牌轻背景 |
| `brand.tintStroke` | `#2866F7` at 22% | `#7BA0FF` at 28% | 品牌边框 |

### Surface

Surface 不建议用固定 HEX 实现，SwiftUI/AppKit 应优先使用系统材质和语义色。下表是设计意图。

| Token | 推荐实现 | 用途 |
| --- | --- | --- |
| `surface.window` | `NSVisualEffectView.material = .hudWindow` 或 `GlassEffect .regular` | 外层窗口 |
| `surface.section` | `Color.primary.opacity(0.045)` + subtle stroke | 大区域分组 |
| `surface.card` | `Color.white.opacity(0.13)` light glass / dynamic fill | 指标卡片 |
| `surface.cardElevated` | card fill + stronger separator + soft shadow | 任务卡片 |
| `surface.separator` | `Color.primary.opacity(0.08)` | 分割线和描边 |
| `surface.track` | `Color.primary.opacity(0.10)` | 进度条/环形轨道 |
| `surface.hover` | `Color.primary.opacity(0.08)` | hover 背景 |
| `surface.pressed` | `Color.primary.opacity(0.12)` | pressed 背景 |

Reduce Transparency 开启时，`surface.window` 和 `surface.card` 必须提高不透明度，避免背景干扰正文。

### Text

| Token | 推荐实现 | 用途 |
| --- | --- | --- |
| `text.primary` | `.primary` | 主要数值、标题 |
| `text.secondary` | `.secondary` | 标签、说明、次要元数据 |
| `text.tertiary` | `.tertiary` | 空状态、快捷键、弱提示 |
| `text.onAccent` | white or black dynamic | 彩色按钮或高饱和 chip 上的文字 |

规则：正文和关键数值不得使用半透明品牌色；小字号文本优先走系统 label 色。

### Status

采用接近 Apple 系统色的高饱和状态色，但只用于小面积图标、圆点、chip、边框。

| Token | Light | Dark | 用途 |
| --- | --- | --- | --- |
| `status.success` | `#34C759` | `#30D158` | 成功、可用、完成 |
| `status.info` | `#007AFF` | `#0A84FF` | 信息、默认链接、普通提示 |
| `status.warning` | `#FF9F0A` | `#FF9F0A` | 需要注意、进行中 |
| `status.danger` | `#FF3B30` | `#FF453A` | 错误、额度危险 |
| `status.neutral` | `#8E8E93` | `#98989D` | 待处理、未知、禁用 |

规则：warning 和 active 可以同色，但 error/danger 必须独立为红色；success 不再承担品牌主色职责。

### Data

数据色必须和状态色分离。图表和 token 拆分优先使用可区分的冷暖组合。

| Token | Hex | 用途 |
| --- | --- | --- |
| `data.quotaPrimary` | `#2866F7` | 5h 额度，贴合 logo 主色 |
| `data.quotaPrimaryHighlight` | `#7BA0FF` | 5h 额度高光 |
| `data.quotaSecondary` | `#8B6DFF` | 7d 额度，品牌紫 |
| `data.quotaSecondaryHighlight` | `#DAA3FA` | 7d 额度高光 |
| `data.input` | `#0A84FF` | 未缓存输入 |
| `data.cached` | `#8B6DFF` | 缓存命中；缓存占比通常很高，使用品牌紫避免绿色成为主视觉 |
| `data.output` | `#FF9F0A` | 输出 token |
| `data.reasoning` | `#BF5AF2` | reasoning 输出，预留 |
| `data.zero` | `#8E8E93` at 35% | 0 值、空柱 |

绿色只保留给成功、完成等小面积状态语义，不用于可能占据大面积的数据条。

### Task Board

任务看板应使用“低饱和背景 + 高饱和小面积标识”。

| Kind | Accent | Fill | Icon |
| --- | --- | --- | --- |
| Active | `#FF9F0A` | accent at 7% | `record.circle` |
| Pending | `#8E8E93` | accent at 6% | `circle` |
| Scheduled | `#8B6DFF` | accent at 7% | `clock` |
| Done | `#34C759` | accent at 7% | `checkmark.circle.fill` |

规则：

- 列背景只用 6% 到 8% 透明度。
- 任务卡片背景保持中性，不随列状态大面积染色。
- chip 可以使用 13% 到 16% 透明度填充，文字使用 accent 本色。
- 任务卡片内状态色面积控制在图标、chip、avatar 三处以内。

## 组件用色规范

### Window

- 外层使用系统材质，不手动铺满品牌渐变。
- 圆角保持 24px，与当前窗口一致。
- 外层 stroke 使用 `Color.white.opacity(0.16)` 或系统 separator 的动态替代，但不要超过 1px 视觉重量。

### Header

- logo 保持原图，不额外加背景色。
- `AgentDesk` 使用 `.primary`，不使用品牌蓝，避免与 logo 争夺焦点。
- account、plan pill 使用中性 fill。只有需要提示升级、错误或未登录时才引入状态色。
- icon button 默认中性，hover 或 active 时可使用 `brand.tintFill`。

### Quota Ring

- 5h 外环使用 `data.quotaPrimary` 到 `data.quotaPrimaryHighlight`。
- 7d 内环使用 `data.quotaSecondary` 到 `data.quotaSecondaryHighlight`。
- 轨道使用 `surface.track`，不要使用深青色轨道。
- 额度低于 15% 时，外环可切换为 `status.danger`，但保留 ring 结构和轨道。
- 5h/7d 使用比例只在环形图表达，不再额外展示横向窗口进度条；重置时间用两行小型摘要放在环形图下方。

### Token Cards

- 卡片背景使用 `surface.card`，不要因为指标类型改变卡片底色。
- 指标标题图标使用中性图标底；拆分条使用 `data.input / data.cached / data.output`。
- 今日、近 7 天、累计三个卡片不再分别用不同主色点，避免伪装成不同状态。

### Progress

- “Value progress” 使用本月 API 等效价值作为当前值，进度条终点是 `2亿 tokens/天 * 30天` 按加权均价折算的满额月价值。
- 当前加权均价使用 Codex-heavy token mix：30% 未缓存输入、50% 缓存输入、20% 输出；按当前 `chat-latest` 参考价折算为 `$7.75/M tokens`，满额月价值约 `$46,500`。
- 进度条必须保留 Plus、Pro100、Pro200 三个订阅成本刻度，并显示满额月价值；标签不重复展示金额。
- 由于 `$20/$100/$200` 相对满额月价值很小，进度条使用分段压缩轴：订阅成本段占前 28%，Pro200 到满额月价值占剩余长度。
- 底部不展示“距某档还差多少”和计价公式，避免信息噪音；计价口径保留在设计文档和代码注释中。
- 金额数值保持 `.primary`，不要随状态改成橙色或绿色；状态色只作用于图标、条、刻度和说明文本。

### Mini Trend

- 今日柱使用 `brand.primary`。
- 历史柱使用 `brand.primary` at 55%。
- 0 值柱使用 `data.zero`。

### Task Cards

- 卡片背景使用中性 elevated surface。
- 标题 `.primary`，详情 `.secondary`，时间 `.tertiary`。
- 状态 chip 使用对应 task accent。
- 不用整张卡片染成状态色，避免看板变成彩色块堆叠。

## 饱和版 Apple 风配色方案

这套方案比当前界面饱和度更高，但仍按 Apple 风格控制使用面积。

| Role | Token | Hex |
| --- | --- | --- |
| Brand Main | `brand.primary` | `#2866F7` |
| Brand Deep | `brand.primaryStrong` | `#1F59ED` |
| Brand Light | `brand.primaryLight` | `#5E8CFF` |
| Brand Purple | `brand.secondary` | `#8B6DFF` |
| Brand Violet Highlight | `brand.highlight` | `#DAA3FA` |
| System Blue | `status.info` | `#0A84FF` |
| System Green | `status.success` | `#30D158` |
| System Orange | `status.warning` | `#FF9F0A` |
| System Red | `status.danger` | `#FF453A` |
| System Purple | `data.reasoning` | `#BF5AF2` |
| Neutral Gray | `status.neutral` | `#98989D` |

推荐实际界面比例：

- 70% 到 80%：中性材质、系统文本、透明分层。
- 12% 到 18%：低透明品牌或状态 tint。
- 4% 到 8%：高饱和实色，例如环形进度、chip、图表柱、状态点。
- 低于 2%：粉紫高光和 halo。

## 代码落地建议

### 1. 建立统一 Palette

`main.swift` 必须通过 `WidgetPalette` 建立集中 token，而不是继续增加组件内散色：

```swift
private enum WidgetPalette {
    static let brandPrimary = Color(red: 0.157, green: 0.400, blue: 0.969) // #2866F7
    static let brandStrong = Color(red: 0.122, green: 0.349, blue: 0.929) // #1F59ED
    static let brandSecondary = Color(red: 0.545, green: 0.427, blue: 1.000) // #8B6DFF
    static let brandHighlight = Color(red: 0.855, green: 0.639, blue: 0.980) // #DAA3FA

    static let statusSuccess = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let statusInfo = Color(red: 0.039, green: 0.518, blue: 1.000) // #0A84FF
    static let statusWarning = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A
    static let statusDanger = Color(red: 1.000, green: 0.271, blue: 0.227) // #FF453A
    static let statusNeutral = Color(red: 0.596, green: 0.596, blue: 0.616) // #98989D
}
```

`WidgetPalette` 同时负责 light/dark surface、card、control、stroke 的动态透明度。新增组件时优先复用 `sectionBackground()`、`cardBackground(cornerRadius:elevated:)`、`WidgetPalette.surfaceTrack` 和现有 brand/status/data token。

### 1b. 外观模式

顶部外观切换由 `WidgetThemeMode` 管理：

- `system`：默认值，清空 `NSApp.appearance` 并跟随 macOS 系统外观。
- `light`：设置 `.aqua`，并通过 SwiftUI `preferredColorScheme(.light)` 同步内容层。
- `dark`：设置 `.darkAqua`，并通过 SwiftUI `preferredColorScheme(.dark)` 同步内容层。

新增页面或组件不得自行保存外观偏好；只读取当前 `colorScheme` 并使用 `WidgetPalette` 返回的动态 surface。

### 2. 替换现有颜色

| 当前用途 | 当前色 | 新 token |
| --- | --- | --- |
| 5h 额度 | `#149E7A` | `data.quotaPrimary` |
| 5h 高光 | `#61F2BA` | `data.quotaPrimaryHighlight` |
| 7d 额度 | `#2E70B8` | `data.quotaSecondary` |
| 7d 高光 | `#7AC7FF` | `data.quotaSecondaryHighlight` |
| 缓存 token | `#149E7A` | `data.cached`，迁移到品牌紫 |
| 输出 token | `#EB941F` | `data.output` |
| active task | `#E0800D` | `task.active` |
| scheduled task | `#128C4F` | `task.scheduled` |
| done task | `#126EC7` | `task.done` |
| danger | `#D1382E` | `status.danger` |

### 3. 分阶段迁移

1. 第一阶段：新增 `WidgetPalette`，替换所有硬编码 RGB，不改变布局。
2. 第二阶段：调整 quota ring 和 token split 的语义色，完成品牌主色迁移。
3. 第三阶段：调整任务看板列背景和 chip，让大面积色彩降噪。
4. 第四阶段：为 Reduce Transparency 和 Increased Contrast 增加动态 surface。
5. 第五阶段：在浅色壁纸、深色壁纸、桌面图片复杂背景下截图验证。

## 验收标准

- 代码中组件内部不再出现新的 `Color(red:green:blue:)`。
- 主视觉从青绿迁移到 logo 蓝紫，绿色只用于成功或完成等小面积状态语义。
- 任何状态色都不作为普通品牌色使用。
- 任务看板列背景不会比任务卡片更抢眼。
- 正文和数值在浅色、深色、复杂壁纸下都能稳定阅读。
- 开启 Reduce Transparency 后，卡片和窗口仍有明确层级。
- 颜色不是唯一信息通道，图标、文本、位置也能表达状态。

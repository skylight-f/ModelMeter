# codexU v1.0.0-beta02

这是 codexU 从“桌面常驻小组件”升级为标准 macOS App 的 beta 版本。主窗口现在是正常的 macOS 窗口，支持 Dock、系统窗口控制、最小化、关闭后继续在菜单栏运行，并保留菜单栏状态项和快捷键唤起能力。

## 主要更新

- 主界面升级为标准 macOS 窗口，不再默认常驻桌面底层。
- 保留菜单栏状态项，点击后展示 Codex / Claude Code Runtime 浮窗。
- 新增 Runtime 展示设置，默认展示 Codex 与 Claude Code，并确保至少保留一个 Runtime。
- 用量趋势的近 7 日折线图和最近半年热力图新增应用内 hover 详情浮窗；近 7 日折线图现在支持整图横向 hover 切换日期。
- 设置页 checkbox 统一改为 switch 开关，语言/外观分段控件圆角与设计标准对齐，所有设置操作控件右对齐。
- 主窗口标题栏 Runtime 与操作按钮组右对齐，并增加顶部间距。
- 菜单栏浮窗新增设置入口，并提供打开主窗口、打开设置和退出应用。
- 支持在其他全屏 App 的当前 Space 中打开菜单栏浮窗。
- `Command + U` 现在用于显示或隐藏主窗口；窗口最小化时会恢复并唤到前台。
- 新增设置窗口，集中管理语言、外观、主窗口置顶和关闭主窗口后的运行行为。
- 主窗口恢复 Liquid Glass 材质和半透明质感，并优化标题栏工具区、窗口圆角、顶部间距和按钮尺寸。
- 语言切换、主题切换从主窗口顶部移入设置；PRO 状态不再常驻顶栏。
- 新增 Codex 与 Claude Code 彩色 Runtime 图标资源。
- 更新 README 截图、安装说明、构建说明和 CHANGELOG。

## 安装包

- Apple Silicon: `codexU-1.0.0-beta02-mac-arm64.dmg`
- Intel: `codexU-1.0.0-beta02-mac-x86_64.dmg`

## 校验

- `make build`
- `make release-all`
- `git diff --check`

SHA-256:

```text
a6368a48c8f1f5c21dd8de6e0155df0bed424a03ef9b21b9a4bc2986126a5c24  codexU-1.0.0-beta02-mac-arm64.dmg
af3312064e4a4cb371ad7503e716ec4902bff48b27582909e41ef8d8d5e3978a  codexU-1.0.0-beta02-mac-x86_64.dmg
```

# codexU

[English](README.en.md)

codexU 是一个本地 macOS 桌面用量小组件。它优先通过官方本地 `codex app-server` 读取账户、额度窗口和 usage 信息，再从 `~/.codex/state_5.sqlite` 聚合本机线程 token 用量，并用看板样式展示今天的 Codex 任务状态。

![codexU 桌面小组件截图](docs/screenshot.png)

## 功能

- 展示 Codex 5 小时和 7 天额度窗口的剩余比例、已用比例和重置时间。
- 汇总本机今日、近 7 天和累计 token 用量。
- 显示近 7 天使用趋势，方便快速对比每天的使用量。
- 从本机 Codex 线程和启用中的 Codex automations 生成今日任务看板。
- 按进行中、待处理、定时、完成四类组织任务。
- 默认贴在桌面层，不遮挡普通窗口；需要查看时可以一键唤到前台。
- 数据只在本机读取。codexU 不上传本地 usage、线程或账户数据到第三方服务。

## 快捷键和操作

- `Command + U`：在桌面层和前台层之间切换小组件。
- 菜单栏仪表图标：点击后执行和 `Command + U` 相同的切换操作。
- 右上角刷新按钮：立即刷新额度、token 统计、趋势图和任务看板。
- 右上角关闭按钮：退出 codexU。
- 拖动小组件背景：移动小组件位置。

## 首次安装：隐私与安全

codexU 目前通过 GitHub Release 的 DMG 安装包分发，不经过 Mac App Store。第一次打开时，macOS 可能会拦截，需要手动允许：

1. 打开 `codexU.app` 一次。如果系统提示无法打开，先取消弹窗。
2. 打开 **系统设置 > 隐私与安全性**。
3. 在 **安全性** 区域找到 `codexU.app`，点击 **仍要打开**。
4. 使用 Touch ID 或密码确认，然后点击 **打开**。

也可以在 Finder 中右键点击 `codexU.app`，选择 **打开**，再确认系统安全提示。

codexU 需要读取本机 `~/.codex/` 下的 Codex 数据。如果 macOS 弹出文件或文件夹访问授权，请允许访问，否则小组件无法读取本机 usage、线程和自动化任务信息。

## 安装

从 GitHub Release 下载最新的 `codexU-<version>-mac-arm64.dmg`：

1. 打开 DMG。
2. 将 `codexU.app` 拖到 `Applications` 文件夹。
3. 从 `Applications` 打开 codexU。
4. 按上面的 **首次安装：隐私与安全** 步骤完成手动放行。

## 运行要求

- macOS 14 或更新版本。
- 本机已安装 Codex。
- 已登录 Codex 账户，额度信息才会显示。
- Codex 至少使用过一次，以便生成 `~/.codex/state_5.sqlite`。
- 从源码构建时需要 Xcode Command Line Tools。

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

产物会写入 `dist/`，例如：

```text
dist/codexU-0.1.3-mac-arm64.dmg
dist/codexU-0.1.3-mac-arm64.dmg.sha256
```

Developer ID 签名和 Apple notarization 流程见 [DISTRIBUTION.md](DISTRIBUTION.md)。

## 数据来源

- 账户与额度：`codex app-server` 的 `account/read`、`account/rateLimits/read`、`account/usage/read`。
- 本机 token 用量：`~/.codex/state_5.sqlite`。
- 今日任务看板：本机 SQLite 中未归档和今日归档的 Codex 线程。
- 定时任务：`~/.codex/automations/**/automation.toml` 中启用的 automation 元数据。

当前 Codex 额度 API 暴露的是滚动窗口百分比和重置时间，不暴露绝对配额数量。更完整的数据口径和回退策略见 [RESEARCH.md](RESEARCH.md)。

## License

MIT. See [LICENSE](LICENSE).

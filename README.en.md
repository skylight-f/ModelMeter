# AgentDesk

[中文](README.md)

AgentDesk is a macOS desktop widget for monitoring token usage and costs across multiple AI coding tools. Supports Codex, MimoCode, and more with automatic data source discovery and real-time usage analysis.

![AgentDesk desktop widget screenshot](docs/screenshot-0.3.0.png)

## Who Is This For

- Developers using AI coding tools like OpenAI Codex, MimoCode, Claude Code
- Teams tracking AI tool usage costs and efficiency
- Anyone who wants AI usage status visible on their desktop

## Core Features

### Usage Overview
- **Quota Ring Chart**: Shows 5-hour and 7-day quota remaining percentage and reset time
- **Token Statistics**: Today, 7-day, and lifetime token usage, split by uncached, cached, and output
- **Value Progress**: Estimates monthly usage value based on API pricing

### Model Usage Analysis
- **Detailed Table**: Token usage, cache hit rate, cost, and output speed per model
- **Price Info**: Supports USD/CNY dual currency, auto-detects domestic/international models
- **Search & Filter**: Quick search by model name or provider
- **Click Details**: Click any model to view detailed statistics

### Usage Trend Chart
- **7-Day Trend**: Stacked bar chart showing daily usage by model
- **Color Coding**: Different colors for different models
- **Hover Interaction**: Mouse hover shows model name and token count

### Auto Data Source Discovery
- **Smart Detection**: Automatically scans local databases for available sources
- **Multi-Source Support**: Codex, MimoCode, Claude Code, Cursor, Windsurf
- **One-Click Switch**: Dropdown menu to quickly switch data sources
- **All Sources**: Combines Codex and MimoCode usage overview with a source split

### Desktop Integration
- **Always Visible**: Stays on desktop layer for quick viewing
- **Keyboard Shortcut**: `Command + U` to toggle front/desktop layer
- **Menu Bar Icon**: Click to quickly toggle display state

### Internationalization & Themes
- **Bilingual**: Chinese/English interface, manual switch
- **Appearance Mode**: Auto/Light/Dark, follows system or manual setting

## Feature Details

### Model Price Support

| Provider | Model Examples | Currency | Input Price | Cache Price | Output Price |
|----------|----------------|----------|-------------|-------------|--------------|
| OpenAI | gpt-5.4, gpt-5.4-mini | USD | $2.50 | $0.25 | $15.00 |
| MimoCode | mimo-auto, mimo-v2.5 | CNY | ¥2.00 | ¥0.50 | ¥8.00 |
| DeepSeek | deepseek-v4-pro | CNY | ¥4.00 | ¥1.00 | ¥16.00 |
| Qwen | qwen3.7-plus, qwen3.7-max | CNY | ¥0.80 | ¥0.20 | ¥4.00 |
| GLM | glm-5.2 | CNY | ¥2.00 | ¥0.50 | ¥8.00 |

### Output Speed Statistics

Average output speed calculated from database (tokens/second):

| Model | Average Speed |
|-------|---------------|
| qwen3.7-max | ~40 tokens/s |
| deepseek-v4-pro | ~35 tokens/s |
| qwen3.7-plus | ~28 tokens/s |
| mimo-v2.5 | ~25 tokens/s |
| gpt-5.4 | ~13 tokens/s |

## Keyboard Shortcuts & Operations

- `Command + U`: Toggle between desktop and front layer
- Menu bar icon: Same as `Command + U`
- Top appearance toggle: Switch between auto/light/dark modes
- Top `中 | EN`: Switch Chinese/English interface
- Top-right refresh button: Refresh all data immediately
- Top-right toggle button: Switch front/desktop layer
- Top-right close button: Quit AgentDesk
- Drag widget background: Move widget position
- Click model row: View detailed statistics for that model

## Installation

### Download from GitHub Release

- Apple Silicon: `AgentDesk-<version>-mac-arm64.dmg`
- Intel: `AgentDesk-<version>-mac-x86_64.dmg`

1. Open the DMG
2. Drag `AgentDesk.app` to the `Applications` folder
3. Open AgentDesk from `Applications`
4. Follow the **First Install: Privacy & Security** steps below

### First Install: Privacy & Security

AgentDesk is distributed via GitHub Release DMG packages, not through the Mac App Store. On first launch, macOS may block it and require manual approval:

1. Open `AgentDesk.app` once. If the system says it can't be opened, cancel the dialog
2. Open **System Settings > Privacy & Security**
3. In the **Security** section, find `AgentDesk.app` and click **Open Anyway**
4. Confirm with Touch ID or password, then click **Open**

You can also right-click `AgentDesk.app` in Finder, choose **Open**, and confirm the security prompt.

## Requirements

- macOS 14 or later
- At least one supported AI coding tool installed (Codex, MimoCode, etc.)
- Logged in to the relevant account for quota information to display
- Xcode Command Line Tools required for building from source

## Building from Source

```sh
make build
```

Run:

```sh
make run
```

Install to `/Applications`:

```sh
make install
```

Check local data source output:

```sh
make probe
```

## Packaging DMG

```sh
make release
```

`make release` outputs an installer for the current build machine's architecture. You can also explicitly package for a specific architecture:

```sh
make release-arm64
make release-intel
make release-all
```

Output goes to `dist/`, for example:

```text
dist/AgentDesk-0.3.0-mac-arm64.dmg
dist/AgentDesk-0.3.0-mac-arm64.dmg.sha256
dist/AgentDesk-0.3.0-mac-x86_64.dmg
dist/AgentDesk-0.3.0-mac-x86_64.dmg.sha256
```

Developer ID signing and Apple notarization workflow: see [DISTRIBUTION.md](DISTRIBUTION.md).

## Data Sources

### Codex
- Account & quota: `codex app-server` endpoints (`account/read`, `account/rateLimits/read`, `account/usage/read`)
- Local token totals: `~/.codex/state_5.sqlite`
- Detailed token breakdown: `~/.codex/sessions/**/rollout-*.jsonl`

### MimoCode
- Usage data: `~/.local/share/mimocode/mimocode.db`
- Models and providers: Extracted from `message` table's `data` JSON
- Throughput calculation: Based on `time.created` and `time.completed` fields

### Other Data Sources
- Claude Code: `~/.claude/state.db`
- Cursor: `~/.cursor/state.vscsqlite`
- Windsurf: `~/.codeium/windsurf/state.vscsqlite`

## Project Structure

```
Sources/CodexUsageWidget/
├── main.swift          # Entry point, AppDelegate, AppKit containers
├── Models.swift        # Data model definitions
├── Providers.swift     # Data source reading, UsageStore
├── Views.swift         # All SwiftUI view components
└── Utils.swift         # Utility functions, formatting, JSON handling
```

## FAQ

### Is AgentDesk an official OpenAI product?

No. AgentDesk is an unofficial local macOS utility for reading local data from multiple AI coding tools.

### Does AgentDesk upload my data?

No. AgentDesk reads data locally only. It does not upload any usage, thread, or account data to third-party services.

### Which AI coding tools are supported?

Currently supported:
- OpenAI Codex
- MimoCode
- Claude Code (coming soon)
- Cursor (coming soon)
- Windsurf (coming soon)

### Why do some models show $0.00 cost?

This is because the pricing information for that model hasn't been added yet. AgentDesk shows estimated costs, and models with actual pricing will display accurate amounts.

### Does it support Intel Macs?

Yes. Intel Macs should download `AgentDesk-<version>-mac-x86_64.dmg`. Build from source with `make release-intel`.

## License

MIT. See [LICENSE](LICENSE).

# AgentDesk Project Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use compose:subagent (recommended) or compose:execute to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve code maintainability, performance, and test coverage of the AgentDesk macOS desktop widget.

**Architecture:** Refactor a 10,500-line Swift monolith (5 files) into modular components, replace Process-based SQLite queries with native API calls, and add unit tests for core business logic.

**Tech Stack:** Swift, SwiftUI, SQLite3 C API, AppKit, Combine

## Global Constraints

- macOS 14+ deployment target
- Build via `make build` (swiftc, no Xcode project)
- All `.swift` files in `Sources/CodexUsageWidget/` are auto-compiled (wildcard in Makefile)
- No external dependencies (pure Apple frameworks)
- Must remain compatible with existing data on disk (Codex state_5.sqlite, mimocode.db)

---

## Phase 1: Foundation (extract shared utilities, fix quick wins)

### Task 1: Fix duplicate imports and extract FilePaths

**Files:**
- Modify: `Sources/CodexUsageWidget/Models.swift:1-6` (remove duplicate imports)
- Create: `Sources/CodexUsageWidget/FilePaths.swift`

**Interfaces:**
- Produces: `enum FilePaths` with static paths for all database locations

- [ ] **Step 1: Create FilePaths.swift**

```swift
// Sources/CodexUsageWidget/FilePaths.swift
import Foundation

enum FilePaths {
    static let home = NSHomeDirectory()

    // Codex
    static let codexStateDB = home + "/.codex/state_5.sqlite"
    static let codexStateDBAlt = home + "/.codex/sqlite/state_5.sqlite"
    static let codexSkillsDir = home + "/.codex/skills"
    static let codexAutomationsDir = home + "/.codex/automations"

    // MimoCode
    static let mimocodeDB = home + "/.local/share/mimocode/mimocode.db"

    // Claude Code
    static let claudeStateDB = home + "/.claude/state.db"
    static let claudeStateDBAlt = home + "/.claude/sqlite/state.db"

    // Cursor
    static let cursorStateDB = home + "/.cursor/state.vscsqlite"
    static let cursorWorkspaceDB = home + "/Library/Application Support/Cursor/User/workspaceStorage/state.vscsqlite"

    // Windsurf
    static let windsurfStateDB = home + "/.codeium/windsurf/state.vscsqlite"

    // sqlite3 binary
    static let sqlite3Binary: String? = {
        let candidates = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3",
                          "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // Agents skills
    static let agentsSkillsDir = home + "/.agents/skills"

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}
```

- [ ] **Step 2: Fix duplicate imports in Models.swift**

Remove lines 4-6 (duplicate `import Cocoa`, `import Carbon.HIToolbox`, `import SwiftUI`). Keep only:
```swift
import Foundation
import SwiftUI
```

- [ ] **Step 3: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexUsageWidget/FilePaths.swift Sources/CodexUsageWidget/Models.swift
git commit -m "refactor: extract FilePaths constants and fix duplicate imports"
```

---

### Task 2: Extract native SQLite query helper

**Files:**
- Create: `Sources/CodexUsageWidget/NativeSQLite.swift`
- Modify: `Sources/CodexUsageWidget/Providers.swift:517-542` (update runSQLite to use native API)

**Interfaces:**
- Produces: `func queryRows(dbPath: String, sql: String) -> [[String: String?]]`

- [ ] **Step 1: Create NativeSQLite.swift**

```swift
// Sources/CodexUsageWidget/NativeSQLite.swift
import Foundation
import SQLite3

enum NativeSQLite {
    static func queryRows(dbPath: String, sql: String) -> [[String: String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: String?]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let cStr = sqlite3_column_text(stmt, i) {
                    row[name] = String(cString: cStr)
                } else if sqlite3_column_type(stmt, i) == SQLITE_INTEGER {
                    row[name] = String(sqlite3_column_int64(stmt, i))
                } else if sqlite3_column_type(stmt, i) == SQLITE_FLOAT {
                    row[name] = String(sqlite3_column_double(stmt, i))
                } else {
                    row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    static func querySingleRow(dbPath: String, sql: String) -> [String: String?]? {
        queryRows(dbPath: dbPath, sql: sql).first
    }
}
```

- [ ] **Step 2: Replace runSQLite in Providers.swift**

In `Providers.swift`, replace the `runSQLite` static method body with:

```swift
private static func runSQLite(sqlitePath: String, dbPath: String, query: String) -> [[String: String]] {
    let rows = NativeSQLite.queryRows(dbPath: dbPath, sql: query)
    return rows.map { dict in
        dict.compactMapValues { value in
            value
        }
    }
}
```

Note: `sqlitePath` parameter becomes unused. Keep it for now to avoid changing all call sites; remove in a later cleanup.

- [ ] **Step 3: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexUsageWidget/NativeSQLite.swift Sources/CodexUsageWidget/Providers.swift
git commit -m "perf: replace Process-based sqlite3 with native SQLite3 API"
```

---

## Phase 2: Split Views.swift into modules

### Task 3: Extract theme and shared components

**Files:**
- Create: `Sources/CodexUsageWidget/WidgetTheme.swift`
- Create: `Sources/CodexUsageWidget/SharedComponents.swift`
- Modify: `Sources/CodexUsageWidget/Views.swift` (remove extracted code)

**Interfaces:**
- Produces: `WidgetLanguage`, `WidgetThemeMode`, `WidgetPalette`, `FlowLayout`, `SectionTitle`, `IconButtonStyleModifier`, `SectionBackgroundModifier`, `CardBackgroundModifier`

- [ ] **Step 1: Create WidgetTheme.swift**

Move from Views.swift:
- `extension Notification.Name` (lines 5-7)
- `postPreferencesDidChange()` (lines 9-11)
- `enum WidgetLanguage` (lines 22-58)
- `enum WidgetThemeMode` (lines 60-99)
- `enum WidgetPalette` (find in file, around line 4842)

- [ ] **Step 2: Create SharedComponents.swift**

Move from Views.swift:
- `struct FlowLayout: Layout` (line 5747)
- `struct SectionTitle: View` (line 2849)
- `struct SectionBackgroundModifier: ViewModifier` (line 3378)
- `struct CardBackgroundModifier: ViewModifier` (line 3403)
- `struct IconButtonStyleModifier: ViewModifier` (line 3435)
- `extension View` block (line 3421)
- `struct CompactFilterPicker` (line 2865)
- `struct CompactTextFieldRow` (line 2901)
- `struct LanguageSwitch` (line 3249)
- `struct ProviderSwitch` (line 3268)
- `struct ThemeSwitch` (line 3352)
- `struct DiscoveredProviderPicker` (line 3291)

- [ ] **Step 3: Remove the extracted code from Views.swift**

- [ ] **Step 4: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageWidget/WidgetTheme.swift Sources/CodexUsageWidget/SharedComponents.swift Sources/CodexUsageWidget/Views.swift
git commit -m "refactor: extract theme and shared components from Views.swift"
```

---

### Task 4: Extract chart and metric components

**Files:**
- Create: `Sources/CodexUsageWidget/WidgetCharts.swift`
- Create: `Sources/CodexUsageWidget/WidgetMetricCards.swift`

**Interfaces:**
- Produces: chart views, metric card views, ring components

- [ ] **Step 1: Create WidgetCharts.swift**

Move from Views.swift:
- `struct GaugeRing` (line 3458)
- `struct DualQuotaRing` (line 3486)
- `struct QuotaRingSegment` (line 3541)
- `struct QuotaRingLabel` (line 3631)
- `struct QuotaResetSummary` (line 3649)
- `struct QuotaResetLine` (line 3672)
- `struct DailyTokenChart` (line 3706)
- `struct ModelDailyTokenChart` (line 3725)
- `struct ModelStackedBar` (line 3796)
- `struct DailyTokenBar` (line 3876)
- `struct TokenSplitBar` (line 4024)
- `struct TokenSplitLegendRow` (line 4058)
- `struct UsageProgressBar` (line 5914)
- `struct RingRGBColor` (line 4823)

- [ ] **Step 2: Create WidgetMetricCards.swift**

Move from Views.swift:
- `struct DetailedTokenMetricCard` (line 3911)
- `struct CacheHitBadge` (line 3991)
- `struct TokenMetricCard` (line 4519)
- `struct MiniTrendCard` (line 4551)
- `struct QuotaValueProgressBar` (line 4461)
- `struct MetricTile` (line 4793)
- `struct DetailMetricCard` (line 4328)
- `struct LegendItem` (line 4348)
- `struct InfoChip` (line 4771)
- `struct AnalyticsStatCard` (line 5831)
- `struct RequestStatLabel` (line 5897)

- [ ] **Step 3: Remove extracted code from Views.swift**

- [ ] **Step 4: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageWidget/WidgetCharts.swift Sources/CodexUsageWidget/WidgetMetricCards.swift Sources/CodexUsageWidget/Views.swift
git commit -m "refactor: extract chart and metric card components from Views.swift"
```

---

### Task 5: Extract model usage and wool progress components

**Files:**
- Create: `Sources/CodexUsageWidget/WidgetModelUsage.swift`
- Create: `Sources/CodexUsageWidget/WidgetWoolProgress.swift`

**Interfaces:**
- Produces: model usage views and wool progress views

- [ ] **Step 1: Create WidgetModelUsage.swift**

Move from Views.swift:
- `struct ModelUsageRow` (line 4083)
- `struct ModelDetailView` (line 4213)
- `struct ModelConsumptionRow` (line 5787)

- [ ] **Step 2: Create WidgetWoolProgress.swift**

Move from Views.swift:
- `struct WoolProgressCard` (line 4389)
- `struct SubscriptionMilestone` (line 4362)

- [ ] **Step 3: Remove extracted code from Views.swift**

- [ ] **Step 4: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageWidget/WidgetModelUsage.swift Sources/CodexUsageWidget/WidgetWoolProgress.swift Sources/CodexUsageWidget/Views.swift
git commit -m "refactor: extract model usage and wool progress components"
```

---

### Task 6: Extract Prompt Studio views

**Files:**
- Create: `Sources/CodexUsageWidget/PromptStudioViews.swift`

**Interfaces:**
- Produces: all Prompt Studio related views

- [ ] **Step 1: Create PromptStudioViews.swift**

Move from Views.swift:
- `struct PromptStudioView` (line 818)
- `struct PromptSummaryStatRow` (line 2004)
- `struct PromptFilterButton` (line 2033)
- `struct StudioSidebarButton` (line 2066)
- `struct StudioPanelHeader` (line 2106)
- `struct OverviewChecklistRow` (line 2122)
- `struct OverviewStepRow` (line 2137)
- `struct AgentProfileListPanel` (line 2159)
- `struct AgentProfileEditorPanel` (line 2241)
- `struct AgentProfilePreviewPanel` (line 2443)
- `struct PublishSyncPanel` (line 2520)
- `struct PublishTargetCard` (line 2627)
- `struct PromptAssetRow` (line 2936)
- `struct PromptAssetDetailView` (line 2985)
- `struct PromptActionButton` (line 3202)
- `struct PromptMetadataPill` (line 3227)

- [ ] **Step 2: Remove extracted code from Views.swift**

- [ ] **Step 3: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexUsageWidget/PromptStudioViews.swift Sources/CodexUsageWidget/Views.swift
git commit -m "refactor: extract Prompt Studio views from Views.swift"
```

---

### Task 7: Extract Settings view

**Files:**
- Create: `Sources/CodexUsageWidget/SettingsViews.swift`

**Interfaces:**
- Produces: `SettingsView`, `EditablePriceRow`, `SettingsTab`

- [ ] **Step 1: Create SettingsViews.swift**

Move from Views.swift:
- `enum SettingsTab` (line 4918)
- `struct EditablePriceRow` (line 4945)
- `struct SettingsView` (line 4975)

- [ ] **Step 2: Remove extracted code from Views.swift**

- [ ] **Step 3: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexUsageWidget/SettingsViews.swift Sources/CodexUsageWidget/Views.swift
git commit -m "refactor: extract Settings views from Views.swift"
```

---

## Phase 3: Split Providers.swift

### Task 8: Extract UsageStore into its own file

**Files:**
- Create: `Sources/CodexUsageWidget/UsageStore.swift`

- [ ] **Step 1: Create UsageStore.swift**

Move `final class UsageStore` (Providers.swift:105-642) to its own file.

- [ ] **Step 2: Update imports if needed**

- [ ] **Step 3: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexUsageWidget/UsageStore.swift Sources/CodexUsageWidget/Providers.swift
git commit -m "refactor: extract UsageStore from Providers.swift"
```

---

### Task 9: Extract CodexUsageReader into its own file

**Files:**
- Create: `Sources/CodexUsageWidget/CodexUsageReader.swift`

- [ ] **Step 1: Create CodexUsageReader.swift**

Move `final class CodexUsageReader` (Providers.swift:644-2165) to its own file.

- [ ] **Step 2: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexUsageWidget/CodexUsageReader.swift Sources/CodexUsageWidget/Providers.swift
git commit -m "refactor: extract CodexUsageReader from Providers.swift"
```

---

## Phase 4: Tests

### Task 10: Add unit tests for modelProvider

**Files:**
- Create: `Tests/ModelProviderTests.swift`

**Interfaces:**
- Consumes: `modelProvider(from:)` from Models.swift

- [ ] **Step 1: Create test file**

```swift
// Tests/ModelProviderTests.swift
import Testing
@testable import CodexUsageWidget

@Suite("modelProvider")
struct ModelProviderTests {
    @Test("OpenAI models")
    func openAI() {
        #expect(modelProvider(from: "gpt-4o") == "OpenAI")
        #expect(modelProvider(from: "gpt-5.4") == "OpenAI")
        #expect(modelProvider(from: "o1-preview") == "OpenAI")
        #expect(modelProvider(from: "o3-mini") == "OpenAI")
    }

    @Test("Anthropic models")
    func anthropic() {
        #expect(modelProvider(from: "claude-sonnet-4-20250514") == "Anthropic")
        #expect(modelProvider(from: "claude-3-opus") == "Anthropic")
    }

    @Test("Google models")
    func google() {
        #expect(modelProvider(from: "gemini-2.5-pro") == "Google")
        #expect(modelProvider(from: "gemma-3") == "Google")
    }

    @Test("DeepSeek models")
    func deepSeek() {
        #expect(modelProvider(from: "deepseek-v4-pro") == "DeepSeek")
        #expect(modelProvider(from: "ds-chat") == "DeepSeek")
    }

    @Test("MimoCode models")
    func mimoCode() {
        #expect(modelProvider(from: "mimo-auto") == "MimoCode")
        #expect(modelProvider(from: "mimo-v2.5-pro") == "MimoCode")
    }

    @Test("Chinese providers")
    func chineseProviders() {
        #expect(modelProvider(from: "qwen3.7-plus") == "Alibaba")
        #expect(modelProvider(from: "glm-5.2") == "Zhipu AI")
        #expect(modelProvider(from: "kimi-latest") == "Moonshot")
    }

    @Test("Unknown model falls back to AI")
    func unknown() {
        #expect(modelProvider(from: "some-random-model") == "AI")
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test` (or `swiftc -parse-as-library Tests/ModelProviderTests.swift`)
Note: May need to adjust test runner based on project setup.

- [ ] **Step 3: Commit**

```bash
git add Tests/ModelProviderTests.swift
git commit -m "test: add unit tests for modelProvider function"
```

---

### Task 11: Add unit tests for TokenBreakdown

**Files:**
- Create: `Tests/TokenBreakdownTests.swift`

- [ ] **Step 1: Create test file**

```swift
// Tests/TokenBreakdownTests.swift
import Testing
@testable import CodexUsageWidget

@Suite("TokenBreakdown")
struct TokenBreakdownTests {
    @Test("billableCachedInputTokens caps at inputTokens")
    func cachedCap() {
        var t = TokenBreakdown.zero
        t.cachedInputTokens = 200
        t.inputTokens = 100
        #expect(t.billableCachedInputTokens == 100)
    }

    @Test("uncachedInputTokens subtracts cached from input")
    func uncached() {
        var t = TokenBreakdown.zero
        t.inputTokens = 500
        t.cachedInputTokens = 200
        #expect(t.uncachedInputTokens == 300)
    }

    @Test("add combines two breakdowns")
    func add() {
        var a = TokenBreakdown(inputTokens: 100, cachedInputTokens: 50, outputTokens: 30, reasoningOutputTokens: 10, totalTokens: 190)
        let b = TokenBreakdown(inputTokens: 200, cachedInputTokens: 80, outputTokens: 60, reasoningOutputTokens: 20, totalTokens: 360)
        a.add(b)
        #expect(a.inputTokens == 300)
        #expect(a.outputTokens == 90)
        #expect(a.totalTokens == 550)
    }

    @Test("delta computes difference")
    func delta() {
        let current = TokenBreakdown(inputTokens: 500, cachedInputTokens: 100, outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 850)
        let previous = TokenBreakdown(inputTokens: 300, cachedInputTokens: 80, outputTokens: 100, reasoningOutputTokens: 20, totalTokens: 500)
        let d = current.delta(from: previous)
        #expect(d.inputTokens == 200)
        #expect(d.outputTokens == 100)
        #expect(d.totalTokens == 350)
    }

    @Test("isZero returns true for zero breakdown")
    func isZero() {
        #expect(TokenBreakdown.zero.isZero == true)
        var t = TokenBreakdown.zero
        t.inputTokens = 1
        #expect(t.isZero == false)
    }
}
```

- [ ] **Step 2: Run tests**

- [ ] **Step 3: Commit**

```bash
git add Tests/TokenBreakdownTests.swift
git commit -m "test: add unit tests for TokenBreakdown calculations"
```

---

## Phase 5: Performance refinements

### Task 12: Optimize timer refresh strategy

**Files:**
- Modify: `Sources/CodexUsageWidget/UsageStore.swift` (start/stop methods)

- [ ] **Step 1: Remove obsolete secondary timer guidance**

The secondary board surface was removed from the product, so there is no dedicated refresh timer to tune.

- [ ] **Step 2: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexUsageWidget/UsageStore.swift
git commit -m "perf: simplify refresh timers"
```

---

### Task 13: Add sessionUsageCache eviction

**Files:**
- Modify: `Sources/CodexUsageWidget/CodexUsageReader.swift`

- [ ] **Step 1: Add cache size limit**

After the `sessionUsageCache` declaration, add a cache eviction method:

```swift
private static func evictSessionCacheIfNeeded() {
    let maxEntries = 200
    if sessionUsageCache.count > maxEntries {
        let keysToRemove = Array(sessionUsageCache.keys.prefix(sessionUsageCache.count - maxEntries))
        for key in keysToRemove {
            sessionUsageCache.removeValue(forKey: key)
        }
    }
}
```

Call it at the start of any method that writes to the cache.

- [ ] **Step 2: Build and verify**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexUsageWidget/CodexUsageReader.swift
git commit -m "perf: add sessionUsageCache eviction to prevent unbounded growth"
```

---

## Summary

| Phase | Tasks | Impact |
|-------|-------|--------|
| Phase 1: Foundation | 2 | Quick wins, shared utilities |
| Phase 2: Views split | 5 | Major maintainability improvement |
| Phase 3: Providers split | 2 | Better code organization |
| Phase 4: Tests | 2 | Regression safety net |
| Phase 5: Performance | 2 | Reduced CPU/memory usage |
| **Total** | **13** | |

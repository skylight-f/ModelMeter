import Foundation

enum StatusItemPresentationSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let suiteName = "codexU.status-item-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("status item self-test failed: could not create UserDefaults suite")
            return false
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let defaultPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(defaultPreferences == .default, "missing keys should load the current rich defaults")
        expect(QuotaDisplayMode.used.drawsClockwise, "used quota should draw clockwise")
        expect(!QuotaDisplayMode.remaining.drawsClockwise, "remaining quota should draw counterclockwise")
        expect(QuotaDisplayMode.used.startsAtLeadingEdge, "used linear bar should start at the leading edge")
        expect(!QuotaDisplayMode.remaining.startsAtLeadingEdge, "remaining linear bar should start at the trailing edge")

        defaults.set("unknown-mode", forKey: StatusItemPreferencesStore.displayModeKey)
        defaults.set("unknown-direction", forKey: StatusItemPreferencesStore.quotaModeKey)
        defaults.set([], forKey: StatusItemPreferencesStore.visibleMetricsKey)
        let repairedPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(repairedPreferences.displayMode == .rich, "unknown display mode should fall back to rich")
        expect(repairedPreferences.quotaMode == .used, "unknown quota mode should fall back to used")
        expect(
            repairedPreferences.visibleMetrics == [.fiveHourQuota, .sevenDayQuota],
            "empty visible metrics should be repaired to both quota windows"
        )

        var noMetrics = StatusItemPreferences.default
        noMetrics.visibleMetrics = []
        expect(noMetrics.validationError() == .requiresVisibleMetric, "empty metrics should be rejected")

        var minimalTokensOnly = StatusItemPreferences.default
        minimalTokensOnly.displayMode = .minimal
        minimalTokensOnly.visibleMetrics = [.todayTokens]
        expect(
            minimalTokensOnly.validationError() == .minimalRequiresQuotaMetric,
            "minimal mode should require a quota metric"
        )
        expect(
            minimalTokensOnly.normalized().hasVisibleQuota,
            "stored minimal token-only state should repair itself"
        )

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = StatusItemSourceSnapshot(
            runtime: .codex,
            fiveHourRemainingPercent: 89,
            fiveHourResetsAt: now.addingTimeInterval(90 * 60),
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(26 * 60 * 60),
            todayTokens: 1_234_567
        )
        let builder = StatusItemPresentationBuilder()

        var usedPreferences = StatusItemPreferences.default
        usedPreferences.visibleMetrics.insert(.todayTokens)
        let used = builder.build(
            source: source,
            preferences: usedPreferences,
            language: .en,
            now: now
        )
        let usedFiveHour = used.metrics.first { $0.metric == .fiveHourQuota }
        let usedSevenDay = used.metrics.first { $0.metric == .sevenDayQuota }
        expect(usedFiveHour?.value == "11%", "used mode should invert remaining percentage")
        expect(usedFiveHour?.fraction == 0.11, "used mode ring fraction should match its number")
        expect(usedFiveHour?.paletteRole == .primary, "5h should use the main blue ring palette")
        expect(usedSevenDay?.paletteRole == .secondary, "7d should use the main purple ring palette")
        expect(usedFiveHour?.resetText == "1h", "reset countdown should use injected time")
        expect(usedSevenDay?.resetText == "1d", "long reset countdown should prefer days")
        expect(used.todayMetric?.value == "1.2M", "today tokens should use compact formatting")
        expect(used.tooltip.contains("used"), "English tooltip should name the quota direction")

        var remainingPreferences = usedPreferences
        remainingPreferences.quotaMode = .remaining
        let remaining = builder.build(
            source: source,
            preferences: remainingPreferences,
            language: .zh,
            now: now
        )
        let remainingFiveHour = remaining.metrics.first { $0.metric == .fiveHourQuota }
        expect(remainingFiveHour?.value == "89%", "remaining mode should preserve remaining percentage")
        expect(remainingFiveHour?.fraction == 0.89, "remaining ring fraction should match its number")
        expect(remainingFiveHour?.paletteRole == .primary, "quota direction must not change palette identity")
        expect(remaining.tooltip.contains("剩余"), "Chinese tooltip should name the quota direction")

        let clampedSource = StatusItemSourceSnapshot(
            runtime: .claudeCode,
            fiveHourRemainingPercent: -10,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 110,
            sevenDayResetsAt: nil,
            todayTokens: nil
        )
        let clamped = builder.build(
            source: clampedSource,
            preferences: remainingPreferences,
            language: .en,
            now: now
        )
        expect(clamped.metrics.first { $0.metric == .fiveHourQuota }?.value == "0%", "negative quota should clamp to zero")
        expect(clamped.metrics.first { $0.metric == .sevenDayQuota }?.value == "100%", "quota above 100 should clamp")
        expect(clamped.todayMetric?.isAvailable == false, "missing token data should remain unavailable")

        var minimalPreferences = StatusItemPreferences.default
        minimalPreferences.displayMode = .minimal
        let minimal = builder.build(source: source, preferences: minimalPreferences, language: .en, now: now)
        expect(minimal.itemLength <= 36, "minimal double-ring item should stay within 36pt")

        var classicPreferences = StatusItemPreferences.default
        classicPreferences.displayMode = .classic
        let classic = builder.build(source: source, preferences: classicPreferences, language: .en, now: now)
        expect(classic.itemLength <= 88, "classic double-ring item should stay within 88pt")
        expect(classic.mode == .classic, "classic presentation should select the number-ring renderer")

        let rich = builder.build(source: source, preferences: .default, language: .en, now: now)
        expect(rich.itemLength <= 124, "default rich item should not exceed the previous width")

        let unavailable = builder.build(
            source: .unavailable(runtime: .codex),
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(unavailable.itemLength == classic.itemLength, "data availability must not change item width")
        expect(unavailable.quotaMetrics.allSatisfy { !$0.isAvailable }, "missing quotas should stay unavailable")

        if failures.isEmpty {
            print("status item self-test passed")
            return true
        }

        for failure in failures {
            print("status item self-test failed: \(failure)")
        }
        return false
    }
}

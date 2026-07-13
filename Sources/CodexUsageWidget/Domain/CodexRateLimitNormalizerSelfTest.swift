import Foundation

enum CodexRateLimitNormalizerSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let fiveHour = window(usedPercent: 12, durationMins: 300)
        let sevenDay = window(usedPercent: 34, durationMins: 10_080)

        let standard = CodexRateLimitNormalizer.normalize([fiveHour, sevenDay])
        expect(standard.fiveHour == fiveHour, "standard response should classify the 300-minute window as 5h")
        expect(standard.sevenDay == sevenDay, "standard response should classify the 10080-minute window as 7d")

        let weeklyOnly = CodexRateLimitNormalizer.normalize([sevenDay, nil])
        expect(weeklyOnly.fiveHour == nil, "weekly-only response must not populate the 5h quota")
        expect(weeklyOnly.sevenDay == sevenDay, "weekly-only response should keep the 7d quota")

        let fiveHourOnly = CodexRateLimitNormalizer.normalize([fiveHour, nil])
        expect(fiveHourOnly.fiveHour == fiveHour, "5h-only response should keep the 5h quota")
        expect(fiveHourOnly.sevenDay == nil, "5h-only response must not populate the 7d quota")

        let reversed = CodexRateLimitNormalizer.normalize([sevenDay, fiveHour])
        expect(reversed.fiveHour == fiveHour, "slot order must not change the 5h classification")
        expect(reversed.sevenDay == sevenDay, "slot order must not change the 7d classification")

        let other = window(usedPercent: 56, durationMins: 43_200)
        let futureWindow = CodexRateLimitNormalizer.normalize([other, sevenDay])
        expect(futureWindow.fiveHour == nil, "an unknown duration must not be labeled as 5h")
        expect(futureWindow.sevenDay == sevenDay, "known windows should survive alongside unknown durations")
        expect(futureWindow.unclassified == [other], "unknown durations should remain available for diagnostics")

        let missingDuration = window(usedPercent: 78, durationMins: nil)
        let incomplete = CodexRateLimitNormalizer.normalize([missingDuration, nil])
        expect(incomplete.fiveHour == nil && incomplete.sevenDay == nil, "missing duration must fail closed")
        expect(incomplete.unclassified == [missingDuration], "missing duration should remain available for diagnostics")

        let duplicateFiveHour = CodexRateLimitNormalizer.normalize([
            fiveHour,
            window(usedPercent: 90, durationMins: 300)
        ])
        expect(duplicateFiveHour.fiveHour == nil, "duplicate 5h windows must be treated as ambiguous")
        expect(duplicateFiveHour.fiveHourMatchCount == 2, "duplicate 5h windows should be reported")

        if failures.isEmpty {
            print("Codex rate-limit normalizer self-test passed")
            return true
        }

        for failure in failures {
            print("Codex rate-limit normalizer self-test failed: \(failure)")
        }
        return false
    }

    private static func window(usedPercent: Double, durationMins: Int?) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowDurationMins: durationMins,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

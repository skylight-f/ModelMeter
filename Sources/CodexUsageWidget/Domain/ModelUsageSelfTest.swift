import Foundation

enum ModelUsageSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let providers: [(String, String)] = [
            ("gpt-5.4", "OpenAI"),
            ("claude-sonnet-4", "Anthropic"),
            ("gemini-2.5-pro", "Google"),
            ("deepseek-v3", "DeepSeek"),
            ("mimo-v2-pro", "MimoCode"),
            ("glm-4.5", "Zhipu AI"),
            ("qwen3-coder", "Alibaba"),
            ("llama-4", "Meta"),
            ("mistral-large", "Mistral"),
            ("grok-4", "xAI"),
            ("unknown-local-model", "AI")
        ]
        for (model, expected) in providers {
            expect(modelProviderName(for: model) == expected, "\(model) should resolve to \(expected)")
        }

        let openAIItem = sampleItem(model: "shared", provider: "OpenAI")
        let anthropicItem = sampleItem(model: "shared", provider: "Anthropic")
        expect(openAIItem.id != anthropicItem.id, "model identity must include provider")

        let trend = ModelUsageTrendDay(
            id: "2026-07-15",
            date: Date(timeIntervalSince1970: 1_768_435_200),
            segments: [
                ModelUsageTrendSegment(model: "a", provider: "OpenAI", tokens: 1_000),
                ModelUsageTrendSegment(model: "b", provider: "Anthropic", tokens: 2_000)
            ]
        )
        expect(trend.tokens == 3_000, "trend day should sum all model segments")

        if failures.isEmpty {
            print("model usage self-test passed")
            return true
        }
        for failure in failures {
            print("model usage self-test failed: \(failure)")
        }
        return false
    }

    private static func sampleItem(model: String, provider: String) -> ModelUsageItem {
        ModelUsageItem(
            model: model,
            provider: provider,
            tokens: 1,
            uncachedInputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            estimatedCostUSD: nil,
            endToEndTokensPerSecond: nil
        )
    }
}

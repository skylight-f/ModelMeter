import XCTest
@testable import CodexUsageWidget

final class ModelProviderTests: XCTestCase {
    func testOpenAIModels() {
        XCTAssertEqual(modelProvider(from: "gpt-4o"), "OpenAI")
        XCTAssertEqual(modelProvider(from: "gpt-5.4"), "OpenAI")
        XCTAssertEqual(modelProvider(from: "o1-preview"), "OpenAI")
        XCTAssertEqual(modelProvider(from: "o3-mini"), "OpenAI")
    }

    func testAnthropicModels() {
        XCTAssertEqual(modelProvider(from: "claude-sonnet-4-20250514"), "Anthropic")
        XCTAssertEqual(modelProvider(from: "claude-3-opus"), "Anthropic")
    }

    func testGoogleModels() {
        XCTAssertEqual(modelProvider(from: "gemini-2.5-pro"), "Google")
        XCTAssertEqual(modelProvider(from: "gemma-3"), "Google")
    }

    func testDeepSeekModels() {
        XCTAssertEqual(modelProvider(from: "deepseek-v4-pro"), "DeepSeek")
        XCTAssertEqual(modelProvider(from: "ds-chat"), "DeepSeek")
    }

    func testMimoCodeModels() {
        XCTAssertEqual(modelProvider(from: "mimo-auto"), "MimoCode")
        XCTAssertEqual(modelProvider(from: "mimo-v2.5-pro"), "MimoCode")
    }

    func testChineseProviders() {
        XCTAssertEqual(modelProvider(from: "qwen3.7-plus"), "Alibaba")
        XCTAssertEqual(modelProvider(from: "glm-5.2"), "Zhipu AI")
        XCTAssertEqual(modelProvider(from: "kimi-latest"), "Moonshot")
    }

    func testUnknownModelFallsBackToAI() {
        XCTAssertEqual(modelProvider(from: "some-random-model"), "AI")
    }
}

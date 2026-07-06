import XCTest
@testable import CodexUsageWidget

final class TokenBreakdownTests: XCTestCase {
    func testBillableCachedInputTokensCapsAtInputTokens() {
        var t = TokenBreakdown.zero
        t.cachedInputTokens = 200
        t.inputTokens = 100
        XCTAssertEqual(t.billableCachedInputTokens, 100)
    }

    func testUncachedInputTokensSubtractsCachedFromInput() {
        var t = TokenBreakdown.zero
        t.inputTokens = 500
        t.cachedInputTokens = 200
        XCTAssertEqual(t.uncachedInputTokens, 300)
    }

    func testAddCombinesTwoBreakdowns() {
        var a = TokenBreakdown(inputTokens: 100, cachedInputTokens: 50, outputTokens: 30, reasoningOutputTokens: 10, totalTokens: 190)
        let b = TokenBreakdown(inputTokens: 200, cachedInputTokens: 80, outputTokens: 60, reasoningOutputTokens: 20, totalTokens: 360)
        a.add(b)
        XCTAssertEqual(a.inputTokens, 300)
        XCTAssertEqual(a.outputTokens, 90)
        XCTAssertEqual(a.totalTokens, 550)
    }

    func testDeltaComputesDifference() {
        let current = TokenBreakdown(inputTokens: 500, cachedInputTokens: 100, outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 850)
        let previous = TokenBreakdown(inputTokens: 300, cachedInputTokens: 80, outputTokens: 100, reasoningOutputTokens: 20, totalTokens: 500)
        let d = current.delta(from: previous)
        XCTAssertEqual(d.inputTokens, 200)
        XCTAssertEqual(d.outputTokens, 100)
        XCTAssertEqual(d.totalTokens, 350)
    }

    func testIsZeroReturnsTrueForZeroBreakdown() {
        XCTAssertTrue(TokenBreakdown.zero.isZero)
        var t = TokenBreakdown.zero
        t.inputTokens = 1
        XCTAssertFalse(t.isZero)
    }
}

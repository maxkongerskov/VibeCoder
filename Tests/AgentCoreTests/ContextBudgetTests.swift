import XCTest
@testable import AgentCore

final class ContextBudgetTests: XCTestCase {

    // P0: GLM-5.2-mxfp4 path — 256K advertised → 179_200 budget at 70%.
    func testEffectiveContextLengthPrefersAdvertisedOverStoredFallback() {
        XCTAssertEqual(
            ContextBudget.effectiveContextLength(stored: 32_768, advertised: 256_000),
            256_000)
    }

    func testBudgetTokensUsesSeventyPercent() {
        let budget = ContextBudget.budgetTokens(effectiveContextLength: 256_000)
        XCTAssertEqual(budget, 179_200)
    }

    func testBudgetTokensHonorsCustomThreshold() {
        let budget = ContextBudget.budgetTokens(
            effectiveContextLength: 100_000,
            compactThresholdPercent: 50)
        XCTAssertEqual(budget, 50_000)
    }

    func testMaxContextWindowCapsModelWindow() {
        let budget = ContextBudget.resolve(
            storedContextLength: 32_768,
            advertised: 256_000,
            maxContextWindowTokens: 64_000,
            compactThresholdPercent: 70)
        // window capped to 64k, budget 70% = 44800
        XCTAssertEqual(budget, 44_800)
    }

    func testResolveCombinesStoredAndAdvertised() {
        let budget = ContextBudget.resolve(storedContextLength: 32_768, advertised: 256_000)
        XCTAssertEqual(budget, 179_200)
    }

    func testResolveViaModelDescriptor() {
        let model = ModelDescriptor(
            id: "GLM-5.2-mxfp4",
            displayName: "GLM",
            backend: .omlx,
            contextLength: 256_000)
        XCTAssertEqual(ContextBudget.resolve(storedContextLength: 32_768, model: model), 179_200)
    }

    func testContextUsageBreakdownSumsCategories() {
        let msgs: [ChatMessage] = [
            .init(role: .user, content: "Hello world this is a test prompt"),
            .init(role: .assistant, content: "Sure, I can help with that request."),
            .init(role: .tool, content: String(repeating: "x", count: 400), toolCallID: "t1"),
        ]
        let b = ContextUsageBreakdown.build(
            systemPrompt: "You are a coding agent.",
            messages: msgs,
            windowTokens: 32_768,
            budgetTokens: 22_937,
            compactThresholdPercent: 70)
        XCTAssertGreaterThan(b.totalTokens, 0)
        XCTAssertEqual(b.totalTokens, b.categories.reduce(0) { $0 + $1.tokens })
        XCTAssertTrue(b.categories.contains(where: { $0.id == "user" }))
        XCTAssertTrue(b.categories.contains(where: { $0.id == "tools" }))
    }

    // MARK: - calibrated(to:) — anchor to a real server-reported total

    func testCalibratedRescalesCategoriesToSumToTotal() {
        let msgs: [ChatMessage] = [
            .init(role: .user, content: String(repeating: "a", count: 400)),
            .init(role: .assistant, content: String(repeating: "b", count: 800)),
            .init(role: .tool, content: String(repeating: "c", count: 1200), toolCallID: "t1"),
        ]
        let b = ContextUsageBreakdown.build(
            systemPrompt: String(repeating: "s", count: 200),
            messages: msgs,
            windowTokens: 32_768,
            budgetTokens: 22_937,
            compactThresholdPercent: 70)
        XCTAssertFalse(b.isCalibrated)

        // Anchor to a total different from the estimate (e.g. the server's
        // real prompt_tokens). Categories must rescale to sum to it.
        let calibrated = b.calibrated(to: 12_345)
        XCTAssertTrue(calibrated.isCalibrated)
        XCTAssertEqual(calibrated.totalTokens, 12_345)
        XCTAssertEqual(calibrated.categories.reduce(0) { $0 + $1.tokens }, 12_345)
        // Window/budget/threshold are preserved through calibration.
        XCTAssertEqual(calibrated.windowTokens, b.windowTokens)
        XCTAssertEqual(calibrated.budgetTokens, b.budgetTokens)
        XCTAssertEqual(calibrated.compactThresholdPercent, b.compactThresholdPercent)
        // Category set/labels are preserved (only the token counts rescale).
        XCTAssertEqual(calibrated.categories.map(\.id), b.categories.map(\.id))
    }

    func testCalibratedScalesProportionally() {
        let b = ContextUsageBreakdown.build(
            systemPrompt: "",
            messages: [
                .init(role: .user, content: String(repeating: "u", count: 400)),
                .init(role: .assistant, content: String(repeating: "a", count: 1200)),
            ],
            windowTokens: 32_768,
            budgetTokens: 22_937,
            compactThresholdPercent: 70)
        // Double the total: each category should roughly double.
        let doubled = b.calibrated(to: b.totalTokens * 2)
        for (orig, scaled) in zip(b.categories, doubled.categories) {
            XCTAssertEqual(scaled.tokens, orig.tokens * 2,
                           "category \(orig.id) should scale proportionally")
        }
    }

    func testCalibratedIsNoOpForNonPositiveTotals() {
        let b = ContextUsageBreakdown.build(
            systemPrompt: "",
            messages: [.init(role: .user, content: "hi")],
            windowTokens: 32_768,
            budgetTokens: 22_937,
            compactThresholdPercent: 70)
        // Zero/negative targets must not rescale (avoids divide-by-zero /
        // negative token counts).
        XCTAssertEqual(b.calibrated(to: 0), b)
        XCTAssertEqual(b.calibrated(to: -5), b)
        // An empty breakdown (total 0) is also a no-op.
        let empty = ContextUsageBreakdown(
            categories: [], totalTokens: 0, budgetTokens: 100,
            windowTokens: 100, compactThresholdPercent: 70)
        XCTAssertEqual(empty.calibrated(to: 500), empty)
    }
}
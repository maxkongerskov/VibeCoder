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
}
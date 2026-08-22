//
//  UnslothContextHonestyCopyTests.swift
//
//  Mira honesty: Unsloth native/max 1M + loaded 32k must not display as 32k.
//  Locks formatter/copy. Live SwiftUI meter binding is still product-owned.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class UnslothContextHonestyCopyTests: XCTestCase {

    func testCopyShowsLoadedAndNativeNotLone32k() {
        let label = ContextWindowHonestyCopy.label(
            nativeMax: 1_048_576, loaded: 32_768)
        XCTAssertTrue(label.contains("32.8k") || label.contains("32k"), label)
        XCTAssertTrue(label.contains("1.0M") || label.contains("1M"), label)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("loaded"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("native"))
        XCTAssertNotEqual(label, "32k")
        XCTAssertNotEqual(label, "32.8k")
        XCTAssertNotEqual(label, ContextUsageBreakdown.formatTokenCount(32_768))
        XCTAssertFalse(label == ContextUsageBreakdown.formatTokenCount(1_048_576),
                       "must not hide the 32k load either: \(label)")
    }

    func testMeterHelpIsNotLone32k() {
        let help = ContextWindowHonestyCopy.meterHelp(
            nativeMax: 1_048_576, loaded: 32_768, used: 1200)
        XCTAssertTrue(help.contains("1.0M") || help.contains("1M"), help)
        XCTAssertTrue(help.contains("32.8k") || help.contains("32k"), help)
        XCTAssertNotEqual(help.trimmingCharacters(in: .whitespaces), "32k")
        XCTAssertFalse(help == "32.8k")
    }

    func testSettingsExampleDoesNotCallUnslothA32kModel() {
        let line = ContextWindowHonestyCopy.settingsExampleBudgetLine(
            percent: 70, maxContextWindowTokens: 0)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("not unsloth native"), line)
        XCTAssertTrue(line.contains("1.0M") || line.contains("1M"), line)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("loaded"))
        // Must not be a single "32k" claim for Unsloth.
        XCTAssertNotEqual(line, "a 32.8k window")
        XCTAssertFalse(
            line.lowercased().contains("unsloth") && !line.lowercased().contains("1.0m") && !line.lowercased().contains("1m"))
    }

    func testContextMeterUsedOverWindowStillFormats1M() {
        let b = ContextUsageBreakdown.build(
            systemPrompt: "",
            messages: [],
            windowTokens: 1_048_576,
            budgetTokens: 734_003,
            compactThresholdPercent: 70)
        XCTAssertTrue(
            b.meterUsedOverWindowLabel.contains("1.0M") || b.meterUsedOverWindowLabel.contains("1M"),
            b.meterUsedOverWindowLabel)
        XCTAssertFalse(
            b.meterUsedOverWindowLabel.hasSuffix("32.8k") && !b.meterUsedOverWindowLabel.contains("1.0M"))
    }
}

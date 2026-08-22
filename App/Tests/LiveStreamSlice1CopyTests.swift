//
//  LiveStreamSlice1CopyTests.swift
//
//  Slice 1 (Sable, local, not pushed) — characterization of live-stream
//  copy/structure. Looks like ZCode (Working for / Thought for / growing
//  markdown / thinking rail). Product is VibeCoder: native SwiftUI. Not
//  Electron. Not ZCode. Does not prove timed GitHub merge vs Unsloth.
//

import XCTest
@testable import VibeCoderApp

final class LiveStreamSlice1CopyTests: XCTestCase {

    func testWorkingForAndThoughtForCopyExistsAsClaimed() {
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 8, isLive: true),
            "Working for 8s")
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 8, isLive: false),
            "Worked for 8s")
        XCTAssertEqual(
            "Thought for \(WorkDurationFormat.shortElapsed(seconds: 8, streaming: false))",
            "Thought for 8s")
        XCTAssertEqual(
            WorkDurationFormat.workingLabel(seconds: 60, isLive: true),
            "Working for 1 minute")
    }

    func testPendingBubbleLocksWorkingThenRailThenGrowingMarkdown() throws {
        let pending = try appSource("Views/Chat/PendingAssistantBubble.swift")
        XCTAssertTrue(pending.contains("WorkingHeader(seconds: elapsedSeconds, isLive: true)"))
        // Order: working header, thinking rail, growing markdown, then tools.
        let header = pending.range(of: "WorkingHeader(seconds:")
        let rail = pending.range(of: "ReasoningBlockView(")
        let md = pending.range(of: "MarkdownTextView(text: effectiveAnswer")
        XCTAssertNotNil(header, "live bubble must mount WorkingHeader")
        XCTAssertNotNil(rail, "live bubble must mount thinking rail")
        XCTAssertNotNil(md, "live bubble must mount growing markdown")
        if let header, let rail, let md {
            XCTAssertTrue(header.lowerBound < rail.lowerBound)
            XCTAssertTrue(rail.lowerBound < md.lowerBound)
        }
        XCTAssertTrue(pending.contains("isStreaming: true"))
        XCTAssertFalse(
            pending.lowercased().contains("electron"),
            "PendingAssistantBubble must not claim Electron")
    }

    func testGrowingMarkdownUsesStableStreamTailId() throws {
        let md = try appSource("Views/Chat/MarkdownTextView.swift")
        XCTAssertTrue(
            md.contains("\"stream-tail\""),
            "streaming last block must keep a stable id")
        XCTAssertTrue(md.contains("isStreaming"))
        XCTAssertTrue(md.contains("Prefix blocks keep a stable id")
            || md.contains("stream-tail"))
    }

    func testThoughtForHeaderAndThinkingRailAreInReasoningBlock() throws {
        let src = try appSource("Views/Chat/ReasoningBlockView.swift")
        XCTAssertTrue(src.contains("return \"Thought for \\(durationLabel)\""))
        XCTAssertTrue(src.contains("Thinking · \\(durationLabel)")
            || src.contains("\"Thinking · \\(durationLabel)\""))
        XCTAssertTrue(src.contains("BuildCodeDivider.thoughtRail()"))
        XCTAssertTrue(src.contains("WorkDurationFormat.shortElapsed"))
    }

    func testHistoryBubbleUsesWorkedForNotLiveWorking() throws {
        let hist = try appSource("Views/Chat/MessageBubbleViewV2.swift")
        XCTAssertTrue(hist.contains("WorkingHeader(seconds: secs, isLive: false)"))
        XCTAssertFalse(hist.contains("WorkingHeader(seconds: secs, isLive: true)"))
        XCTAssertTrue(hist.contains("ReasoningBlockView("))
    }

    func testReducedMotionStillDisablesShimmer() throws {
        let shimmer = try appSource("Theme/ShimmerText.swift")
        XCTAssertTrue(
            shimmer.contains("accessibilityDisplayShouldReduceMotion"),
            "ShimmerText must honor Reduced Motion")
        // Static Text when reduced; TimelineView (sweep) otherwise.
        XCTAssertTrue(shimmer.contains("TimelineView"))
        let reduceIdx = shimmer.range(of: "accessibilityDisplayShouldReduceMotion")
        let timelineIdx = shimmer.range(of: "TimelineView")
        XCTAssertNotNil(reduceIdx)
        XCTAssertNotNil(timelineIdx)
        if let reduceIdx, let timelineIdx {
            XCTAssertTrue(reduceIdx.lowerBound < timelineIdx.lowerBound)
        }

        let pending = try appSource("Views/Chat/PendingAssistantBubble.swift")
        XCTAssertTrue(
            pending.contains("accessibilityDisplayShouldReduceMotion"),
            "phrase cycle must skip under Reduced Motion")

        let working = try appSource("Views/Chat/WorkingHeader.swift")
        XCTAssertTrue(working.contains("ShimmerText(label"))
        XCTAssertTrue(working.contains("if isLive"))
    }

    func testAppCopyDoesNotClaimElectronOrThatVibeCoderIsZCode() throws {
        let files = [
            "Views/Chat/PendingAssistantBubble.swift",
            "Views/Chat/WorkingHeader.swift",
            "Views/Chat/ReasoningBlockView.swift",
            "Views/Chat/MessageBubbleViewV2.swift",
            "Utilities/WorkDurationFormat.swift",
            "Theme/ShimmerText.swift",
        ]
        for rel in files {
            let text = try appSource(rel)
            assertNotProductIdentityLies(in: text, file: rel)
        }
        // Formatter copy is elapsed phrases, not a product rename.
        let live = WorkDurationFormat.workingLabel(seconds: 3, isLive: true)
        XCTAssertFalse(live.localizedCaseInsensitiveContains("electron"))
        XCTAssertFalse(live.localizedCaseInsensitiveContains("zcode"))
        XCTAssertTrue(live.hasPrefix("Working for"))
    }

    func testStreamSliceIsNotA99PercentOrUnslothSpeedClaim() {
        // Residual honesty: these tests characterize local unpushed UI copy.
        // They do not raise RELEASE_BAR to 99% and do not invent speed vs Unsloth.
        let live = WorkDurationFormat.workingLabel(seconds: 6, isLive: true)
        XCTAssertEqual(live, "Working for 6s")
        XCTAssertFalse(live.localizedCaseInsensitiveContains("unsloth"))
        XCTAssertFalse(live.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(live.localizedCaseInsensitiveContains("as fast"))
    }

    func testCodeBlockChromeCopyAndWrapToggle() throws {
        XCTAssertEqual(CodeBlockCopy.copy, "Copy")
        XCTAssertEqual(CodeBlockCopy.copied, "Copied")
        XCTAssertEqual(CodeBlockCopy.wrapLines, "Wrap lines")
        XCTAssertFalse(CodeBlockCopy.wrapLines.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(CodeBlockCopy.copy.localizedCaseInsensitiveContains("zcode"))

        let src = try appSource("Views/Chat/CodeBlockView.swift")
        XCTAssertTrue(src.contains("CodeBlockCopy.wrapLines"))
        XCTAssertTrue(src.contains("CodeBlockCopy.copy"))
        XCTAssertTrue(src.contains("CodeBlockCopy.copied"))
        XCTAssertTrue(src.contains("@State private var wrapLines = false"))
        XCTAssertTrue(src.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertTrue(src.contains("if wrapLines"))
        XCTAssertTrue(src.contains("Theme.Motion.quick"))
        XCTAssertFalse(src.lowercased().contains("vibecoder is zcode"))
        XCTAssertFalse(
            src.contains("ChatViewModel"),
            "code-block chrome must not grow ChatViewModel")
    }

    // MARK: - helpers

    private func assertNotProductIdentityLies(in text: String, file: String) {
        let lower = text.lowercased()
        XCTAssertFalse(
            lower.contains("vibecoder is zcode"),
            "\(file) must not claim VibeCoder IS ZCode")
        XCTAssertFalse(
            lower.contains("we are zcode"),
            "\(file) must not claim the product is ZCode")
        XCTAssertFalse(
            lower.contains("this app is electron")
                || lower.contains("vibecoder is electron"),
            "\(file) must not claim Electron")
        // User-facing string literals must not market Electron.
        if let electronRange = lower.range(of: "electron") {
            let start = text.index(
                electronRange.lowerBound,
                offsetBy: -40,
                limitedBy: text.startIndex) ?? text.startIndex
            let window = String(text[start..<electronRange.upperBound]).lowercased()
            XCTFail("\(file) mentions Electron (\(window)…) — product is native SwiftUI")
        }
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }
}

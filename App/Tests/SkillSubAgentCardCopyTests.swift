//
//  SkillSubAgentCardCopyTests.swift
//
//  Characterization of Skill and SubAgent card copy (Sable, local).
//  Skill: Running skill / Ran skill + args. SubAgent: Launching / Launched
//  + prompt. Product is VibeCoder. Looks like ZCode cards. Not ZCode.
//  Not Electron. Does not stamp 99%. Does not restyle the painted copy.
//

import XCTest
@testable import AgentCore
@testable import VibeCoderApp

final class SkillSubAgentCardCopyTests: XCTestCase {

    func testSkillCardCopyIsRunningSkillThenRanSkillWithArgs() {
        let running = SkillCard(index: 0, isRunning: true, skillName: "review", args: "strict")
        XCTAssertEqual(SkillCardCopy.verb(running), "Running skill")
        XCTAssertEqual(SkillCardCopy.status(running), "review · strict")
        XCTAssertEqual(running.kindLabel, "Running skill")
        XCTAssertEqual(ToolCallGrouping.skillKindLabel(isRunning: true), "Running skill")

        let done = SkillCard(index: 0, isRunning: false, skillName: "review", args: "strict")
        XCTAssertEqual(SkillCardCopy.verb(done), "Ran skill")
        XCTAssertEqual(SkillCardCopy.status(done), "review · strict")
        XCTAssertEqual(ToolCallGrouping.skillKindLabel(isRunning: false), "Ran skill")

        XCTAssertEqual(
            SkillCardCopy.status(SkillCard(index: 1, isRunning: false, skillName: "ship")),
            "ship")
        XCTAssertEqual(
            SkillCardCopy.status(SkillCard(index: 2, isRunning: false, skillName: "", args: "only-args")),
            "only-args")
        XCTAssertEqual(
            SkillCardCopy.status(SkillCard(index: 3, isRunning: false, skillName: "")),
            "Skill")

        let line = "\(SkillCardCopy.verb(running)) · \(SkillCardCopy.status(running))"
        XCTAssertEqual(line, "Running skill · review · strict")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("electron"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("99%"))
    }

    func testLoadSkillGroupsToSkillCardNotExplore() {
        let running = ToolCallEvent(
            name: "load_skill",
            isRunning: true,
            skillName: "review-pr",
            skillArgs: "focus tests")
        let groups = ToolCallGrouping.group([running])
        XCTAssertEqual(groups.count, 1)
        guard case .skill(let card) = groups[0] else {
            return XCTFail("load_skill is a skill card")
        }
        XCTAssertEqual(card.kindLabel, "Running skill")
        XCTAssertEqual(card.skillName, "review-pr")
        XCTAssertEqual(card.args, "focus tests")
        XCTAssertTrue(card.isRunning)
    }

    func testSubAgentCardCopyIsLaunchingThenLaunchedWithPrompt() {
        XCTAssertEqual(SubAgentCardCopy.title, "SubAgent")
        let running = AgentCard(
            index: 1,
            isRunning: true,
            prompt: "scan tests",
            agentType: "explore")
        XCTAssertEqual(SubAgentCardCopy.verb(running), "Launching")
        XCTAssertEqual(SubAgentCardCopy.status(running), "scan tests")
        XCTAssertEqual(running.kindLabel, "Launching")
        XCTAssertEqual(ToolCallGrouping.agentKindLabel(isRunning: true), "Launching")

        let done = AgentCard(index: 1, isRunning: false, prompt: "scan tests")
        XCTAssertEqual(SubAgentCardCopy.verb(done), "Launched")
        XCTAssertEqual(ToolCallGrouping.agentKindLabel(isRunning: false), "Launched")

        XCTAssertEqual(
            SubAgentCardCopy.status(AgentCard(index: 2, isRunning: false, agentType: "plan")),
            "plan")
        XCTAssertEqual(
            SubAgentCardCopy.status(AgentCard(index: 3, isRunning: false)),
            "SubAgent")

        let line = "\(SubAgentCardCopy.title) · \(SubAgentCardCopy.verb(running)) · \(SubAgentCardCopy.status(running))"
        XCTAssertEqual(line, "SubAgent · Launching · scan tests")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("electron"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("99%"))
    }

    func testTaskAndFollowUpToolsAreAgentCardsNotOther() {
        let running = ToolCallEvent(
            name: "task",
            isRunning: true,
            agentPrompt: "Find the grouping tests",
            agentType: "explore")
        guard case .agent(let card) = ToolCallGrouping.group([running])[0] else {
            return XCTFail("task is an agent card")
        }
        XCTAssertEqual(card.title, "SubAgent")
        XCTAssertEqual(card.kindLabel, "Launching")
        XCTAssertEqual(card.prompt, "Find the grouping tests")
        XCTAssertEqual(card.agentType, "explore")
        XCTAssertEqual(card.toolName, "task")

        let followUps = [
            ToolCallEvent(name: "get_task_output"),
            ToolCallEvent(name: "kill_task", agentType: "explore"),
            ToolCallEvent(name: "wait_tasks"),
        ]
        let groups = ToolCallGrouping.group(followUps)
        XCTAssertEqual(groups.count, 3)
        for g in groups {
            guard case .agent(let c) = g else {
                return XCTFail("task output/stop tools are agent cards, got \(g)")
            }
            XCTAssertEqual(c.title, "SubAgent")
            XCTAssertEqual(c.kindLabel, "Launched")
        }
    }

    func testSkillAndAgentDoNotCollapseIntoExploreOrEachOther() {
        let events = [
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "load_skill", skillName: "ship"),
            ToolCallEvent(name: "task", agentPrompt: "plan next"),
            ToolCallEvent(name: "read_file"),
            ToolCallEvent(name: "load_skill", skillName: "review"),
        ]
        let groups = ToolCallGrouping.group(events)
        XCTAssertEqual(groups.count, 5)
        guard case .explore = groups[0] else { return XCTFail("search is explore") }
        guard case .skill(let a) = groups[1] else { return XCTFail("skill card") }
        XCTAssertEqual(a.skillName, "ship")
        guard case .agent(let agent) = groups[2] else { return XCTFail("agent card") }
        XCTAssertEqual(agent.prompt, "plan next")
        guard case .explore(let counts, _) = groups[3] else {
            return XCTFail("read after agent is a new explore")
        }
        XCTAssertEqual(counts.files, 1)
        guard case .skill(let b) = groups[4] else { return XCTFail("second skill stays its own card") }
        XCTAssertEqual(b.skillName, "review")
    }

    func testSendMessageIsNotAnAgentCard() {
        XCTAssertEqual(ToolCallGrouping.family(forToolName: "send_message"), .other)
        let groups = ToolCallGrouping.group([ToolCallEvent(name: "send_message")])
        XCTAssertEqual(groups.count, 1)
        guard case .standalone(_, let family) = groups[0] else {
            return XCTFail("send_message is standalone other, not SubAgent")
        }
        XCTAssertEqual(family, .other)
    }

    func testChatStackPaintsSkillAndSubAgentRowsAsClaimed() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        XCTAssertTrue(src.contains("case .skill(let card):"))
        XCTAssertTrue(src.contains("skillRow(card)"))
        XCTAssertTrue(src.contains("case .agent(let card):"))
        XCTAssertTrue(src.contains("subAgentRow(card)"))
        XCTAssertTrue(src.contains("Text(SkillCardCopy.verb(card))"))
        XCTAssertTrue(src.contains("Text(SkillCardCopy.status(card))"))
        XCTAssertTrue(src.contains("Text(SubAgentCardCopy.title)"))
        XCTAssertTrue(src.contains("Text(\"\\(SubAgentCardCopy.verb(card)) · \\(SubAgentCardCopy.status(card))\")"))
        XCTAssertTrue(src.contains("accessibilityLabel(\"\\(SkillCardCopy.verb(card)) · \\(SkillCardCopy.status(card))\")"))
        XCTAssertTrue(src.contains("accessibilityLabel(\"\\(SubAgentCardCopy.title) · \\(SubAgentCardCopy.verb(card))\")"))
        XCTAssertEqual(src.components(separatedBy: "private func skillRow(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "private func subAgentRow(").count - 1, 1)
        XCTAssertFalse(src.contains("Ask ZCode"))
        assertNotProductIdentityLies(in: src, file: "ZCodeActivityLineView.swift")
    }

    func testSkillSubAgentCopyDoesNotClaimZCodeOrStamp99() throws {
        let files = [
            "Utilities/SettingsDiscoverabilityCopy.swift",
            "Views/Chat/ZCodeActivityLineView.swift",
        ]
        for rel in files {
            assertNotProductIdentityLies(in: try appSource(rel), file: rel)
        }
        XCTAssertFalse(SkillCardCopy.verb(SkillCard(index: 0, isRunning: true, skillName: "x")).localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(SubAgentCardCopy.title.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(SubAgentCardCopy.title.localizedCaseInsensitiveContains("99%"))
        XCTAssertFalse(SkillCardCopy.status(SkillCard(index: 0, isRunning: false, skillName: "x")).localizedCaseInsensitiveContains("unsloth"))
        XCTAssertEqual(SubAgentCardCopy.title, "SubAgent")
        XCTAssertEqual(SkillCardCopy.verb(SkillCard(index: 0, isRunning: false, skillName: "x")), "Ran skill")
    }

    func testUngroupedSubAgentRowUsesGroupedLaunchingCopyNotTypeDescChrome() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        let ungrouped = slice(src, start: "private var subagentRow: some View {", end: "private var subagentStatusText:")
        XCTAssertFalse(ungrouped.isEmpty, "ungrouped SubAgent row must exist")
        XCTAssertTrue(src.contains("if isAgentFamily {"))
        XCTAssertTrue(src.contains("private var isAgentFamily:"))
        XCTAssertTrue(src.contains("private var asAgentCard: AgentCard"))
        XCTAssertTrue(ungrouped.contains("Text(SubAgentCardCopy.title)"))
        XCTAssertTrue(ungrouped.contains("Text(SubAgentCardCopy.verb(asAgentCard))"))
        XCTAssertTrue(ungrouped.contains("Text(SubAgentCardCopy.status(asAgentCard))"))
        // Old dual chrome: [box] SubAgent {type} · {desc} — not Launching/Launched.
        XCTAssertFalse(ungrouped.contains("Text(taskArgs.type)"))
        XCTAssertFalse(ungrouped.contains("Text(subagentStatusText)"))
        XCTAssertFalse(ungrouped.contains("Text(\"SubAgent\")"))
        XCTAssertFalse(ungrouped.contains("Theme.Palette.subagentType"))
        XCTAssertFalse(ungrouped.contains("general-purpose"))
        let grouped = slice(src, start: "private func subAgentRow(", end: "private var toolsHeader")
        XCTAssertTrue(grouped.contains("Text(SubAgentCardCopy.title)"))
        XCTAssertTrue(grouped.contains("Text(\"\\(SubAgentCardCopy.verb(card)) · \\(SubAgentCardCopy.status(card))\")"))
        XCTAssertEqual(SubAgentCardCopy.verb(AgentCard(index: 0, isRunning: true, prompt: "x")), "Launching")
        XCTAssertEqual(SubAgentCardCopy.verb(AgentCard(index: 0, isRunning: false, prompt: "x")), "Launched")
        XCTAssertFalse(ungrouped.localizedCaseInsensitiveContains("zcode"))
        XCTAssertFalse(ungrouped.localizedCaseInsensitiveContains("99%"))
    }

    func testPaintedCopyOmitsOpenInSidePaneAndLatestRows() throws {
        let src = try appSource("Views/Chat/ZCodeActivityLineView.swift")
        let skillFn = slice(src, start: "private func skillRow(", end: "private func subAgentRow(")
        let agentFn = slice(src, start: "private func subAgentRow(", end: "private var toolsHeader")
        XCTAssertFalse(skillFn.contains("Open in side pane"))
        XCTAssertFalse(agentFn.contains("Open in side pane"))
        XCTAssertFalse(agentFn.contains("Latest "))
        XCTAssertFalse(agentFn.contains("rows"))
        XCTAssertTrue(agentFn.contains("SubAgentCardCopy.title"))
        XCTAssertTrue(skillFn.contains("SkillCardCopy.verb"))
    }

    // MARK: - helpers

    private func slice(_ src: String, start: String, end: String) -> String {
        guard let a = src.range(of: start), let b = src.range(of: end) else { return "" }
        return String(src[a.lowerBound..<b.lowerBound])
    }

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

//
//  SlashCommandDispatcherTests.swift
//
//  Characterization of parse → route → SlashCommandResult so the contract
//  lives with the extracted type, not the frozen ChatViewModel.
//

import XCTest
@testable import AgentCore

@MainActor
final class SlashCommandDispatcherTests: XCTestCase {

    func testNonSlashIsNotACommand() {
        let host = MockSlashHost()
        XCTAssertEqual(
            SlashCommandDispatcher.dispatch("hello", host: host),
            .notACommand)
        XCTAssertEqual(
            SlashCommandDispatcher.dispatch("", host: host),
            .notACommand)
    }

    func testUnknownCommandIsNotACommand() {
        let host = MockSlashHost()
        XCTAssertEqual(
            SlashCommandDispatcher.dispatch("/not-a-real-command", host: host),
            .notACommand)
        XCTAssertEqual(host.expandedName, "/not-a-real-command")
        XCTAssertNil(host.customExpansion)
    }

    func testUnknownCustomCommandExpands() {
        let host = MockSlashHost()
        host.customExpansion = "Run custom command /ship\n\nbody"
        let result = SlashCommandDispatcher.dispatch("/ship prod", host: host)
        XCTAssertEqual(host.expandedName, "/ship")
        XCTAssertEqual(host.expandedArgs, "prod")
        XCTAssertEqual(result, .expandToMessage("Run custom command /ship\n\nbody"))
    }

    func testHelpRoutesToHostAndSetsStatus() {
        let host = MockSlashHost()
        host.helpText = "Available commands:\n  /compact"
        let result = SlashCommandDispatcher.dispatch("/help compact", host: host)
        XCTAssertEqual(host.statusLine, "Slash command help")
        XCTAssertEqual(host.helpFilter, "compact")
        XCTAssertEqual(result, .handled(message: "Available commands:\n  /compact"))
    }

    func testHelpAlias() {
        let host = MockSlashHost()
        host.helpText = "help-body"
        let parsed = SlashCommandDispatcher.parse("/?")
        XCTAssertEqual(parsed?.command, "/help")
        let result = SlashCommandDispatcher.dispatch("/?", host: host)
        XCTAssertEqual(result, .handled(message: "help-body"))
    }

    func testParseResolvesAliasesAndArgs() {
        XCTAssertEqual(SlashCommandDispatcher.parse("/m opus")?.command, "/model")
        XCTAssertEqual(SlashCommandDispatcher.parse("/m opus")?.args, "opus")
        XCTAssertEqual(SlashCommandDispatcher.parse("/title New Name")?.command, "/rename")
        XCTAssertEqual(SlashCommandDispatcher.parse(" /compact keep auth")?.command.lowercased(), "/compact")
        XCTAssertEqual(SlashCommandDispatcher.parse(" /compact keep auth")?.args, "keep auth")
        XCTAssertNil(SlashCommandDispatcher.parse("hello"))
    }

    func testCompactSlashRoutesToHost() {
        let host = MockSlashHost()
        host.compactResult = .handled(message: "Compacting…")
        let result = SlashCommandDispatcher.dispatch("/compact keep auth", host: host)
        XCTAssertEqual(host.compactPreserve, "keep auth")
        XCTAssertEqual(result, .handled(message: "Compacting…"))
    }

    func testCommitUsageWithoutMessage() {
        let host = MockSlashHost()
        let result = SlashCommandDispatcher.dispatch("/commit", host: host)
        XCTAssertEqual(result, .handled(message: "Usage: /commit <message>"))
        XCTAssertNil(host.statusLine)
    }

    func testCommitWithoutProject() {
        let host = MockSlashHost()
        let result = SlashCommandDispatcher.dispatch("/commit add tests", host: host)
        XCTAssertEqual(
            result,
            .handled(message: "No project open — open a folder before /commit."))
    }

    func testNewConversationRoutesToHost() {
        let host = MockSlashHost()
        let result = SlashCommandDispatcher.dispatch("/new", host: host)
        XCTAssertTrue(host.didNew)
        XCTAssertEqual(result, .handled(message: "Started a new conversation."))
    }

    func testClearRoutesToHost() {
        let host = MockSlashHost()
        let result = SlashCommandDispatcher.dispatch("/clear", host: host)
        XCTAssertTrue(host.didClear)
        XCTAssertEqual(result, .handled(message: "Cleared all messages."))
    }
}

@MainActor
private final class MockSlashHost: SlashCommandHost {
    var slashWorkingDirectory: URL?
    var slashProjectRoot: URL?

    var statusLine: String?
    var didNew = false
    var didClear = false
    var didHome = false
    var helpText = "Available commands:"
    var helpFilter: String?
    var customExpansion: String?
    var expandedName: String?
    var expandedArgs: String?
    var compactPreserve: String?
    var compactResult: SlashCommandResult = .handled(message: "compact")

    func slashSetStatusLine(_ text: String) { statusLine = text }
    func slashNewConversation() { didNew = true }
    func slashClearConversation() { didClear = true }
    func slashHome() { didHome = true }
    func slashFork() -> String { "forked" }
    func slashRename(to title: String) -> String { "Renamed to \"\(title)\"." }
    func slashExport() {}
    func slashQuit() {}
    func slashOpenSettings(pane: String?) { _ = pane }
    func slashHistoryPreview() -> String { "No prompt history yet." }
    func slashContextUsage() -> String { "Context usage" }
    func slashSessionInfo() -> String { "Session" }

    func slashCompact(preserve: String) -> SlashCommandResult {
        compactPreserve = preserve
        return compactResult
    }
    func slashUndo() -> SlashCommandResult { .handled(message: "undo") }
    func slashRewind() -> SlashCommandResult { .handled(message: "rewind") }
    func slashRestoreCheckpoint() -> SlashCommandResult { .handled(message: "restore") }
    func slashCopy(nth: String) -> SlashCommandResult { .handled(message: "copy \(nth)") }

    func slashModel(args: String) -> SlashCommandResult { .handled(message: "model \(args)") }
    func slashEffort(args: String) -> SlashCommandResult { .handled(message: "effort \(args)") }

    func slashPlan(args: String) -> SlashCommandResult { .handled(message: "plan \(args)") }
    func slashViewPlan() -> SlashCommandResult { .handled(message: "view-plan") }
    func slashApprovePlan() {}
    func slashStayPlan() {}
    func slashToggleAlwaysApprove() -> SlashCommandResult { .handled(message: "yolo") }
    func slashToggleAuto() -> SlashCommandResult { .handled(message: "auto") }

    func slashGoal(args: String) -> SlashCommandResult { .handled(message: "goal \(args)") }
    func slashRemember(args: String) -> SlashCommandResult { .handled(message: "remember \(args)") }
    func slashSkill(args: String) -> SlashCommandResult { .handled(message: "skill \(args)") }
    func slashLoop(args: String) -> SlashCommandResult { .handled(message: "loop \(args)") }

    func slashHelpText(filter: String) -> String {
        helpFilter = filter
        return helpText
    }
    func slashExpandCustomCommand(name: String, args: String) -> String? {
        expandedName = name
        expandedArgs = args
        return customExpansion
    }
}

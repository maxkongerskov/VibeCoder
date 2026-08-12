//
//  SlashCommandServiceTests.swift
//
//  Unit tests for Grok Build–parity slash command parsing, aliases,
//  autocomplete filtering, and help text.
//

import XCTest
@testable import VibeCoderApp

final class SlashCommandServiceTests: XCTestCase {

    func testParseRejectsNonSlash() {
        XCTAssertNil(SlashCommandService.parse("hello"))
        XCTAssertNil(SlashCommandService.parse(""))
        // Leading whitespace is trimmed — still a valid slash command.
        XCTAssertNotNil(SlashCommandService.parse(" /compact"))
    }

    func testParseBasicCommandAndArgs() {
        let parsed = SlashCommandService.parse("/compact keep auth details")
        XCTAssertEqual(parsed?.command.lowercased(), "/compact")
        XCTAssertEqual(parsed?.args, "keep auth details")
    }

    func testParseAliases() {
        XCTAssertEqual(SlashCommandService.parse("/m")?.command, "/model")
        XCTAssertEqual(SlashCommandService.parse("/title New Name")?.command, "/rename")
        XCTAssertEqual(SlashCommandService.parse("/title New Name")?.args, "New Name")
        XCTAssertEqual(SlashCommandService.parse("/exit")?.command, "/quit")
        XCTAssertEqual(SlashCommandService.parse("/config")?.command, "/settings")
        XCTAssertEqual(SlashCommandService.parse("/?")?.command, "/help")
    }

    func testGoalSubcommandsStayAsArgs() {
        let pause = SlashCommandService.parse("/goal pause")
        XCTAssertEqual(pause?.command.lowercased(), "/goal")
        XCTAssertEqual(pause?.args, "pause")

        let objective = SlashCommandService.parse("/goal Migrate auth to new API")
        XCTAssertEqual(objective?.command.lowercased(), "/goal")
        XCTAssertEqual(objective?.args, "Migrate auth to new API")
    }

    func testCommandLookup() {
        XCTAssertNotNil(SlashCommandService.command(named: "/compact"))
        XCTAssertNotNil(SlashCommandService.command(named: "/m")) // alias
        XCTAssertNil(SlashCommandService.command(named: "/not-a-real-command"))
    }

    func testMatchingCommandsPrefix() {
        let matches = SlashCommandService.matchingCommands(draft: "/com")
        XCTAssertTrue(matches.contains { $0.name == "/compact" })
        // After a space, menu hides (user typing args).
        XCTAssertTrue(SlashCommandService.matchingCommands(draft: "/compact keep").isEmpty)
    }

    func testMatchingBareSlashReturnsCatalog() {
        let matches = SlashCommandService.matchingCommands(draft: "/")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.count <= 12)
    }

    func testHelpTextListsCategories() {
        let help = SlashCommandService.helpText()
        XCTAssertTrue(help.contains("/compact"))
        XCTAssertTrue(help.contains("Session:"))
        XCTAssertTrue(help.contains("Model:"))
    }

    func testHelpTextSpecificCommand() {
        let help = SlashCommandService.helpText(filter: "compact")
        XCTAssertTrue(help.contains("/compact"))
        XCTAssertTrue(help.contains("Compress"))
    }

    func testIsSlashDraft() {
        XCTAssertTrue(SlashCommandService.isSlashDraft("/compact"))
        XCTAssertTrue(SlashCommandService.isSlashDraft("  /model "))
        XCTAssertFalse(SlashCommandService.isSlashDraft("hello"))
    }

    // MARK: - /skill

    func testSkillCommandRegisteredAndAliased() {
        XCTAssertNotNil(SlashCommandService.command(named: "/skill"))
        XCTAssertEqual(SlashCommandService.parse("/skills")?.command, "/skill")
        XCTAssertEqual(SlashCommandService.parse("/skill verify")?.command, "/skill")
        XCTAssertEqual(SlashCommandService.parse("/skill verify")?.args, "verify")
        XCTAssertTrue(SlashCommandService.helpText().contains("/skill"))
        XCTAssertTrue(SlashCommandService.helpText().contains("Skills:"))
    }

    func testParseSkillArgs() {
        XCTAssertNil(SlashCommandService.parseSkillArgs(""))
        XCTAssertNil(SlashCommandService.parseSkillArgs("   "))
        let one = SlashCommandService.parseSkillArgs("verify")
        XCTAssertEqual(one?.name, "verify")
        XCTAssertEqual(one?.skillArgs, "")
        let two = SlashCommandService.parseSkillArgs("verify focus on tests")
        XCTAssertEqual(two?.name, "verify")
        XCTAssertEqual(two?.skillArgs, "focus on tests")
    }

    func testSkillCatalogListsBundledVerify() {
        let catalog = SlashCommandService.formatSkillCatalog(
            projectRoot: nil,
            worktreeRoot: nil,
            includeBundled: true
        )
        XCTAssertTrue(catalog.contains("verify"), "bundled verify skill should be listed")
        XCTAssertTrue(catalog.contains("Usage: /skill"))
    }

    func testEvaluateSkillCommandListAndLoad() {
        let listed = SlashCommandService.evaluateSkillCommand(
            args: "",
            projectRoot: nil,
            worktreeRoot: nil
        )
        if case .list(let text) = listed {
            XCTAssertTrue(text.contains("verify"))
        } else {
            XCTFail("expected list outcome, got \(listed)")
        }

        let loaded = SlashCommandService.evaluateSkillCommand(
            args: "verify focus",
            projectRoot: nil,
            worktreeRoot: nil
        )
        if case .loaded(let name, let envelope, let status) = loaded {
            XCTAssertEqual(name, "verify")
            XCTAssertTrue(envelope.contains("<skill name=\"verify\""))
            XCTAssertTrue(envelope.contains("args=\"focus\""))
            XCTAssertTrue(envelope.contains("</skill>"))
            XCTAssertTrue(status.contains("verify"))
            XCTAssertTrue(status.contains("next message"))
        } else {
            XCTFail("expected loaded outcome, got \(loaded)")
        }
    }

    func testEvaluateSkillCommandUnknown() {
        let failed = SlashCommandService.evaluateSkillCommand(
            args: "definitely-not-a-skill-xyz",
            projectRoot: nil,
            worktreeRoot: nil
        )
        if case .failed(let msg) = failed {
            XCTAssertTrue(msg.contains("Unknown skill"))
            XCTAssertTrue(msg.contains("Available:"))
        } else {
            XCTFail("expected failed outcome, got \(failed)")
        }
    }

    func testEvaluateSkillCommandDiscoversProjectSkill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa8-skill-\(UUID().uuidString)", isDirectory: true)
        let skillDir = root
            .appendingPathComponent(".vibecoder", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("demo-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let md = """
        ---
        name: demo-skill
        description: Demo skill for slash /skill tests.
        ---
        # Demo
        Do the demo thing.
        """
        try md.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = SlashCommandService.evaluateSkillCommand(
            args: "demo-skill",
            projectRoot: root,
            worktreeRoot: nil,
            includeBundled: false,
            home: root // isolate from user home skills
        )
        if case .loaded(let name, let envelope, _) = outcome {
            XCTAssertEqual(name, "demo-skill")
            XCTAssertTrue(envelope.contains("Do the demo thing"))
        } else {
            XCTFail("expected loaded project skill, got \(outcome)")
        }
    }

    func testCommitAndPRSlashCatalog() {
        XCTAssertNotNil(SlashCommandService.command(named: "/commit"))
        XCTAssertNotNil(SlashCommandService.command(named: "/pr"))
        XCTAssertEqual(SlashCommandService.parse("/git-commit fix typo")?.command, "/commit")
        XCTAssertEqual(SlashCommandService.parse("/git-commit fix typo")?.args, "fix typo")
        XCTAssertEqual(SlashCommandService.parse("/pull-request My PR")?.command, "/pr")
        XCTAssertTrue(SlashCommandService.helpText().contains("/commit"))
        XCTAssertTrue(SlashCommandService.helpText().contains("Git"))
    }

}

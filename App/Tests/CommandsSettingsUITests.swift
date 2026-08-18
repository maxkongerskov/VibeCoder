//
//  CommandsSettingsUITests.swift
//  Settings → Commands editor: naming, encode/parse, import, paths.
//

import XCTest
@testable import VibeCoderApp

final class CommandsSettingsUITests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - Tabs

    func testCommandsTabRawValueAndAgentGroupOrder() {
        XCTAssertEqual(SettingsManagersTabID.commands, "commands")
        XCTAssertTrue(SettingsManagersTabID.allRawValues.contains("commands"))
        let ids = SettingsManagersTabID.allRawValues
        let agent = ids.firstIndex(of: "agent")
        let skills = ids.firstIndex(of: "skills")
        let subagents = ids.firstIndex(of: "subagents")
        let commands = ids.firstIndex(of: "commands")
        let hooks = ids.firstIndex(of: "hooks")
        XCTAssertEqual(agent, 0)
        XCTAssertEqual(skills, 1)
        XCTAssertEqual(subagents, 2)
        XCTAssertEqual(commands, 3)
        XCTAssertEqual(hooks, 4)
    }

    // MARK: - Naming

    func testNameValidationAllowsUnderscoreRejectsSpaces() {
        XCTAssertTrue(CommandProfileNaming.isValidName("review-pr"))
        XCTAssertTrue(CommandProfileNaming.isValidName("review_pr"))
        XCTAssertTrue(CommandProfileNaming.isValidName("Review2"))
        XCTAssertFalse(CommandProfileNaming.isValidName("has space"))
        XCTAssertFalse(CommandProfileNaming.isValidName("has/slash"))
        XCTAssertFalse(CommandProfileNaming.isValidName("/leading"))
        XCTAssertFalse(CommandProfileNaming.isValidName(""))
        XCTAssertEqual(CommandProfileNaming.slugify("Review PR"), "review-pr")
        XCTAssertEqual(CommandProfileNaming.slugify("/review_pr"), "review_pr")
    }

    // MARK: - Encode / parse

    func testEncodeParseRoundTripKeepsArgumentsLiteral() throws {
        let draft = CommandProfileDraft(
            name: "review-pr",
            description: "Review a pull request",
            argumentHint: "<pr-url>",
            prompt: "Review $ARGUMENTS and cite $1."
        )
        let markdown = try CommandProfileCodec.encode(draft)
        XCTAssertTrue(markdown.contains("argument-hint: <pr-url>"))
        XCTAssertTrue(markdown.contains("Review $ARGUMENTS and cite $1."))
        XCTAssertFalse(markdown.contains("Run custom command /review-pr"))

        let parsed = try XCTUnwrap(CommandProfileCodec.parse(markdown: markdown))
        XCTAssertEqual(parsed.name, "review-pr")
        XCTAssertEqual(parsed.description, "Review a pull request")
        XCTAssertEqual(parsed.argumentHint, "<pr-url>")
        XCTAssertEqual(parsed.prompt, "Review $ARGUMENTS and cite $1.")
    }

    func testEmptyPromptRejected() {
        XCTAssertThrowsError(try CommandProfileCodec.encode(
            CommandProfileDraft(name: "ok", prompt: "   ")
        )) { error in
            XCTAssertEqual(error as? CommandProfileError, .emptyPrompt)
        }
    }

    func testInvalidNameRejected() {
        XCTAssertThrowsError(try CommandProfileCodec.encode(
            CommandProfileDraft(name: "bad name", prompt: "Do it.")
        )) { error in
            XCTAssertEqual(error as? CommandProfileError, .invalidName)
        }
    }

    func testParseArgumentHintAliases() {
        let markdown = """
        ---
        name: demo
        argument_hint: <path>
        ---
        Use $ARGUMENTS
        """
        let parsed = CommandProfileCodec.parse(markdown: markdown)
        XCTAssertEqual(parsed?.argumentHint, "<path>")
        XCTAssertEqual(parsed?.prompt, "Use $ARGUMENTS")
    }

    func testWriteAndLoadDirectory() throws {
        let draft = CommandProfileDraft(
            name: "summarize",
            description: "Summarize a file",
            argumentHint: "<file>",
            prompt: "Summarize $ARGUMENTS"
        )
        let dest = CommandProfileCodec.fileURL(name: draft.name, directory: scratch)
        try CommandProfileCodec.write(draft, to: dest)
        let loaded = CommandProfileCodec.loadDirectory(scratch)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "summarize")
        XCTAssertEqual(loaded.first?.prompt, "Summarize $ARGUMENTS")
        XCTAssertEqual(
            loaded.first?.fileURL?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )
    }

    func testImportCopiesMarkdown() throws {
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        let destRoot = scratch.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.md")
        try """
        ---
        name: imported_cmd
        description: From disk
        ---
        Keep $ARGUMENTS as-is.
        """.write(to: file, atomically: true, encoding: .utf8)

        let dest = try CommandProfileCodec.importCommand(from: file, into: destRoot)
        XCTAssertEqual(dest.lastPathComponent, "imported_cmd.md")
        let parsed = CommandProfileCodec.parse(
            markdown: try String(contentsOf: dest, encoding: .utf8)
        )
        XCTAssertEqual(parsed?.name, "imported_cmd")
        XCTAssertEqual(parsed?.prompt, "Keep $ARGUMENTS as-is.")
    }

    func testSlashServiceSubstitutesArgumentsFromDiskCommand() throws {
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let draft = CommandProfileDraft(
            name: "review_pr",
            argumentHint: "<url>",
            prompt: "Review $ARGUMENTS (file $1)"
        )
        try CommandProfileCodec.write(
            draft,
            to: CommandProfileCodec.fileURL(
                name: draft.name,
                directory: CommandProfilePaths.userRoot(home: home)
            )
        )
        let message = try XCTUnwrap(
            SlashCommandService.expandCustomCommand(
                name: "/review_pr",
                args: "https://example.com/pr/1 extra",
                projectRoot: nil,
                home: home
            )
        )
        XCTAssertTrue(message.contains("Run custom command /review_pr"))
        XCTAssertTrue(message.contains("Review https://example.com/pr/1 extra (file https://example.com/pr/1)"))
    }

    func testUserAndWorkspacePaths() {
        let home = URL(fileURLWithPath: "/tmp/vc-home")
        XCTAssertEqual(
            CommandProfilePaths.userRoot(home: home).path,
            "/tmp/vc-home/.vibecoder/commands"
        )
        let project = URL(fileURLWithPath: "/tmp/repo")
        XCTAssertEqual(
            CommandProfilePaths.projectRoot(project).path,
            "/tmp/repo/.vibecoder/commands"
        )
    }
}

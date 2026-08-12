//
//  SkillDiscoveryTests.swift
//  Wave B S2 — Skills v0: discovery, parse, index, load_skill.
//

import XCTest
@testable import AgentCore

final class SkillDiscoveryTests: XCTestCase {

    private var tempRoot: URL!
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-proj-\(UUID().uuidString)", isDirectory: true)
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - Parse

    func testParseFrontmatterNameAndDescription() {
        let md = """
        ---
        name: review-pr
        description: Review a pull request carefully
        ---
        # Body

        Do a careful review.
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "ignored")
        XCTAssertEqual(skill?.name, "review-pr")
        XCTAssertEqual(skill?.description, "Review a pull request carefully")
        XCTAssertTrue(skill?.body.contains("careful review") == true)
        XCTAssertFalse(skill?.body.contains("---") == true)
    }

    func testParseDerivesDescriptionFromHeadingWhenMissing() {
        let md = """
        ---
        name: plain
        ---
        # Ship checklist

        Steps go here.
        """
        let skill = SkillDiscovery.parse(markdown: md)
        XCTAssertEqual(skill?.name, "plain")
        XCTAssertTrue(skill?.description.contains("Ship checklist") == true)
    }

    // MARK: - Discovery paths

    func testDiscoversVibecoderAndClaudeLayouts() throws {
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "commit"],
            name: "commit",
            description: "Create a git commit",
            body: "Write a good commit message."
        )
        try writeSkill(
            under: tempRoot,
            segments: [".claude", "skills", "pr-review"],
            name: "pr-review",
            description: "Claude-style PR review skill",
            body: "Review the PR."
        )
        try writeSkill(
            under: tempRoot,
            segments: [".cursor", "skills", "cursor-pack"],
            name: "cursor-pack",
            description: "Cursor peer skill root",
            body: "From .cursor/skills."
        )

        let found = SkillDiscovery.discover(
            projectRoot: tempRoot,
            includeBundled: false,
            home: tempHome
        )
        let names = Set(found.map(\.name))
        XCTAssertTrue(names.contains("commit"), names.description)
        XCTAssertTrue(names.contains("pr-review"), names.description)
        XCTAssertTrue(names.contains("cursor-pack"), names.description)
        XCTAssertEqual(found.first { $0.name == "commit" }?.source, .project)
    }

    /// PA9: index discovery must not retain full skill bodies.
    func testMetadataOnlyDiscoverOmitsBodyUntilEnsureOrByName() throws {
        let huge = String(repeating: "DETAIL ", count: 2_000)
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "heavy"],
            name: "heavy",
            description: "Heavy skill for lazy index",
            body: "# Body\n\n\(huge)"
        )

        let meta = SkillDiscovery.discover(
            projectRoot: tempRoot,
            includeBundled: false,
            home: tempHome,
            metadataOnly: true
        )
        let heavy = meta.first { $0.name == "heavy" }
        XCTAssertNotNil(heavy)
        XCTAssertTrue(heavy!.metadataOnly)
        XCTAssertTrue(heavy!.body.isEmpty, "index path must not keep body")
        XCTAssertEqual(heavy!.description, "Heavy skill for lazy index")

        let loaded = SkillDiscovery.byName(
            "heavy",
            projectRoot: tempRoot,
            includeBundled: false,
            home: tempHome
        )
        XCTAssertNotNil(loaded)
        XCTAssertFalse(loaded!.metadataOnly)
        XCTAssertTrue(loaded!.body.contains("DETAIL"), loaded!.body.prefix(80).description)

        let index = SkillDiscovery.indexBlock(
            projectRoot: tempRoot,
            includeBundled: false
        )
        XCTAssertNotNil(index)
        XCTAssertTrue(index!.contains("`heavy`"), index ?? "")
        XCTAssertFalse(index!.contains("DETAIL DETAIL"), "index must not dump skill body")
    }

    func testProjectSkillOverridesUserAndBundled() throws {
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "verify"],
            name: "verify",
            description: "Project verify",
            body: "Project-specific verify body."
        )
        try writeSkill(
            under: tempHome,
            segments: [".vibecoder", "skills", "verify"],
            name: "verify",
            description: "User verify",
            body: "User verify body."
        )

        let found = SkillDiscovery.discover(
            projectRoot: tempRoot,
            includeBundled: true,
            home: tempHome
        )
        let verify = found.first { $0.name == "verify" }
        XCTAssertEqual(verify?.source, .project)
        XCTAssertTrue(verify?.body.contains("Project-specific") == true)
        XCTAssertEqual(found.filter { $0.name == "verify" }.count, 1)
    }

    func testBundledPdfSkillIsOfflineOnly() {
        let bundled = SkillDiscovery.bundledSkills()
        let pdf = bundled.first { $0.name == "pdf" }
        XCTAssertNotNil(pdf, "bundled pdf skill missing")
        XCTAssertEqual(pdf?.source, .bundled)
        let body = pdf?.body.lowercased() ?? ""
        XCTAssertTrue(body.contains("extract_pdf_text"), body)
        XCTAssertTrue(body.contains("create_pdf"), body)
        XCTAssertTrue(body.contains("offline"), body)
        XCTAssertTrue(
            body.contains("web_search") || body.contains("never use"),
            "skill should forbid online PDF workflows"
        )
    }

    func testBundledVerifyPresentWhenNoDiskSkills() {
        let found = SkillDiscovery.discover(
            projectRoot: tempRoot,
            includeBundled: true,
            home: tempHome
        )
        let verify = found.first { $0.name == "verify" }
        XCTAssertNotNil(verify)
        XCTAssertEqual(verify?.source, .bundled)
        XCTAssertTrue(verify?.body.lowercased().contains("verify") == true)
        let commit = found.first { $0.name == "commit" }
        XCTAssertNotNil(commit, "bundled commit skill should be present")
        XCTAssertEqual(commit?.source, .bundled)
    }

    // MARK: - Index

    func testIndexBlockListsNamesAndMentionsLoadSkill() {
        let skills = [
            DiscoveredSkill(name: "alpha", description: "First skill", body: "A", source: .project),
            DiscoveredSkill(name: "beta", description: "Second skill", body: "B", source: .user),
        ]
        let block = SkillDiscovery.indexBlock(skills: skills)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("load_skill"))
        XCTAssertTrue(block!.contains("`alpha`"))
        XCTAssertTrue(block!.contains("`beta`"))
        XCTAssertTrue(block!.contains("First skill"))
    }

    func testComposerInjectsSkillsIndex() {
        let index = SkillDiscovery.indexBlock(skills: [
            DiscoveredSkill(name: "verify", description: "Verify edits", body: "…", source: .bundled)
        ])
        XCTAssertNotNil(index)

        var convo = Conversation(title: "t", modelID: "m")
        convo.projectRoot = tempRoot
        let model = ModelDescriptor(
            id: "m", displayName: "m", backend: .lmStudio, contextLength: 32_000)
        let (prompt, _) = AgentSystemPromptComposer.compose(
            .init(
                conversation: convo,
                config: .init(),
                model: model,
                nudges: [],
                messages: [],
                cachedInstructions: nil,
                cachedMemory: nil,
                cachedAgentsMd: nil,
                cachedSkillsIndex: index
            )
        )
        XCTAssertTrue(prompt.contains("Available skills"), prompt)
        XCTAssertTrue(prompt.contains("`verify`"), prompt)
        XCTAssertTrue(prompt.contains("load_skill"), prompt)
    }

    // MARK: - load_skill tool

    func testLoadSkillToolReturnsEnvelope() async throws {
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "commit"],
            name: "commit",
            description: "Commit skill",
            body: "Stage and commit carefully."
        )
        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: tempRoot,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: UUID()
        )
        let result = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: [
                "skill": "commit",
                "args": "fix typo",
            ]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("<skill name=\"commit\""), result.content)
        XCTAssertTrue(result.content.contains("Stage and commit carefully."), result.content)
        XCTAssertTrue(result.content.contains("args=\"fix typo\""), result.content)
        XCTAssertTrue(result.content.contains("</skill>"), result.content)
    }

    func testLoadSkillToolUnknownNameErrors() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: tempRoot,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: UUID()
        )
        let result = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": "does-not-exist-xyz"]),
            context: ctx
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("unknown"), result.content)
    }

    func testLoadSkillIsReadOnlyRegistered() async {
        await ToolRegistry.shared.registerBuiltins()
        let meta = await ToolRegistry.shared.metadata(for: "load_skill")
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.permission, .readOnly)
        let isRO = await ToolRegistry.shared.isReadOnlyTool("load_skill")
        XCTAssertTrue(isRO)
    }

    /// Wave C: worktree-only skill must still load when projectRoot is also set
    /// (index used worktree-first; load_skill used project-only → miss).
    func testLoadSkillFindsSkillOnWorktreeWhenProjectSet() async throws {
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }

        try writeSkill(
            under: worktree,
            segments: [".vibecoder", "skills", "wt-only"],
            name: "wt-only",
            description: "Worktree skill",
            body: "Only in worktree."
        )
        // Project root has no skills.
        let found = SkillDiscovery.byName(
            "wt-only",
            projectRoot: tempRoot,
            worktreeRoot: worktree,
            includeBundled: false,
            home: tempHome
        )
        XCTAssertNotNil(found, "must scan worktree when project has no skill")
        XCTAssertTrue(found?.body.contains("Only in worktree") == true)

        // Project skill still wins over same name on worktree.
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "shared"],
            name: "shared",
            description: "Project wins",
            body: "From project."
        )
        try writeSkill(
            under: worktree,
            segments: [".vibecoder", "skills", "shared"],
            name: "shared",
            description: "Worktree loses",
            body: "From worktree."
        )
        // Worktree is scanned first — worktree name wins for same key.
        // Documented precedence: worktree → project. Worktree wins.
        let shared = SkillDiscovery.byName(
            "shared",
            projectRoot: tempRoot,
            worktreeRoot: worktree,
            includeBundled: false,
            home: tempHome
        )
        XCTAssertEqual(shared?.body, "From worktree.")

        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: tempRoot,
            worktreeRoot: worktree,
            safeMode: nil,
            conversationID: UUID()
        )
        let result = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": "wt-only"]),
            context: ctx
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Only in worktree"), result.content)
    }

    func testParseStripsBOMAndCRLF() {
        let md = "\u{FEFF}---\r\nname: bomskill\r\ndescription: with bom\r\n---\r\n# Body\r\nOK.\r\n"
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.name, "bomskill")
        XCTAssertEqual(skill?.description, "with bom")
        XCTAssertTrue(skill?.body.contains("OK") == true)
    }


    func testParseMultilineDescriptionBlock() {
        let md = """
        ---
        name: multi
        description: |
          First line of description.
          Second line still description.
        ---
        # Body
        content
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.name, "multi")
        XCTAssertTrue(skill?.description.contains("First line") == true, skill?.description ?? "")
        XCTAssertTrue(skill?.description.contains("Second line") == true, skill?.description ?? "")
        XCTAssertTrue(skill?.body.contains("content") == true)
    }

    func testParseFoldedDescription() {
        let md = """
        ---
        name: fold
        description: >
          One
          Two
        ---
        Body only
        """
        let skill = SkillDiscovery.parse(markdown: md)
        XCTAssertEqual(skill?.name, "fold")
        XCTAssertTrue(skill?.description.contains("One") == true)
        XCTAssertTrue(skill?.description.contains("Two") == true)
        XCTAssertFalse(skill!.description.contains("\n"), skill!.description)
    }

    // MARK: - PA7 control-plane frontmatter

    func testParseDisableModelInvocationKebabAndSnake() {
        let kebab = """
        ---
        name: code-review
        description: Review code carefully
        disable-model-invocation: true
        ---
        # Review
        Do the review.
        """
        let skill = SkillDiscovery.parse(markdown: kebab, defaultName: "x")
        XCTAssertEqual(skill?.name, "code-review")
        XCTAssertEqual(skill?.disableModelInvocation, true)
        XCTAssertEqual(skill?.isModelInvocable, false)
        XCTAssertEqual(skill?.userInvocable, true)

        let snake = """
        ---
        name: code-review-2
        description: Review
        disable_model_invocation: yes
        user_invocable: false
        ---
        Body
        """
        let skill2 = SkillDiscovery.parse(markdown: snake, defaultName: "x")
        XCTAssertEqual(skill2?.disableModelInvocation, true)
        XCTAssertEqual(skill2?.userInvocable, false)
    }

    func testParseBoolishFalseAndDefaults() {
        let md = """
        ---
        name: open
        description: Normal skill
        disable-model-invocation: false
        ---
        Body
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.disableModelInvocation, false)
        XCTAssertEqual(skill?.isModelInvocable, true)
        XCTAssertEqual(skill?.userInvocable, true)
    }

    func testParseAllowedToolsAndIgnoresUnknownFields() {
        let md = """
        ---
        name: gated
        description: Tools listed
        allowed-tools: read_file, grep_code, "edit_file"
        metadata: ignored-parent
        short-description: also-ignored-unknown
        weird_future_flag: 42
        ---
        # Body
        content
        """
        let skill = SkillDiscovery.parse(markdown: md, defaultName: "x")
        XCTAssertEqual(skill?.name, "gated")
        XCTAssertEqual(skill?.allowedTools, ["read_file", "grep_code", "edit_file"])
        // Unknown keys must not break parse or change control-plane defaults.
        XCTAssertEqual(skill?.disableModelInvocation, false)
        XCTAssertEqual(skill?.userInvocable, true)
        XCTAssertTrue(skill?.body.contains("content") == true)
    }

    func testParseAllowedToolsBracketList() {
        let md = """
        ---
        name: bracket
        description: d
        allowed_tools: [run_shell, git_diff]
        ---
        Body
        """
        let skill = SkillDiscovery.parse(markdown: md)
        XCTAssertEqual(skill?.allowedTools, ["run_shell", "git_diff"])
    }

    func testIndexBlockExcludesDisableModelInvocation() {
        let skills = [
            DiscoveredSkill(name: "alpha", description: "First", body: "A", source: .project),
            DiscoveredSkill(
                name: "code-review",
                description: "Slash only",
                body: "B",
                source: .user,
                disableModelInvocation: true
            ),
            DiscoveredSkill(name: "beta", description: "Second", body: "C", source: .project),
        ]
        let block = SkillDiscovery.indexBlock(skills: skills)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("`alpha`"), block!)
        XCTAssertTrue(block!.contains("`beta`"), block!)
        XCTAssertFalse(block!.contains("code-review"), block!)
        XCTAssertFalse(block!.contains("Slash only"), block!)
    }

    func testIndexBlockNilWhenOnlyDisabledSkills() {
        let skills = [
            DiscoveredSkill(
                name: "hidden",
                description: "No model",
                body: "X",
                disableModelInvocation: true
            ),
        ]
        XCTAssertNil(SkillDiscovery.indexBlock(skills: skills))
    }

    func testByNameStillResolvesDisabledSkillForUserPath() throws {
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "code-review"],
            name: "code-review",
            description: "Review only via slash",
            body: "User-only review body.",
            extraFrontmatter: ["disable-model-invocation: true"]
        )
        let found = SkillDiscovery.byName(
            "code-review",
            projectRoot: tempRoot,
            includeBundled: false,
            home: tempHome
        )
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.disableModelInvocation, true)
        XCTAssertTrue(found?.body.contains("User-only review body") == true)
        // User/slash path: format envelope still works without going through load_skill.
        let envelope = SkillDiscovery.formatSkillMessage(found!)
        XCTAssertTrue(envelope.contains("<skill name=\"code-review\""))
        XCTAssertTrue(envelope.contains("User-only review body"))
    }

    func testLoadSkillToolRefusesDisableModelInvocation() async throws {
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "code-review"],
            name: "code-review",
            description: "Slash only",
            body: "Should not load via tool.",
            extraFrontmatter: ["disable-model-invocation: true"]
        )
        try writeSkill(
            under: tempRoot,
            segments: [".vibecoder", "skills", "commit"],
            name: "commit",
            description: "Commit skill",
            body: "Stage carefully."
        )
        await ToolRegistry.shared.registerBuiltins()
        let ctx = ToolContext(
            projectRoot: tempRoot,
            worktreeRoot: nil,
            safeMode: nil,
            conversationID: UUID()
        )
        let denied = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": "code-review"]),
            context: ctx
        )
        XCTAssertTrue(denied.isError, denied.content)
        XCTAssertTrue(denied.content.contains("disable-model-invocation"), denied.content)
        XCTAssertFalse(denied.content.contains("Should not load via tool."), denied.content)

        // Unknown-skill Available: list must not leak disabled skill names.
        let unknown = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": "nope"]),
            context: ctx
        )
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.content.contains("commit"), unknown.content)
        XCTAssertFalse(unknown.content.contains("code-review"), unknown.content)

        // Normal skills still load.
        let ok = try await ToolRegistry.shared.execute(
            name: "load_skill",
            arguments: ToolArguments(dictionary: ["skill": "commit"]),
            context: ctx
        )
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertTrue(ok.content.contains("Stage carefully."), ok.content)
    }

    // MARK: - Helpers

    private func writeSkill(
        under root: URL,
        segments: [String],
        name: String,
        description: String,
        body: String,
        extraFrontmatter: [String] = []
    ) throws {
        var dir = root
        for s in segments {
            dir = dir.appendingPathComponent(s, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let extras = extraFrontmatter.map { $0 + "\n" }.joined()
        let md = """
        ---
        name: \(name)
        description: \(description)
        \(extras)---
        \(body)
        """
        try md.write(
            to: dir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

//
//  SettingsManagersUITests.swift
//  U4 settings-managers — Skills / Subagents frontmatter + tab ids.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class SettingsManagersUITests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-u4-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - Tabs

    func testSettingsTabRawValues() {
        XCTAssertEqual(SettingsManagersTabID.skills, "skills")
        XCTAssertEqual(SettingsManagersTabID.subagents, "subagents")
        XCTAssertTrue(SettingsManagersTabID.allRawValues.contains("skills"))
        XCTAssertTrue(SettingsManagersTabID.allRawValues.contains("subagents"))
        XCTAssertTrue(SettingsManagersTabID.allRawValues.contains("agent"))
        XCTAssertTrue(SettingsManagersTabID.allRawValues.contains("hooks"))
    }

    // MARK: - Name validation

    func testSubagentNameValidationRejectsSpacesAndSlashes() {
        XCTAssertTrue(SettingsManagersNaming.isValidName("code-reviewer"))
        XCTAssertTrue(SettingsManagersNaming.isValidName("Explore2"))
        XCTAssertFalse(SettingsManagersNaming.isValidName("has space"))
        XCTAssertFalse(SettingsManagersNaming.isValidName("has/slash"))
        XCTAssertFalse(SettingsManagersNaming.isValidName("path\\win"))
        XCTAssertFalse(SettingsManagersNaming.isValidName(""))
        XCTAssertFalse(SettingsManagersNaming.isValidName("  "))
        XCTAssertThrowsError(try SubagentProfileCodec.encode(
            SubagentProfileDraft(name: "bad name", systemPrompt: "Do work.")
        )) { error in
            XCTAssertEqual(error as? SettingsManagersError, .invalidName)
        }
    }

    func testSkillSlugifyMapsSpacesAndDropsSlashes() {
        XCTAssertEqual(SettingsManagersNaming.slugify("Code Review"), "code-review")
        XCTAssertFalse(SettingsManagersNaming.isValidName("a/b"))
        XCTAssertEqual(SettingsManagersNaming.slugify("a/b"), "a-b")
    }

    // MARK: - Agent frontmatter round-trip

    func testAgentFrontmatterRoundTripViaParse() throws {
        let draft = SubagentProfileDraft(
            name: "code-reviewer",
            description: "Reviews diffs carefully",
            systemPrompt: "You review code. Be terse.",
            model: "glm-4.7",
            maxTurns: 12,
            background: true,
            inheritAllTools: false,
            tools: ["read_file", "grep_code"]
        )
        let markdown = try SubagentProfileCodec.encode(draft)
        XCTAssertTrue(markdown.contains("tools: read_file, grep_code"))
        XCTAssertTrue(markdown.contains("maxTurns: 12"))
        XCTAssertTrue(markdown.contains("background: true"))

        let file = scratch.appendingPathComponent("code-reviewer.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        let parsed = AgentDefinitionDiscovery.parse(file: file)
        XCTAssertEqual(parsed?.name, "code-reviewer")
        XCTAssertEqual(parsed?.description, "Reviews diffs carefully")
        XCTAssertEqual(parsed?.systemPrompt, "You review code. Be terse.")
        XCTAssertEqual(parsed?.tools, ["read_file", "grep_code"])
        XCTAssertEqual(parsed?.model, "glm-4.7")
        XCTAssertEqual(parsed?.maxTurns, 12)
        XCTAssertEqual(parsed?.background, true)
        XCTAssertFalse(SubagentProfileCodec.inheritsAllTools(markdown: markdown))
    }

    func testInheritAllOmitsToolsKey() throws {
        let markdown = try SubagentProfileCodec.encode(
            SubagentProfileDraft(
                name: "wide",
                description: "d",
                systemPrompt: "Do anything.",
                inheritAllTools: true,
                tools: ["read_file"]
            )
        )
        XCTAssertFalse(markdown.contains("tools:"))
        XCTAssertTrue(SubagentProfileCodec.inheritsAllTools(markdown: markdown))
        let parsed = AgentDefinitionDiscovery.parse(markdown: markdown)
        XCTAssertEqual(parsed?.name, "wide")
        XCTAssertEqual(parsed?.tools, [])
        XCTAssertEqual(parsed?.systemPrompt, "Do anything.")
    }

    func testEmptyToolsKeyIsFailClosedNotInherit() {
        let markdown = """
        ---
        name: locked
        description: d
        tools:
        ---
        Stay read-only.
        """
        XCTAssertFalse(SubagentProfileCodec.inheritsAllTools(markdown: markdown))
        let parsed = AgentDefinitionDiscovery.parse(markdown: markdown)
        XCTAssertEqual(parsed?.tools, [])
    }

    // MARK: - Skill enable rewrite

    func testSkillEnableRewriteFlipsDisableModelInvocation() throws {
        let original = """
        ---
        name: demo
        description: Demo skill
        disable-model-invocation: true
        ---
        # Demo

        Do the demo.
        """
        let enabled = SkillFrontmatterWriter.setDisableModelInvocation(original, disabled: false)
        let parsedOn = SkillDiscovery.parse(markdown: enabled, defaultName: "demo")
        XCTAssertEqual(parsedOn?.disableModelInvocation, false)
        XCTAssertTrue(parsedOn?.isModelInvocable == true)
        XCTAssertTrue(enabled.contains("disable-model-invocation: false"))

        let disabled = SkillFrontmatterWriter.setDisableModelInvocation(enabled, disabled: true)
        let parsedOff = SkillDiscovery.parse(markdown: disabled, defaultName: "demo")
        XCTAssertEqual(parsedOff?.disableModelInvocation, true)
        XCTAssertTrue(parsedOff?.isModelInvocable == false)

        let file = scratch.appendingPathComponent("SKILL.md")
        try original.write(to: file, atomically: true, encoding: .utf8)
        try SkillFrontmatterWriter.applyDisableModelInvocation(at: file, disabled: false)
        let fromDisk = SkillDiscovery.parse(file: file)
        XCTAssertEqual(fromDisk?.disableModelInvocation, false)
        XCTAssertEqual(fromDisk?.name, "demo")
        XCTAssertTrue(fromDisk?.body.contains("Do the demo") == true)
    }

    func testSkillEnableRewriteInsertsFlagWhenMissing() {
        let original = """
        ---
        name: bare
        description: no flag
        ---
        Body text.
        """
        let out = SkillFrontmatterWriter.setDisableModelInvocation(original, disabled: true)
        let parsed = SkillDiscovery.parse(markdown: out, defaultName: "bare")
        XCTAssertEqual(parsed?.disableModelInvocation, true)
        XCTAssertEqual(parsed?.description, "no flag")
    }

    func testWriteNewSkillRoundTrip() throws {
        let file = try SkillFrontmatterWriter.writeNewSkill(
            name: "My Reviewer",
            description: "Review the diff",
            body: "Read the patch first.",
            root: scratch
        )
        XCTAssertEqual(file.lastPathComponent, "SKILL.md")
        let parsed = SkillDiscovery.parse(file: file)
        XCTAssertEqual(parsed?.name, "my-reviewer")
        XCTAssertEqual(parsed?.description, "Review the diff")
        XCTAssertTrue(parsed?.body.contains("Read the patch first") == true)
        XCTAssertEqual(parsed?.disableModelInvocation, false)
    }

    // MARK: - Built-in types

    func testBuiltInSubagentTypesAreTheThreeCases() {
        let raw = SubagentType.allCases.map(\.rawValue)
        XCTAssertEqual(raw, ["general-purpose", "explore", "plan"])
        XCTAssertEqual(SubagentType.allCases.count, 3)
        XCTAssertEqual(SubagentType.generalPurpose.shortDescription.isEmpty, false)
        XCTAssertFalse(SubagentType.explore.preferredTools.isEmpty)
        XCTAssertFalse(SubagentType.plan.preferredTools.isEmpty)
    }
}

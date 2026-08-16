//
//  ParitySubagentProfilesTests.swift
//
//  Markdown agent profile frontmatter + AgentMailbox + send_message.
//

import XCTest
@testable import AgentCore

final class ParitySubagentProfilesTests: XCTestCase {

    override func setUp() async throws {
        await AgentMailbox.shared.reset()
    }

    override func tearDown() async throws {
        await AgentMailbox.shared.reset()
    }

    // MARK: - Frontmatter parse + mapping

    func testParseProfileFieldsKeepsToolsAndPrompt() {
        let md = """
        ---
        name: builder
        description: Strong builder
        model: glm-4.7
        thoughtLevel: high
        permissionMode: edit
        maxTurns: 12
        background: true
        tools: read_file, write_file
        ---
        You implement the plan.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.name, "builder")
        XCTAssertEqual(def?.description, "Strong builder")
        XCTAssertEqual(def?.systemPrompt, "You implement the plan.")
        XCTAssertEqual(def?.tools, ["read_file", "write_file"])
        XCTAssertEqual(def?.model, "glm-4.7")
        XCTAssertEqual(def?.thoughtLevel, "high")
        XCTAssertEqual(def?.permissionMode, .edit)
        XCTAssertEqual(def?.maxTurns, 12)
        XCTAssertEqual(def?.background, true)
        XCTAssertEqual(def?.profileSettings.model, "glm-4.7")
        XCTAssertEqual(def?.profileSettings.maxTurns, 12)
    }

    func testEffortAliasWhenThoughtLevelMissing() {
        let md = """
        ---
        name: thinker
        description: d
        effort: max
        ---
        Think hard.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.thoughtLevel, "max")
        XCTAssertNil(def?.model)
        XCTAssertNil(def?.permissionMode)
        XCTAssertNil(def?.maxTurns)
        XCTAssertNil(def?.background)
    }

    func testThoughtLevelWinsOverEffort() {
        let md = """
        ---
        name: prefer
        description: d
        thoughtLevel: low
        effort: max
        ---
        Prefer thoughtLevel.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.thoughtLevel, "low")
    }

    func testPermissionModeAcceptEditsMapsToEdit() {
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("acceptEdits"), .edit)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("accept_edits"), .edit)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("accept-edits"), .edit)
        let md = """
        ---
        name: auto
        description: d
        permissionMode: acceptEdits
        ---
        Body.
        """
        XCTAssertEqual(AgentDefinitionDiscovery.parse(markdown: md)?.permissionMode, .edit)
    }

    func testPermissionModeBypassPermissionsMapsToYolo() {
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("bypassPermissions"), .yolo)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("bypass_permissions"), .yolo)
        let md = """
        ---
        name: wild
        description: d
        permission_mode: bypassPermissions
        ---
        Body.
        """
        XCTAssertEqual(AgentDefinitionDiscovery.parse(markdown: md)?.permissionMode, .yolo)
    }

    func testPermissionModeCanonicalValues() {
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("plan"), .plan)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("build"), .build)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("edit"), .edit)
        XCTAssertEqual(AgentProfileSettings.parsePermissionMode("yolo"), .yolo)
        XCTAssertNil(AgentProfileSettings.parsePermissionMode("nope"))
        XCTAssertNil(AgentProfileSettings.parsePermissionMode("   "))
    }

    func testAllowedToolsStillParsedWithProfileFields() {
        let md = """
        ---
        name: gated
        description: d
        allowed-tools: read_file, grep_code
        model: cheap-explore
        maxTurns: 8
        background: false
        ---
        Scout only.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.tools, ["read_file", "grep_code"])
        XCTAssertEqual(def?.model, "cheap-explore")
        XCTAssertEqual(def?.maxTurns, 8)
        XCTAssertEqual(def?.background, false)
        XCTAssertEqual(def?.systemPrompt, "Scout only.")
    }

    func testSnakeAndKebabAliases() {
        let md = """
        ---
        name: aliases
        description: d
        thought-level: medium
        max_turns: 20
        permission-mode: plan
        ---
        Plan first.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertEqual(def?.thoughtLevel, "medium")
        XCTAssertEqual(def?.maxTurns, 20)
        XCTAssertEqual(def?.permissionMode, .plan)
    }

    func testInvalidMaxTurnsAndBackgroundIgnored() {
        let md = """
        ---
        name: junk
        description: d
        maxTurns: 0
        background: maybe
        ---
        Still a prompt.
        """
        let def = AgentDefinitionDiscovery.parse(markdown: md)
        XCTAssertNil(def?.maxTurns)
        XCTAssertNil(def?.background)
        XCTAssertEqual(def?.systemPrompt, "Still a prompt.")
    }

    func testDiscoveredDefinitionInitDefaultsProfileFields() {
        let def = DiscoveredAgentDefinition(
            name: "x", description: "", systemPrompt: "hi", tools: ["read_file"])
        XCTAssertNil(def.model)
        XCTAssertNil(def.thoughtLevel)
        XCTAssertNil(def.permissionMode)
        XCTAssertNil(def.maxTurns)
        XCTAssertNil(def.background)
        XCTAssertTrue(def.profileSettings.isEmpty)
    }

    func testAgentDefinitionStoresProfileSettings() {
        let settings = AgentProfileSettings(
            model: "local-qwen",
            thoughtLevel: "high",
            permissionMode: .build,
            maxTurns: 9,
            background: true)
        XCTAssertFalse(settings.isEmpty)
        XCTAssertEqual(settings.permissionMode, .build)
    }

    // MARK: - Mailbox

    func testMailboxSendAndDrain() async {
        let mailbox = AgentMailbox()
        let id = AgentMailbox.makeAgentId()
        let sent = await mailbox.send(
            to: id, summary: "assign task one", message: "start on task 1", from: "parent")
        XCTAssertFalse(sent.resumeRequested)
        XCTAssertEqual(sent.message.to, id)
        XCTAssertEqual(sent.message.summary, "assign task one")
        XCTAssertEqual(sent.message.from, "parent")

        let pending = await mailbox.peek(agentId: id)
        XCTAssertEqual(pending.count, 1)
        let drained = await mailbox.drain(agentId: id)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].message, "start on task 1")
        let again = await mailbox.drain(agentId: id)
        XCTAssertTrue(again.isEmpty)
    }

    func testMailboxResumeRequestedWhenCompleted() async {
        let mailbox = AgentMailbox()
        let id = AgentMailbox.makeAgentId()
        await mailbox.markCompleted(id)
        let completedBefore = await mailbox.isCompleted(agentId: id)
        let resumeBefore = await mailbox.resumeRequested(agentId: id)
        XCTAssertTrue(completedBefore)
        XCTAssertFalse(resumeBefore)

        let sent = await mailbox.send(to: id, summary: "continue work", message: "please resume")
        XCTAssertTrue(sent.resumeRequested)
        let resumeAfterSend = await mailbox.resumeRequested(agentId: id)
        XCTAssertTrue(resumeAfterSend)

        let msgs = await mailbox.drain(agentId: id)
        XCTAssertEqual(msgs.count, 1)
        let resumeAfterDrain = await mailbox.resumeRequested(agentId: id)
        XCTAssertTrue(resumeAfterDrain, "drain must not clear resumeRequested")
        let consumed = await mailbox.consumeResumeRequest(agentId: id)
        XCTAssertTrue(consumed)
        let resumeAfterConsume = await mailbox.resumeRequested(agentId: id)
        XCTAssertFalse(resumeAfterConsume)
    }

    func testMailboxNormalizesBareUUID() async {
        let mailbox = AgentMailbox()
        let uuid = UUID()
        _ = await mailbox.send(
            to: uuid.uuidString, summary: "ping", message: "hello")
        let drained = await mailbox.drain(agentId: AgentMailbox.makeAgentId(uuid))
        XCTAssertEqual(drained.count, 1)
    }

    func testMailboxOptionalDiskRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = AgentMailbox.makeAgentId()
        let first = AgentMailbox(diskRoot: dir)
        await first.markCompleted(id)
        _ = await first.send(to: id, summary: "disk ping", message: "persisted body")

        let second = AgentMailbox(diskRoot: dir)
        let diskCompleted = await second.isCompleted(agentId: id)
        let diskResume = await second.resumeRequested(agentId: id)
        XCTAssertTrue(diskCompleted)
        XCTAssertTrue(diskResume)
        let msgs = await second.drain(agentId: id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].summary, "disk ping")
        XCTAssertEqual(msgs[0].message, "persisted body")
    }

    // MARK: - send_message tool

    func testSendMessageToolWritesMailbox() async throws {
        let id = AgentMailbox.makeAgentId()
        let tool = SendMessageTool()
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID())
        let result = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "to": id,
                "summary": "assign task one",
                "message": "start on task #1",
            ]),
            context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains(id))
        XCTAssertTrue(result.content.contains("queued"))
        XCTAssertNil(result.extras[AgentMailbox.extrasResumeKey])

        let msgs = await AgentMailbox.shared.drain(agentId: id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].summary, "assign task one")
        XCTAssertEqual(msgs[0].message, "start on task #1")
    }

    func testSendMessageToolResumeExtraWhenCompleted() async throws {
        let id = AgentMailbox.makeAgentId()
        await AgentMailbox.shared.markCompleted(id)
        let tool = SendMessageTool()
        let result = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "to": id,
                "summary": "resume review",
                "message": "continue from the last file",
            ]),
            context: ToolContext(projectRoot: nil, conversationID: UUID()))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.extras[AgentMailbox.extrasResumeKey], "true")
        XCTAssertTrue(result.content.contains("resumed_background"))
        let resumeFlag = await AgentMailbox.shared.resumeRequested(agentId: id)
        XCTAssertTrue(resumeFlag)
    }

    func testSendMessageToolValidatesRequiredFields() async throws {
        let tool = SendMessageTool()
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID())
        let missingTo = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "summary": "hi", "message": "body",
            ]),
            context: ctx)
        XCTAssertTrue(missingTo.isError)
        let missingSummary = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "to": AgentMailbox.makeAgentId(), "message": "body",
            ]),
            context: ctx)
        XCTAssertTrue(missingSummary.isError)
        let missingMessage = try await tool.execute(
            arguments: ToolArguments(dictionary: [
                "to": AgentMailbox.makeAgentId(), "summary": "hi there",
            ]),
            context: ctx)
        XCTAssertTrue(missingMessage.isError)
        let leftover = await AgentMailbox.shared.drain(agentId: AgentMailbox.makeAgentId())
        XCTAssertTrue(leftover.isEmpty)
    }

    func testSendMessageSchemaMatchesZCodeShape() {
        XCTAssertEqual(SendMessageTool.name, "send_message")
        XCTAssertEqual(SendMessageTool.category, .agent)
        XCTAssertEqual(SendMessageTool.permission, .executes)
        if case .core = SendMessageTool.availability { } else {
            XCTFail("send_message must be core")
        }
        let keys = Set(SendMessageTool.schema.parameters.properties.keys)
        XCTAssertEqual(keys, ["to", "summary", "message"])
        XCTAssertEqual(Set(SendMessageTool.schema.parameters.required), ["to", "summary", "message"])
        XCTAssertTrue(SendMessageTool.schema.description.contains("agent_<uuid>"))
    }
}

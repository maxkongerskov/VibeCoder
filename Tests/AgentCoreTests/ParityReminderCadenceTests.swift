//
//  ParityReminderCadenceTests.swift
//  ZCode-parity mid-turn reminder cadence (plan mode / todo / post-compact).
//

import XCTest
@testable import AgentCore

final class ParityReminderCadenceTests: XCTestCase {

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    private func assistant(
        _ text: String,
        calls: [ToolCallInvocation] = []
    ) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: calls)
    }

    private func call(_ name: String, id: String = "c1") -> ToolCallInvocation {
        ToolCallInvocation(id: id, name: name, arguments: "{}")
    }

    /// `n` real user turns, each followed by an assistant reply.
    private func transcript(humanTurns n: Int) -> [ChatMessage] {
        guard n > 0 else { return [] }
        var messages: [ChatMessage] = []
        for i in 1...n {
            messages.append(user("turn \(i)"))
            messages.append(assistant("ok \(i)"))
        }
        return messages
    }

    // MARK: - Human-turn counting

    func testIsSystemReminderMatchesWireOnly() {
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.buildGuard(succeeded: true)))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.autoVerify(path: "App.swift", tail: "let x = 1")))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.memoryFirstTurn("- note")))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.interjection("steer left")))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.planModeCadence))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.todoPlanNudge))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            SystemReminder.postCompactRefresh("# Available skills\n- `verify`")))
        XCTAssertTrue(SystemReminder.isSystemReminder(
            "[system] Background job update\njob 1 done"))
        XCTAssertFalse(SystemReminder.isSystemReminder("Please edit App.swift"))
        XCTAssertEqual(
            SystemReminder.isSystemReminder(SystemReminder.buildGuard(succeeded: false)),
            SystemReminder.isWireOnly(SystemReminder.buildGuard(succeeded: false)))
    }

    func testIsHumanTurnSkipsHarnessReminders() {
        XCTAssertTrue(ChatLoop.isHumanTurn(user("ship the feature")))
        XCTAssertFalse(ChatLoop.isHumanTurn(assistant("working")))
        XCTAssertFalse(ChatLoop.isHumanTurn(user(SystemReminder.buildGuard(succeeded: true))))
        XCTAssertFalse(ChatLoop.isHumanTurn(user(SystemReminder.autoVerify(
            path: "Foo.swift", tail: "print(1)"))))
        XCTAssertFalse(ChatLoop.isHumanTurn(ChatMessage(
            role: .tool, content: "ok", toolCallID: "t1")))
    }

    func testHumanTurnCountIgnoresSystemRemindersAndNonUserRoles() {
        let messages: [ChatMessage] = [
            user("one"),
            assistant("ack"),
            user(SystemReminder.buildGuard(succeeded: true)),
            user(SystemReminder.interjection("ignore me as a turn? no — this is a reminder")),
            user("two"),
            ChatMessage(role: .tool, content: "tool", toolCallID: "t1"),
            user("three"),
        ]
        XCTAssertEqual(ChatLoop.humanTurnCount(messages: messages), 3)
    }

    // MARK: - Plan-mode cadence (every 5 human turns)

    func testPlanModeReminderOnlyOnEveryFifthHumanTurn() {
        for n in 0...12 {
            let should = ChatLoop.shouldRemindPlanMode(
                messages: transcript(humanTurns: n),
                executionMode: .plan)
            XCTAssertEqual(should, n > 0 && n % 5 == 0, "human turns \(n)")
        }
    }

    func testPlanModeReminderOffWhenNotInPlanMode() {
        let five = transcript(humanTurns: 5)
        XCTAssertFalse(ChatLoop.shouldRemindPlanMode(messages: five, executionMode: .build))
        XCTAssertFalse(ChatLoop.shouldRemindPlanMode(messages: five, executionMode: .edit))
        XCTAssertFalse(ChatLoop.shouldRemindPlanMode(messages: five, executionMode: .yolo))
        XCTAssertFalse(ChatLoop.shouldRemindPlanMode(messages: five, executionMode: nil))
    }

    func testPlanModeReminderIgnoresWireOnlyRowsTowardInterval() {
        var messages = transcript(humanTurns: 4)
        messages.append(user(SystemReminder.buildGuard(succeeded: true)))
        messages.append(user(SystemReminder.autoVerify(path: "A.swift", tail: "x")))
        XCTAssertFalse(ChatLoop.shouldRemindPlanMode(messages: messages, executionMode: .plan))
        messages.append(user("fifth real turn"))
        XCTAssertTrue(ChatLoop.shouldRemindPlanMode(messages: messages, executionMode: .plan))
    }

    // MARK: - Todo / plan nudge (after 8 human turns)

    func testTodoNudgeFiresAtThresholdWithoutPlanTools() {
        XCTAssertFalse(ChatLoop.shouldNudgeTodoPlan(messages: transcript(humanTurns: 7)))
        XCTAssertTrue(ChatLoop.shouldNudgeTodoPlan(messages: transcript(humanTurns: 8)))
        XCTAssertFalse(
            ChatLoop.shouldNudgeTodoPlan(messages: transcript(humanTurns: 9)),
            "must not re-fire every turn after the threshold")
    }

    func testTodoNudgeRepeatsOnIntervalNotEveryTurn() {
        for n in 8...24 {
            let should = ChatLoop.shouldNudgeTodoPlan(messages: transcript(humanTurns: n))
            let expected = (n - 8) % 8 == 0
            XCTAssertEqual(should, expected, "human turns \(n)")
        }
    }

    func testTodoNudgeSuppressedAfterCreatePlan() {
        var messages = transcript(humanTurns: 8)
        messages.append(assistant("", calls: [call("create_plan")]))
        XCTAssertFalse(ChatLoop.shouldNudgeTodoPlan(messages: messages))
    }

    func testTodoNudgeSuppressedAfterUpdateTodo() {
        var messages = transcript(humanTurns: 8)
        messages.append(assistant("", calls: [call("update_todo", id: "u1")]))
        XCTAssertFalse(ChatLoop.shouldNudgeTodoPlan(messages: messages))
    }

    func testTodoNudgeStillFiresIfOnlyRevisePlanWasCalled() {
        var messages = transcript(humanTurns: 8)
        messages.append(assistant("", calls: [call("revise_plan")]))
        XCTAssertTrue(
            ChatLoop.shouldNudgeTodoPlan(messages: messages),
            "acceptance names create_plan / update_todo only")
    }

    func testTodoNudgeSuppressedWhenPlanStoreHasLivePlan() {
        let messages = transcript(humanTurns: 8)
        XCTAssertTrue(ChatLoop.shouldNudgeTodoPlan(messages: messages))
        XCTAssertFalse(
            ChatLoop.shouldNudgeTodoPlan(messages: messages, hasLivePlan: true),
            "PlanStore plan must suppress after compact drops tool calls")
    }

    func testCadenceRemindersOmitsTodoWhenHasLivePlan() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 8),
            executionMode: .edit,
            didPersistCompact: false,
            emitTurnCadence: true,
            hasLivePlan: true)
        XCTAssertTrue(nudges.isEmpty)
    }

    func testDefaultTodoThresholdIsEight() {
        XCTAssertEqual(ChatLoop.todoNudgeHumanTurns, 8)
        XCTAssertEqual(ChatLoop.todoNudgeRepeatHumanTurns, 8)
        XCTAssertEqual(ChatLoop.planModeReminderHumanTurns, 5)
    }

    // MARK: - Post-compaction refresh body

    func testPostCompactRefreshBodyJoinsExistingFormattedBlocks() {
        let skills = SkillDiscovery.indexBlock(skills: [
            DiscoveredSkill(
                name: "verify",
                description: "Re-read, diff, and build after edits",
                body: "")
        ])
        let instructions = """
        # Project instructions

        Always run tests.
        """
        let body = ChatLoop.postCompactRefreshBody(
            skillIndex: skills,
            projectInstructions: instructions)
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.contains("# Available skills") == true)
        XCTAssertTrue(body?.contains("`verify`") == true)
        XCTAssertTrue(body?.contains("# Project instructions") == true)
        XCTAssertTrue(body?.contains("Always run tests.") == true)
    }

    func testPostCompactRefreshBodyNilWhenBothEmpty() {
        XCTAssertNil(ChatLoop.postCompactRefreshBody(skillIndex: nil, projectInstructions: nil))
        XCTAssertNil(ChatLoop.postCompactRefreshBody(skillIndex: "  \n", projectInstructions: ""))
    }

    func testPostCompactRefreshUsesSystemReminderDialect() {
        let wrapped = SystemReminder.postCompactRefresh("# Available skills\n- `verify`")
        XCTAssertTrue(wrapped.hasPrefix("# System reminder — post-compaction"))
        XCTAssertTrue(SystemReminder.isSystemReminder(wrapped))
        XCTAssertTrue(wrapped.contains("# Available skills"))
    }

    // MARK: - cadenceReminders aggregator

    func testCadenceRemindersPlanModeOnFifthTurn() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 5),
            executionMode: .plan,
            didPersistCompact: false,
            emitTurnCadence: true)
        XCTAssertEqual(nudges, [SystemReminder.planModeCadence])
    }

    func testCadenceRemindersTodoOnEighthTurnOutsidePlan() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 8),
            executionMode: .edit,
            didPersistCompact: false,
            emitTurnCadence: true)
        XCTAssertEqual(nudges, [SystemReminder.todoPlanNudge])
    }

    func testCadenceRemindersCanEmitPlanAndTodoTogether() {
        // LCM of plan interval 5 and todo 8/8 grid is 40.
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 40),
            executionMode: .plan,
            didPersistCompact: false,
            emitTurnCadence: true)
        XCTAssertEqual(nudges, [
            SystemReminder.planModeCadence,
            SystemReminder.todoPlanNudge
        ])
    }

    func testCadenceRemindersTodoSkippedBetweenRepeatSlots() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 10),
            executionMode: .plan,
            didPersistCompact: false,
            emitTurnCadence: true)
        XCTAssertEqual(nudges, [SystemReminder.planModeCadence])
    }

    func testCadenceRemindersSkipsTurnCadenceWhenFlagFalse() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 10),
            executionMode: .plan,
            didPersistCompact: false,
            emitTurnCadence: false)
        XCTAssertTrue(nudges.isEmpty)
    }

    func testCadenceRemindersPostCompactUsesOverridesNotDisk() {
        let skillBlock = SkillDiscovery.indexBlock(skills: [
            DiscoveredSkill(name: "ship", description: "Ship checklist", body: "")
        ])
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 1),
            executionMode: .edit,
            didPersistCompact: true,
            emitTurnCadence: false,
            skillIndex: skillBlock,
            projectInstructions: "# Project instructions\n\nUse tabs.")
        XCTAssertEqual(nudges.count, 1)
        let body = nudges[0]
        XCTAssertTrue(body.hasPrefix("# System reminder — post-compaction"))
        XCTAssertTrue(body.contains("`ship`"))
        XCTAssertTrue(body.contains("# Project instructions"))
        XCTAssertTrue(body.contains("Use tabs."))
    }

    func testCadenceRemindersPostCompactSkippedWhenNothingToRefresh() {
        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 1),
            executionMode: .edit,
            didPersistCompact: true,
            emitTurnCadence: false,
            skillIndex: "",
            projectInstructions: "")
        XCTAssertTrue(nudges.isEmpty)
    }

    func testCadenceRemindersReloadsSkillIndexFromDiskAfterCompact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillDir = root
            .appendingPathComponent(".vibecoder", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("cadence-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: cadence-demo
        description: Cadence refresh fixture
        ---
        # Cadence demo
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let agentos = root.appendingPathComponent(".agentos", isDirectory: true)
        try FileManager.default.createDirectory(at: agentos, withIntermediateDirectories: true)
        try "Prefer focused diffs."
            .write(to: agentos.appendingPathComponent("instructions.md"),
                   atomically: true, encoding: .utf8)

        let nudges = ChatLoop.cadenceReminders(
            messages: transcript(humanTurns: 1),
            executionMode: .edit,
            didPersistCompact: true,
            emitTurnCadence: false,
            projectRoot: root)
        XCTAssertEqual(nudges.count, 1)
        XCTAssertTrue(nudges[0].contains("# Available skills"))
        XCTAssertTrue(nudges[0].contains("`cadence-demo`"))
        XCTAssertTrue(nudges[0].contains("# Project instructions"))
        XCTAssertTrue(nudges[0].contains("Prefer focused diffs."))
    }

    // MARK: - AgentLoop wiring

    private var loopModel: ModelDescriptor {
        ModelDescriptor(id: "cadence-loop", displayName: "Cadence Loop", backend: .lmStudio)
    }

    private func loopConfig(
        executionMode: ExecutionMode? = nil,
        rawMode: Bool = false
    ) -> AgentLoop.Configuration {
        .init(
            maxIterations: 6,
            verifyEdits: false,
            memoryEnabled: false,
            dreamEnabled: false,
            rawMode: rawMode,
            executionMode: executionMode)
    }

    private func systemContent(_ request: ChatRequest) -> String {
        request.messages.first { $0.role == .system }?.content ?? ""
    }

    func testAgentLoopInjectsPlanCadenceOnFifthHumanTurn() async throws {
        let backend = CadenceScriptedBackend(turns: [
            .chunks([.contentDelta("ok"), .done(finishReason: "stop")]),
        ])
        var convo = Conversation()
        convo.messages = transcript(humanTurns: 4)
        let loop = AgentLoop(backend: backend, model: loopModel, config: loopConfig(executionMode: .plan))
        _ = try await loop.run(userMessage: "fifth", conversation: convo) { _ in }
        let sys = systemContent(try XCTUnwrap(backend.capturedRequests.first))
        XCTAssertTrue(sys.contains("# System reminder — plan mode"), sys)
    }

    func testAgentLoopInjectsTodoNudgeOnEighthTurnNotNinth() async throws {
        let eighth = CadenceScriptedBackend(turns: [
            .chunks([.contentDelta("ok"), .done(finishReason: "stop")]),
        ])
        var convo8 = Conversation()
        convo8.messages = transcript(humanTurns: 7)
        let loop8 = AgentLoop(backend: eighth, model: loopModel, config: loopConfig(executionMode: .edit))
        _ = try await loop8.run(userMessage: "eighth", conversation: convo8) { _ in }
        let sys8 = systemContent(try XCTUnwrap(eighth.capturedRequests.first))
        XCTAssertTrue(sys8.contains("# System reminder — plan / todos"), sys8)

        let ninth = CadenceScriptedBackend(turns: [
            .chunks([.contentDelta("ok"), .done(finishReason: "stop")]),
        ])
        var convo9 = Conversation()
        convo9.messages = transcript(humanTurns: 8)
        let loop9 = AgentLoop(backend: ninth, model: loopModel, config: loopConfig(executionMode: .edit))
        _ = try await loop9.run(userMessage: "ninth", conversation: convo9) { _ in }
        let sys9 = systemContent(try XCTUnwrap(ninth.capturedRequests.first))
        XCTAssertFalse(sys9.contains("# System reminder — plan / todos"), sys9)
    }

    func testAgentLoopSkipsTurnCadenceOnSecondIteration() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let backend = CadenceScriptedBackend(turns: [
            .chunks([
                .toolCallDelta(
                    index: 0, id: "c1", name: "list_directory",
                    argumentsAppend: #"{"path":"."}"#),
                .done(finishReason: "tool_calls"),
            ]),
            .chunks([.contentDelta("done"), .done(finishReason: "stop")]),
        ])
        var convo = Conversation()
        convo.messages = transcript(humanTurns: 4)
        let loop = AgentLoop(backend: backend, model: loopModel, config: loopConfig(executionMode: .plan))
        _ = try await loop.run(userMessage: "fifth", conversation: convo) { _ in }
        XCTAssertEqual(backend.capturedRequests.count, 2)
        let first = systemContent(backend.capturedRequests[0])
        let second = systemContent(backend.capturedRequests[1])
        XCTAssertTrue(first.contains("# System reminder — plan mode"), first)
        XCTAssertFalse(second.contains("# System reminder — plan mode"), second)
    }

    func testAgentLoopSuppressesTodoNudgeWhenPlanStoreHasLivePlan() async throws {
        var convo = Conversation()
        let live = Plan(
            goal: "Ship the feature",
            todos: [Todo(id: "t1", text: "Write the patch", status: .pending)])
        await PlanStore.shared.setPlan(live, for: convo.id)
        let backend = CadenceScriptedBackend(turns: [
            .chunks([.contentDelta("ok"), .done(finishReason: "stop")]),
        ])
        // Compact-shaped transcript: 8 human turns, no create_plan / update_todo.
        convo.messages = transcript(humanTurns: 7)
        let loop = AgentLoop(backend: backend, model: loopModel, config: loopConfig(executionMode: .edit))
        do {
            _ = try await loop.run(userMessage: "eighth", conversation: convo) { _ in }
            let sys = systemContent(try XCTUnwrap(backend.capturedRequests.first))
            XCTAssertFalse(
                sys.contains("# System reminder — plan / todos"),
                "live PlanStore plan must suppress todo nag: \(sys)")
        } catch {
            await PlanStore.shared.clear(for: convo.id)
            throw error
        }
        await PlanStore.shared.clear(for: convo.id)
    }

    func testAgentLoopRawModeOmitsCadence() async throws {
        let backend = CadenceScriptedBackend(turns: [
            .chunks([.contentDelta("hi"), .done(finishReason: "stop")]),
        ])
        var convo = Conversation()
        convo.messages = transcript(humanTurns: 4)
        let loop = AgentLoop(backend: backend, model: loopModel, config: loopConfig(
            executionMode: .plan, rawMode: true))
        _ = try await loop.run(userMessage: "fifth", conversation: convo) { _ in }
        let sys = systemContent(try XCTUnwrap(backend.capturedRequests.first))
        XCTAssertFalse(sys.contains("# System reminder — plan mode"), sys)
        XCTAssertTrue(sys.isEmpty, "chat mode sends no system prompt")
    }

    func testAgentLoopPostCompactRefreshOnlyWhenHistoryShrank() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDir = root
            .appendingPathComponent(".vibecoder/skills/cadence-loop", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: cadence-loop
        description: Loop wiring fixture
        ---
        # Fixture
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let overflow = BackendError.http(status: 400, body: "context_length_exceeded")
        let finish: [ChatChunk] = [.contentDelta("ok"), .done(finishReason: "stop")]

        let noShrink = CadenceScriptedBackend(turns: [
            .failure(overflow),
            .chunks(finish),
        ])
        var tiny = Conversation(projectRoot: root)
        tiny.messages = [user("only")]
        let tinyLoop = AgentLoop(backend: noShrink, model: loopModel, config: loopConfig())
        _ = try await tinyLoop.run(userMessage: "go", conversation: tiny) { _ in }
        XCTAssertEqual(noShrink.capturedRequests.count, 2)
        let retryTiny = systemContent(noShrink.capturedRequests[1])
        XCTAssertFalse(
            retryTiny.contains("# System reminder — post-compaction"),
            "no-op compact must not refresh: \(retryTiny)")

        let shrink = CadenceScriptedBackend(turns: [
            .failure(overflow),
            .chunks(finish),
        ])
        var fat = Conversation(projectRoot: root)
        fat.messages = transcript(humanTurns: 12)
        let fatLoop = AgentLoop(backend: shrink, model: loopModel, config: loopConfig())
        _ = try await fatLoop.run(userMessage: "continue", conversation: fat) { _ in }
        XCTAssertEqual(shrink.capturedRequests.count, 2)
        let firstFat = systemContent(shrink.capturedRequests[0])
        let retryFat = systemContent(shrink.capturedRequests[1])
        XCTAssertFalse(firstFat.contains("# System reminder — post-compaction"), firstFat)
        XCTAssertTrue(
            retryFat.contains("# System reminder — post-compaction"),
            retryFat)
        XCTAssertTrue(retryFat.contains("`cadence-loop`"), retryFat)
    }

    func testAgentLoopSeedsSessionReadPathsFromConversation() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-rbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Seeded.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)

        var convo = Conversation(projectRoot: root)
        convo.sessionReadPaths = [file.path]
        await SessionReadTracker.shared.clear(conversationID: convo.id)
        defer {
            Task { await SessionReadTracker.shared.clear(conversationID: convo.id) }
        }

        let edits = """
        <<<<<<< SEARCH
        let x = 1
        =======
        let x = 2
        >>>>>>> REPLACE
        """
        let args = String(
            data: try JSONSerialization.data(withJSONObject: [
                "path": file.path,
                "edits": edits,
            ]),
            encoding: .utf8
        ) ?? "{}"
        let backend = CadenceScriptedBackend(turns: [
            .chunks([
                .toolCallDelta(index: 0, id: "e1", name: "edit_file", argumentsAppend: args),
                .done(finishReason: "tool_calls"),
            ]),
            .chunks([.contentDelta("done"), .done(finishReason: "stop")]),
        ])
        let result = try await AgentLoop(
            backend: backend,
            model: loopModel,
            config: loopConfig(executionMode: .yolo)
        ).run(userMessage: "edit", conversation: convo) { _ in }
        await SessionReadTracker.shared.clear(conversationID: convo.id)

        let tool = try XCTUnwrap(result.messages.first { $0.role == .tool && $0.toolCallID == "e1" })
        XCTAssertFalse(
            tool.content.lowercased().contains("read-before-edit"),
            "persisted sessionReadPaths must seed ToolContext: \(tool.content)")
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("let x = 2"), written)
    }

    func testAgentLoopCopiesMemoryUpdateExtrasOntoNextIterationNudges() async throws {
        await ToolRegistry.shared.registerBuiltins()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-memupd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let note = "Isolate agent edits in a git worktree for memory_update hook."
        let args = String(
            data: try JSONSerialization.data(withJSONObject: [
                "action": "remember",
                "text": note,
            ]),
            encoding: .utf8
        ) ?? "{}"
        let backend = CadenceScriptedBackend(turns: [
            .chunks([
                .toolCallDelta(index: 0, id: "m1", name: "memory", argumentsAppend: args),
                .done(finishReason: "tool_calls"),
            ]),
            .chunks([.contentDelta("acked"), .done(finishReason: "stop")]),
        ])
        let convo = Conversation(projectRoot: root)
        let result = try await AgentLoop(
            backend: backend,
            model: loopModel,
            config: loopConfig(executionMode: .edit)
        ).run(userMessage: "remember that", conversation: convo) { _ in }

        let tool = try XCTUnwrap(result.messages.first { $0.role == .tool && $0.toolCallID == "m1" })
        XCTAssertFalse(tool.content.lowercased().contains("error"), tool.content)
        XCTAssertGreaterThanOrEqual(backend.capturedRequests.count, 2)
        let first = systemContent(backend.capturedRequests[0])
        let second = systemContent(backend.capturedRequests[1])
        XCTAssertFalse(first.contains(MemoryUpdateReminder.heading), first)
        XCTAssertTrue(
            second.contains(MemoryUpdateReminder.heading),
            "next iteration must see memory_update in system-prompt tail: \(second)")
        XCTAssertTrue(second.contains("Action: remember"), second)
        XCTAssertTrue(second.contains("worktree"), second)
    }
}

// MARK: - Scripted backend

private enum CadenceStream: Sendable {
    case chunks([ChatChunk])
    case failure(Error)
}

private final class CadenceScriptedBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .lmStudio
    private let turns: [CadenceStream]
    private var turnIndex = 0
    private let lock = NSLock()
    private(set) var streamAttempts = 0
    private var _captured: [ChatRequest] = []

    init(turns: [CadenceStream]) { self.turns = turns }

    var capturedRequests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func listModels() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: "cadence-loop", displayName: "Cadence Loop", backend: .lmStudio)]
    }

    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        streamAttempts += 1
        _captured.append(request)
        let idx = turnIndex
        turnIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard idx < turns.count else {
                continuation.yield(.contentDelta("done"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
                return
            }
            switch turns[idx] {
            case .chunks(let chunks):
                for c in chunks { continuation.yield(c) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel(streamID: UUID) async {}
}

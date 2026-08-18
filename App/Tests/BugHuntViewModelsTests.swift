//
//  BugHuntViewModelsTests.swift
//
//  Runtime proofs for ViewModel bugs. Each test asserts correct behavior;
//  a failure is the confirmation.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class BugHuntViewModelsTests: XCTestCase {

    override func tearDown() {
        ChatPromptHooks.resetTestHandlers()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeApp(models: [ModelDescriptor] = [],
                         selected: String? = nil,
                         backend: (any InferenceBackend)? = nil) -> AppViewModel {
        let app = AppViewModel()
        var settings = AppSettings()
        settings.backend = .omlx
        settings.xcodeMCPEnabled = false
        app.settings = settings
        app.availableModels = models
        app.selectedModelID = selected
        app.testingBackend = backend
        return app
    }

    private func sampleModel() -> ModelDescriptor {
        ModelDescriptor(id: "bughunt-model", displayName: "BugHunt",
                        backend: .omlx, contextLength: 8_192)
    }

    private func waitUntil(_ pred: @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pred() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: 0 — P0-4 first-run permission default

    func testConnectionFieldTypingDoesNotFireSettingsSideEffects() {
        let app = makeApp()
        let baseline = app.settingsSideEffectCount
        for i in 0..<20 {
            app.persistSettings { $0.lmStudioHost = "127.0.0.\(i % 10)" }
            app.persistSettings { $0.lmStudioPort = 1234 + i }
            app.persistSettings { $0.lmStudioAPIKey = "k\(i)" }
        }
        XCTAssertEqual(
            app.settingsSideEffectCount, baseline,
            "host/port/key typing must not invalidate MCP or bounce Local API")
        XCTAssertEqual(app.settings.lmStudioHost, "127.0.0.9")
        app.applySettingsSideEffects()
        XCTAssertEqual(
            app.settingsSideEffectCount, baseline + 1,
            "Test / commit applies side effects once")
    }

    func testDefaultExecutionModeIsAskNotFull() {
        let app = AppViewModel()
        XCTAssertEqual(
            app.executionMode, .build,
            "fresh AppViewModel must default to Ask, not Full/YOLO")
        XCTAssertTrue(
            app.safeModeOn,
            "Ask default must arm Safe Mode (executionMode.enablesSafeMode)")
        XCTAssertNotEqual(app.executionMode, .yolo)
    }

    // MARK: 0b — P0-3 sidebar save merge keeps live transcript

    func testSaveMergeKeepsLiveMessagesWhenListRowIsStale() {
        var listRow = Conversation(
            title: "old",
            messages: [ChatMessage(role: .user, content: "start")])
        var live = listRow
        live.messages.append(ChatMessage(role: .assistant, content: "working…"))
        listRow.title = "renamed"
        live.title = "renamed"
        let snap = ConversationSaveMerge.snapshot(listRow: listRow, live: live)
        XCTAssertEqual(snap.title, "renamed")
        XCTAssertEqual(snap.messages.count, 2, "must persist the live VM transcript, not the stale list row")
        XCTAssertEqual(snap.messages.last?.content, "working…")
    }

    func testSaveMergeWithoutLiveVMUsesListRow() {
        let listRow = Conversation(title: "only-list")
        let snap = ConversationSaveMerge.snapshot(listRow: listRow, live: nil)
        XCTAssertEqual(snap.id, listRow.id)
        XCTAssertEqual(snap.title, "only-list")
    }

    func testRenamePersistsLiveTranscriptNotStaleListRow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-3-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConversationStore(directory: dir)
        let app = makeApp()
        app.conversationsCoordinator.conversationStore = store

        var convo = Conversation(title: "pre-turn")
        convo.messages = [ChatMessage(role: .user, content: "hello")]
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        vm.conversation.messages.append(
            ChatMessage(role: .assistant, content: "mid-turn reply"))

        app.renameConversation(id: convo.id, to: "after-rename")
        // persistMergedConversation writes in a Task — wait for disk.
        let deadline = Date().addingTimeInterval(2)
        var loaded: Conversation?
        while Date() < deadline {
            loaded = try await store.load(id: convo.id)
            if loaded?.title == "after-rename" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(loaded?.title, "after-rename")
        XCTAssertEqual(
            loaded?.messages.count, 2,
            "rename must not persist the pre-turn message array")
        XCTAssertEqual(loaded?.messages.last?.content, "mid-turn reply")
    }

    func testRefreshConversationsSurfacesUnloadableCount() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-list-unloadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConversationStore(directory: dir)
        let healthy = Conversation(title: "visible")
        try await store.save(healthy)
        try Data("{broken".utf8).write(
            to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        let app = makeApp()
        app.conversationsCoordinator.conversationStore = store
        await app.refreshConversations()

        XCTAssertEqual(app.conversations.map(\.id), [healthy.id])
        XCTAssertEqual(app.unloadableConversations.count, 1)
        XCTAssertEqual(
            app.unloadableConversations.first?.filename.hasSuffix(".json"),
            true)
    }

    // MARK: 1 — /loop interval-only uses the token as the prompt

    func testLoopIntervalOnlyDoesNotScheduleTokenAsPrompt() async {
        let app = makeApp()
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        let result = vm.handleSlashCommand("/loop 1h")
        guard case .handled(let message) = result else {
            return XCTFail("expected handled")
        }
        let text = message ?? ""
        // Best-effort cleanup if the buggy path persisted a "1h" task.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let store = ScheduledTaskStore()
        for task in await store.reload() where task.name == "1h" || task.shortPrompt == "1h" {
            await store.delete(task)
        }
        XCTAssertTrue(
            text.lowercased().contains("usage"),
            "/loop 1h must require a prompt; got: \(text)")
        XCTAssertFalse(
            text.contains("Scheduled"),
            "/loop 1h must not create a task named after the interval; got: \(text)")
    }

    func testLoopBareHIsNotAnHourlyInterval() {
        let app = makeApp()
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        let result = vm.handleSlashCommand("/loop h check the logs")
        guard case .handled(let message) = result else {
            return XCTFail("expected handled")
        }
        let text = message ?? ""
        // Bare "h" is not a duration; should schedule as a one-shot / usage,
        // not Hourly with prompt "check the logs".
        XCTAssertFalse(
            text.contains("Hourly"),
            "bare 'h' must not parse as hourly; got: \(text)")
    }

    // MARK: 2 — /loop drops the conversation project folder

    func testLoopCommandBindsConversationProjectFolder() async {
        let marker = "bughunt-loop-proj-\(UUID().uuidString.prefix(8))"
        let project = URL(fileURLWithPath: "/tmp/\(marker)")
        var convo = Conversation(title: "Loop project bind")
        convo.projectRoot = project
        let app = makeApp()
        let vm = ChatViewModel(conversation: convo, app: app)

        let result = vm.handleSlashCommand("/loop 1h \(marker) check deploy")
        guard case .handled(let message) = result else {
            return XCTFail("expected handled")
        }
        XCTAssertTrue((message ?? "").contains("Scheduled"), message ?? "")

        let deadline = Date().addingTimeInterval(3)
        var found: ScheduledTask?
        let store = ScheduledTaskStore()
        while Date() < deadline {
            let tasks = await store.reload()
            found = tasks.first { $0.shortPrompt.contains(marker) }
            if found != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let found else {
            return XCTFail("scheduled task was not persisted")
        }
        XCTAssertEqual(
            found.projectFolder,
            project.path,
            "/loop must copy the conversation project folder onto the task")
        await store.delete(found)
    }

    // MARK: 3 — first-send title uses injected chrome, not the user prompt

    func testSendTitleIgnoresSessionNotesPrefix() {
        let model = sampleModel()
        let backend = FinishingBackend(model: model)
        let app = makeApp(models: [model], selected: model.id, backend: backend)
        var convo = Conversation()
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        _ = vm.handleSlashCommand("/remember keep the auth token shape")
        let started = vm.send("please implement login")
        XCTAssertTrue(started)
        defer { vm.cancel() }
        let title = app.conversations.first(where: { $0.id == convo.id })?.title
            ?? vm.conversation.title
        XCTAssertFalse(
            title.contains("Session notes"),
            "auto-title must use the user prompt, not session-note chrome; got \(title)")
        XCTAssertTrue(
            title.localizedCaseInsensitiveContains("please implement login"),
            "auto-title should come from the prompt; got \(title)")
    }

    func testSendTitleIgnoresStickyPinHeader() {
        let model = sampleModel()
        let backend = FinishingBackend(model: model)
        let app = makeApp(models: [model], selected: model.id, backend: backend)
        var convo = Conversation()
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        vm.stickyContextPins = [
            StickyContextPin(kind: .file, path: "/tmp/Foo.swift", displayName: "Foo.swift")
        ]
        let started = vm.send("please implement login")
        XCTAssertTrue(started)
        defer { vm.cancel() }
        let title = app.conversations.first(where: { $0.id == convo.id })?.title
            ?? vm.conversation.title
        XCTAssertFalse(
            title.contains("Sticky context pins"),
            "auto-title must not be the pin header; got \(title)")
        XCTAssertTrue(
            title.localizedCaseInsensitiveContains("please implement login"),
            "auto-title should come from the prompt; got \(title)")
    }

    // MARK: 4 — @-mention treats emails as queries

    func testActiveMentionQueryIgnoresEmailAddresses() {
        let q = MentionSearchCoordinator.activeMentionQuery(
            in: "email me at user@example.com")
        XCTAssertNil(q, "email must not open mention search; got \(String(describing: q))")
        XCTAssertEqual(
            MentionSearchCoordinator.activeMentionQuery(in: "see @Foo"),
            "Foo")
    }

    // MARK: 5 — duplicate drops sticky pins

    func testDuplicateConversationKeepsStickyPins() {
        let pin = StickyContextPinRecord(
            kind: "file", path: "/tmp/Keep.swift", displayName: "Keep.swift")
        var source = Conversation(title: "Pinned context")
        source.stickyContextPins = [pin]
        let coord = ConversationCoordinator()
        coord.conversations = [source]
        coord.duplicateConversation(source.id)
        let copy = coord.conversations.first { $0.id != source.id }
        XCTAssertNotNil(copy)
        XCTAssertEqual(
            copy?.stickyContextPins.map(\.path),
            [pin.path],
            "fork/duplicate must keep sticky context pins")
    }

    // MARK: 6 — /clear leaves plan approval chrome

    func testClearRemovesPlanSnapshot() {
        let app = makeApp()
        app.executionMode = .plan
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        vm.planStoreSnapshot = Plan.make(goal: "Ship it", todoTexts: ["A", "B"])
        XCTAssertNotNil(vm.activePlan)
        XCTAssertTrue(vm.planNeedsApproval)
        _ = vm.handleSlashCommand("/clear")
        XCTAssertNil(
            vm.planStoreSnapshot,
            "/clear must drop the in-memory plan snapshot")
        XCTAssertFalse(
            vm.planNeedsApproval,
            "/clear must not leave Approve/Stay chrome on an empty chat")
    }

    // MARK: 7 — Approve switches mode even when send cannot start

    func testApprovePlanDoesNotLeaveAskModeWhenSendBails() {
        let app = makeApp(models: [], selected: nil)
        app.executionMode = .plan
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        vm.planStoreSnapshot = Plan.make(goal: "Ship it", todoTexts: ["A"])
        vm.approvePlanAndContinue()
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(
            app.executionMode, .plan,
            "Approve must not flip to Ask when the continue turn cannot start")
    }

    // MARK: 8 — scheduler creates an orphan chat when no model is selected

    func testScheduledTaskDoesNotCreateOrphanWhenNoModelSelected() async {
        let model = sampleModel()
        let app = makeApp(models: [model], selected: nil)
        XCTAssertNil(app.selectedModelID)
        XCTAssertFalse(app.availableModels.isEmpty)
        let before = app.conversations.count
        let id = await app.runScheduledTask(
            ScheduledTask(name: "bughunt-sched-orphan", shortPrompt: "ping"))
        if let id {
            app.deleteConversation(id)
        }
        XCTAssertNil(
            id,
            "scheduler must not insert a conversation when send will bail (no selected model)")
        XCTAssertEqual(app.conversations.count, before)
    }

    // MARK: 9 — finishRun stamps duration onto a previous turn

    func testFinishRunDoesNotOverwritePriorTurnWorkDuration() async {
        let model = sampleModel()
        let backend = ThrowingBackend(model: model)
        let app = makeApp(models: [model], selected: model.id, backend: backend)
        let prior = ChatMessage(
            role: .assistant, content: "previous answer", workDurationSeconds: 42)
        var convo = Conversation(messages: [
            ChatMessage(role: .user, content: "old"),
            prior
        ])
        convo.title = "Duration convo"
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        _ = vm.send("follow up that will error")
        await waitUntil({ !vm.isRunning }, timeout: 5)
        let stamped = vm.conversation.messages.first(where: { $0.id == prior.id })
        XCTAssertEqual(
            stamped?.workDurationSeconds, 42,
            "failed/cancelled turn must not rewrite the previous assistant's Worked-for duration")
    }

    // MARK: 10 — delete mid-turn resurrects the conversation

    func testDeleteDuringRunDoesNotResurrectConversation() async {
        let model = sampleModel()
        let backend = DelayedFinishingBackend(model: model, delayNanos: 400_000_000)
        let app = makeApp(models: [model], selected: model.id, backend: backend)
        var convo = Conversation(title: "bughunt-delete-resurrect")
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        XCTAssertTrue(vm.send("stay alive"))
        XCTAssertTrue(vm.isRunning)
        app.deleteConversation(convo.id)
        XCTAssertFalse(app.conversations.contains(where: { $0.id == convo.id }))
        await waitUntil({ !vm.isRunning }, timeout: 5)
        await app.refreshConversations()
        XCTAssertFalse(
            app.conversations.contains(where: { $0.id == convo.id }),
            "finishing a deleted conversation must not save it back onto disk")
        try? await ConversationStore.shared.delete(id: convo.id)
    }

    // MARK: 11 — worktree send ignores project-root UserPromptSubmit hooks

    func testSendHonorsProjectHooksWhenWorktreeIsActive() throws {
        let fm = FileManager.default
        let short = String(UUID().uuidString.prefix(8)).lowercased()
        let project = fm.temporaryDirectory.appendingPathComponent(
            "bughunt-hooks-\(short)", isDirectory: true)
        let hooks = project.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        HookDispatcher.setHooksHomeDirectoryOverride(project)
        defer {
            HookDispatcher.setHooksHomeDirectoryOverride(nil)
            try? fm.removeItem(at: project)
        }

        let script = hooks.appendingPathComponent("deny-prompt.sh")
        try "#!/bin/sh\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "deny-prompt.sh"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: hooks.appendingPathComponent("hooks.json"))

        var convo = Conversation()
        convo.projectRoot = project
        convo.worktreeBranch = "agentcore/\(short)"
        // Sibling worktree path has no hooks dir.
        XCTAssertNotNil(convo.worktreeRootURL)
        XCTAssertNotEqual(convo.worktreeRootURL?.path, project.path)

        let model = sampleModel()
        let backend = FinishingBackend(model: model)
        let app = makeApp(models: [model], selected: model.id, backend: backend)
        let vm = ChatViewModel(conversation: convo, app: app)
        let started = vm.send("this should be blocked by project hook")
        defer { vm.cancel() }
        XCTAssertFalse(
            started,
            "UserPromptSubmit hooks in the project root must still deny when a worktree is bound")
        XCTAssertFalse(vm.isRunning)
        XCTAssertTrue(
            vm.statusLine.lowercased().contains("block")
                || vm.statusLine.lowercased().contains("hook"),
            "expected hook deny status, got: \(vm.statusLine)")
    }

    // MARK: 12 — discardWorktree clears the branch after a failed discard

    func testDiscardWorktreeKeepsBranchWhenGitDiscardFails() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "bughunt-wt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Not a git repo → WorktreeService.discard throws gitFailed.
        var convo = Conversation()
        convo.projectRoot = root
        convo.worktreeBranch = "agentcore/deadbeef"

        let coord = ConversationCoordinator()
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord
        wt.discardWorktree(for: convo.id)

        let after = coord.conversations[0]
        XCTAssertNotNil(
            after.worktreeBranch,
            "failed discard must not drop worktreeBranch (orphans the worktree)")
        XCTAssertNotNil(wt.worktreeError)
    }

    // MARK: 13 — move down last pinned mutates dates without changing order

    func testMoveDownLastPinnedDoesNotRewriteDatesWhenOrderCannotChange() {
        let now = Date()
        var pinned = Conversation(title: "pinned")
        pinned.pinned = true
        pinned.updatedAt = now
        var unpinned = Conversation(title: "unpinned")
        unpinned.pinned = false
        unpinned.updatedAt = now.addingTimeInterval(-60)

        let coord = ConversationCoordinator()
        coord.conversations = [pinned, unpinned]
        let beforeOrder = coord.sidebarOrderedConversations().map(\.id)
        XCTAssertEqual(beforeOrder, [pinned.id, unpinned.id])

        coord.moveConversationDown(pinned.id)

        let afterOrder = coord.sidebarOrderedConversations().map(\.id)
        XCTAssertEqual(afterOrder, beforeOrder)
        let pinnedAfter = coord.conversations.first { $0.id == pinned.id }!
        XCTAssertEqual(
            pinnedAfter.updatedAt, now,
            "no-op Move down must not rewrite updatedAt")
    }
}

// MARK: - Test backends

@MainActor
private final class FinishingBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .omlx
    let model: ModelDescriptor
    init(model: ModelDescriptor) { self.model = model }
    func listModels() async throws -> [ModelDescriptor] { [model] }
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("ok"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
    func cancel(streamID: UUID) async {}
}

@MainActor
private final class ThrowingBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .omlx
    let model: ModelDescriptor
    init(model: ModelDescriptor) { self.model = model }
    func listModels() async throws -> [ModelDescriptor] { [model] }
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "bughunt", code: 1))
        }
    }
    func cancel(streamID: UUID) async {}
}

@MainActor
private final class DelayedFinishingBackend: InferenceBackend, @unchecked Sendable {
    let identifier: BackendIdentifier = .omlx
    let model: ModelDescriptor
    let delayNanos: UInt64
    init(model: ModelDescriptor, delayNanos: UInt64) {
        self.model = model
        self.delayNanos = delayNanos
    }
    func listModels() async throws -> [ModelDescriptor] { [model] }
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        let delay = delayNanos
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: delay)
                continuation.yield(.contentDelta("ok"))
                continuation.yield(.done(finishReason: "stop"))
                continuation.finish()
            }
        }
    }
    func cancel(streamID: UUID) async {}
}

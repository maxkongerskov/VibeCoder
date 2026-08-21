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

    func testEnsureFirstConversationWaitsForStoreThenSeedsOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = makeApp()
        app.conversationsCoordinator.conversationStore = ConversationStore(directory: dir)
        XCTAssertFalse(app.conversationsDidLoad)
        app.ensureFirstConversationIfNeeded()
        XCTAssertTrue(app.conversations.isEmpty, "must not seed before disk load")

        app.conversationsCoordinator.conversationsDidLoad = true
        app.ensureFirstConversationIfNeeded()
        XCTAssertEqual(app.conversations.count, 1, "first-run creates the connect-hero task")
        let id = app.conversations[0].id
        app.ensureFirstConversationIfNeeded()
        XCTAssertEqual(app.conversations.count, 1)
        XCTAssertEqual(app.conversations[0].id, id)
        XCTAssertEqual(app.selectedConversationID, id)
    }

    /// W3: binding a non-git folder must not be silent — worktreeError + statusLine.
    func testBindNonGitFolderSurfacesVisibleWorktreeReason() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = makeApp()
        let convo = Conversation()
        app.conversations = [convo]
        let vm = app.chatViewModel(for: convo.id)
        let project = Project(name: "plain", url: dir, createdAt: Date(), isExternal: true)
        app.moveConversationToProject(convo.id, project: project)

        XCTAssertEqual(app.conversations[0].projectRoot?.path, dir.path)
        XCTAssertNil(app.conversations[0].worktreeBranch)
        let reason = app.worktreeError
        XCTAssertNotNil(reason, "non-git bind must surface a visible reason")
        XCTAssertTrue(
            reason?.localizedCaseInsensitiveContains("git") == true,
            "got: \(reason ?? "nil")")
        XCTAssertEqual(vm.statusLine, reason)
        XCTAssertEqual(
            WorktreeBindCopy.notice(for: .skippedNotGit(path: dir.path)),
            reason)
    }

    /// Ada P2 leftover: coordinator create-save logs, does not throw to caller.
    func testCoordinatorCreatedConversationSaveFailureIsCaught() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-save-block-\(UUID().uuidString)")
        try Data([0x00]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = ConversationStore(
            directory: blocker.appendingPathComponent("conversations", isDirectory: true))
        let app = makeApp()
        app.conversationsCoordinator.host = app
        app.conversationsCoordinator.conversationStore = store
        let ok = await app.conversationsCoordinator.persistCreatedConversation(
            Conversation(title: "p2-coord"),
            context: "test")
        XCTAssertFalse(ok, "unwritable store must fail closed to the caller")
    }

    /// Ada P2: ChatViewModel persist logs and sets statusLine — no silent `try?`.
    func testChatViewModelSaveFailureSetsStatusLine() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cvm-save-block-\(UUID().uuidString)")
        try Data([0x00]).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = ConversationStore(
            directory: blocker.appendingPathComponent("conversations", isDirectory: true))
        let app = makeApp()
        let vm = ChatViewModel(conversation: Conversation(title: "p2-save"), app: app)
        XCTAssertTrue(vm.statusLine.isEmpty)
        await vm.persistConversationSnapshot(vm.conversation, store: store)
        XCTAssertEqual(vm.statusLine, "Couldn't save conversation.")
        XCTAssertFalse(vm.isRunning)
    }

    /// F2: draft + no model must not start a turn (no live server required).
    func testSendWithDraftAndNoModelDoesNotDispatchTurn() {
        let app = makeApp(models: [], selected: nil)
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        let accepted = vm.send("hello from first run")
        XCTAssertFalse(accepted)
        XCTAssertFalse(vm.isRunning, "no-model send must not flip isRunning")
        XCTAssertFalse(
            vm.conversation.messages.contains { $0.role == .user },
            "must not append an optimistic user bubble")
        XCTAssertTrue(
            vm.statusLine.lowercased().contains("model")
                || vm.statusLine.lowercased().contains("connection"),
            "honest status, got: \(vm.statusLine)")
    }

    /// F3: listing models / detecting a server is not selecting one.
    func testSendWithListedModelsButNoSelectionDoesNotDispatchTurn() {
        let listed = sampleModel()
        let other = ModelDescriptor(
            id: "other-model", displayName: "Other",
            backend: .omlx, contextLength: 8_192)
        let app = makeApp(models: [listed, other], selected: nil)
        XCTAssertNil(app.selectedModelID)
        let vm = ChatViewModel(conversation: Conversation(), app: app)
        let accepted = vm.send("draft with servers listed")
        XCTAssertFalse(accepted)
        XCTAssertFalse(vm.isRunning)
        XCTAssertTrue(
            vm.statusLine.lowercased().contains("select a model"),
            "must not auto-pick listed models, got: \(vm.statusLine)")
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

    /// W6: title-menu Edit main tree → `disableWorktree` (opt-out, disk stays).
    /// Isolate/enable clears opt-out. Does not grow ChatViewModel.
    func testEditMainTreeDisableWorktreeOptsOutWithoutDiscardingDisk() throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("w6-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "w6-edit-main")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        convo.worktreeOptOut = false

        let coord = ConversationCoordinator()
        coord.conversationStore = ConversationStore(directory: storeDir)
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        XCTAssertNotNil(isolated.worktreeBranch)
        XCTAssertFalse(isolated.worktreeOptOut)
        guard let diskPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree path")
        }
        XCTAssertTrue(
            WorktreeService.worktreeExists(at: diskPath),
            "enable must create the sibling checkout")
        defer {
            try? WorktreeService.discard(
                worktreePath: diskPath,
                branch: isolated.worktreeBranch ?? "",
                projectFolder: project.path)
        }

        // Edit main tree…
        wt.disableWorktree(for: convo.id)
        let opted = coord.conversations[0]
        XCTAssertNil(opted.worktreeBranch)
        XCTAssertTrue(opted.worktreeOptOut, "Edit main tree must persist opt-out")
        XCTAssertEqual(opted.projectRoot?.path, project.path)
        XCTAssertNil(wt.worktreeError)
        XCTAssertTrue(
            WorktreeService.worktreeExists(at: diskPath),
            "disable must not git-worktree-remove; Discard on the review sheet is the delete path")

        // Isolate / enable clears opt-out and reattaches (reuse).
        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let again = coord.conversations[0]
        XCTAssertFalse(again.worktreeOptOut, "Isolate must clear opt-out")
        XCTAssertNotNil(again.worktreeBranch)
        XCTAssertTrue(WorktreeService.worktreeExists(at: diskPath))
    }

    /// mergeWorktree must persist the post-ensure `worktreeBranch` (not leave nil on disk).
    func testMergeWorktreePersistsNewWorktreeBranch() async throws {
        let fm = FileManager.default
        let storeDir = fm.temporaryDirectory
            .appendingPathComponent("merge-persist-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: storeDir) }

        let project = try makeGitRepo(prefix: "merge-persist")
        defer { try? fm.removeItem(at: project) }

        var convo = Conversation()
        convo.projectRoot = project
        let store = ConversationStore(directory: storeDir)
        let coord = ConversationCoordinator()
        coord.conversationStore = store
        coord.conversations = [convo]
        let wt = WorktreeCoordinator()
        wt.conversations = coord

        wt.enableWorktree(for: convo.id)
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let isolated = coord.conversations[0]
        XCTAssertNotNil(isolated.worktreeBranch)
        guard let firstPath = isolated.worktreeRootURL?.path else {
            return XCTFail("enable must produce a worktree")
        }
        try "from-wt".write(
            to: URL(fileURLWithPath: firstPath).appendingPathComponent("from-wt.txt"),
            atomically: true, encoding: .utf8)

        wt.mergeWorktree(for: convo.id, commitMessage: "app persist re-isolate")
        XCTAssertNil(wt.worktreeError, wt.worktreeError ?? "")
        let after = coord.conversations[0]
        XCTAssertNotNil(after.worktreeBranch, "in-memory conversation must be re-isolated after merge")
        XCTAssertFalse(after.worktreeOptOut)
        let newPath = after.worktreeRootURL?.path
        defer {
            if let newPath {
                try? WorktreeService.discard(
                    worktreePath: newPath,
                    branch: after.worktreeBranch ?? "",
                    projectFolder: project.path)
            }
        }
        if let newPath {
            XCTAssertTrue(WorktreeService.worktreeExists(at: newPath))
        }

        var loaded: Conversation?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            loaded = try await store.load(id: convo.id)
            if loaded?.worktreeBranch != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(
            loaded?.worktreeBranch,
            "ConversationStore must persist worktreeBranch after mergeWorktree")
        XCTAssertEqual(loaded?.worktreeBranch, after.worktreeBranch)
    }

    private func makeGitRepo(prefix: String) throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: [String], timeout: TimeInterval = 10) -> ShellResult {
            ShellRunner.run(
                executable: "/usr/bin/env",
                arguments: ["git"] + args,
                workingDirectory: project,
                timeout: timeout)
        }
        let initR = git(["init"])
        XCTAssertEqual(initR.exitCode, 0, initR.stderr)
        _ = git(["config", "user.email", "test@example.com"], timeout: 5)
        _ = git(["config", "user.name", "Test"], timeout: 5)
        try "readme".write(
            to: project.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        let add = git(["add", "README.md"], timeout: 5)
        XCTAssertEqual(add.exitCode, 0, add.stderr)
        let commit = git(["commit", "-m", "init"])
        XCTAssertEqual(commit.exitCode, 0, commit.stderr)
        return project
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

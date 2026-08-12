//
//  GoalLifecycleTests.swift
//
//  Wave A W1: GoalAssessment heuristics, GoalOrchestrator honesty,
//  natural-finish goal intercept, and tool-pairing invariant.
//

import XCTest
@testable import AgentCore

final class GoalLifecycleTests: XCTestCase {

    // MARK: - GoalAssessment

    func testAssessCompletePlanIsAchieved() {
        let plan = Plan(goal: "Ship feature", todos: [
            Todo(id: "1", text: "Write code", status: .done),
            Todo(id: "2", text: "Tests", status: .skipped),
        ])
        let r = GoalAssessment.assess(
            goalDescription: "Ship feature",
            plan: plan,
            recentErrorFlags: [])
        XCTAssertTrue(r.achieved)
        XCTAssertTrue(r.gaps.isEmpty)
    }

    func testAssessOpenTodosNotAchievedWithGaps() {
        let plan = Plan(goal: "Ship feature", todos: [
            Todo(id: "1", text: "Write code", status: .done),
            Todo(id: "2", text: "Fix build", status: .pending),
            Todo(id: "3", text: "Docs", status: .failed, result: "blocked"),
        ])
        let r = GoalAssessment.assess(
            goalDescription: "Ship feature",
            plan: plan,
            recentErrorFlags: [])
        XCTAssertFalse(r.achieved)
        XCTAssertEqual(r.gaps.count, 2)
        XCTAssertTrue(r.gaps.contains { $0.contains("Fix build") })
        XCTAssertTrue(r.gaps.contains { $0.contains("Docs") })
    }

    func testAssessNoPlanNotAchieved() {
        let r = GoalAssessment.assess(
            goalDescription: "Refactor auth",
            plan: nil,
            recentErrorFlags: [])
        XCTAssertFalse(r.achieved)
        XCTAssertFalse(r.gaps.isEmpty)
        XCTAssertTrue(r.gaps[0].contains("Refactor auth"))
    }

    func testAssessNoPlanSoftAchievedWithBuildAndWork() {
        let r = GoalAssessment.assess(
            goalDescription: "Refactor auth",
            plan: nil,
            recentErrorFlags: [false, false],
            soft: .init(
                buildVerified: true,
                successfulToolRounds: 3,
                hadSuccessfulMutation: true))
        XCTAssertTrue(r.achieved)
        XCTAssertTrue(r.gaps.isEmpty)
    }

    func testAssessNoPlanSoftBlockedWithoutBuild() {
        let r = GoalAssessment.assess(
            goalDescription: "Refactor auth",
            plan: nil,
            recentErrorFlags: [],
            soft: .init(
                buildVerified: false,
                successfulToolRounds: 5,
                hadSuccessfulMutation: true))
        XCTAssertFalse(r.achieved)
        XCTAssertTrue(r.gaps.contains { $0.lowercased().contains("build") })
    }

    func testAssessRecentErrorsNotAchieved() {
        let r = GoalAssessment.assess(
            goalDescription: "Green build",
            plan: nil,
            recentErrorFlags: [false, true, false])
        XCTAssertFalse(r.achieved)
        XCTAssertTrue(r.gaps.contains { $0.lowercased().contains("fail") })
    }

    func testAssessCompletePlanBlockedByRecentErrors() {
        let plan = Plan(goal: "Ship", todos: [
            Todo(id: "1", text: "A", status: .done),
        ])
        let r = GoalAssessment.assess(
            goalDescription: "Ship",
            plan: plan,
            recentErrorFlags: [true])
        XCTAssertFalse(r.achieved)
        XCTAssertTrue(r.gaps.contains { $0.lowercased().contains("fail") })
    }

    func testAssessAllSkippedNotAchieved() {
        let plan = Plan(goal: "Ship", todos: [
            Todo(id: "1", text: "A", status: .skipped),
            Todo(id: "2", text: "B", status: .skipped),
        ])
        let r = GoalAssessment.assess(
            goalDescription: "Ship",
            plan: plan,
            recentErrorFlags: [])
        XCTAssertFalse(r.achieved)
        XCTAssertTrue(r.gaps.contains { $0.lowercased().contains("skipped") })
    }

    func testAssessFailedTodosNotAchieved() {
        let plan = Plan(goal: "Ship", todos: [
            Todo(id: "1", text: "A", status: .done),
            Todo(id: "2", text: "B", status: .failed, result: "boom"),
        ])
        // not isComplete because failed is open-ish - still assert explicitly
        let r = GoalAssessment.assess(
            goalDescription: "Ship",
            plan: plan,
            recentErrorFlags: [])
        XCTAssertFalse(r.achieved)
    }

    func testGoalOrchestratorSeedPreservesAttemptCount() async {
        let orch = GoalOrchestrator(
            goalDescription: "multi-turn",
            seedAttemptCount: 3,
            seedLastFingerprint: GapFingerprint(gaps: ["a"]).value,
            seedConsecutiveStallCount: 1)
        let snap = await orch.snapshot()
        XCTAssertEqual(snap.attemptCount, 3)
        XCTAssertEqual(snap.consecutiveStallCount, 1)
        // next not-achieved with same gaps bumps stall to 2 → pause if threshold 2
        let action = await orch.evaluateTurnEnd(achieved: false, gaps: ["a"])
        // attempt becomes 4; stall count becomes 2 → pause at threshold 2
        XCTAssertEqual(action, .pause(reason: .noProgress))
    }

    // MARK: - GoalOrchestrator (no false complete)

    func testEvaluateTurnEndNotAchievedDoesNotComplete() async {
        let orch = GoalOrchestrator(goalDescription: "Do the thing",
                                    config: .init(maxAttempts: 5, stallThreshold: 3))
        let action = await orch.evaluateTurnEnd(achieved: false, gaps: ["still open"])
        XCTAssertEqual(action, .continue)
        let snap = await orch.snapshot()
        XCTAssertEqual(snap.status, .active)
        XCTAssertEqual(snap.attemptCount, 1)
    }

    func testEvaluateTurnEndAchievedCompletes() async {
        let orch = GoalOrchestrator(goalDescription: "Done goal")
        let action = await orch.evaluateTurnEnd(achieved: true, gaps: [])
        XCTAssertEqual(action, .stop)
        let snap = await orch.snapshot()
        XCTAssertEqual(snap.status, .complete)
    }

    func testRepeatedSameGapsPause() async {
        let orch = GoalOrchestrator(
            goalDescription: "X",
            config: .init(maxAttempts: 10, stallThreshold: 2))
        // 1st: establish fingerprint (count stays 0)
        let a1 = await orch.evaluateTurnEnd(achieved: false, gaps: ["a", "b"])
        XCTAssertEqual(a1, .continue)
        // 2nd: same fingerprint → consecutiveStallCount = 1
        let a2 = await orch.evaluateTurnEnd(achieved: false, gaps: ["b", "a"])
        XCTAssertEqual(a2, .continue)
        // 3rd: count = 2 >= stallThreshold → pause
        let a3 = await orch.evaluateTurnEnd(achieved: false, gaps: ["a", "b"])
        XCTAssertEqual(a3, .pause(reason: .noProgress))
    }

    // MARK: - Tool pairing invariant

    func testUnpairedToolResultIDsDetectsOrphans() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [.init(id: "t1", name: "read_file", arguments: "{}")]),
            ChatMessage(role: .tool, content: "ok", toolCallID: "t1"),
            ChatMessage(role: .tool, content: "BuildGuard: build succeeded", toolCallID: "buildguard"),
        ]
        let orphans = ChatLoop.unpairedToolResultIDs(in: messages)
        XCTAssertEqual(orphans, ["buildguard"])
    }

    func testUnpairedToolResultIDsEmptyWhenPaired() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [
                            .init(id: "a", name: "read_file", arguments: "{}"),
                            .init(id: "b", name: "grep_code", arguments: "{}"),
                        ]),
            ChatMessage(role: .tool, content: "1", toolCallID: "a"),
            ChatMessage(role: .tool, content: "2", toolCallID: "b"),
        ]
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: messages).isEmpty)
    }

    func testBuildGuardSuccessUserReminderCountsAsVerification() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "fix"),
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [.init(id: "e1", name: "write_file", arguments: "{}")]),
            ChatMessage(role: .tool, content: "wrote", toolCallID: "e1"),
            ChatMessage(role: .user, content: SystemReminder.buildGuard(succeeded: true)),
            ChatMessage(role: .assistant, content: "Done."),
        ]
        XCTAssertTrue(ChatLoop.editAlreadyVerifiedThisTurn(
            messages: messages, turnStartIndex: 0,
            mutatingToolNames: ["write_file"],
            verificationToolNames: ["read_file"]))
        XCTAssertTrue(ChatLoop.unpairedToolResultIDs(in: messages).isEmpty)
    }

    // MARK: - AgentLoop natural finish + goal

    private let model = ModelDescriptor(
        id: "test-model", displayName: "Test", backend: .lmStudio)

    private final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
        let identifier: BackendIdentifier = .lmStudio
        private let lock = NSLock()
        private var _captured: [ChatRequest] = []
        private let turns: [[ChatChunk]]
        private var turnIndex = 0

        init(turns: [[ChatChunk]]) { self.turns = turns }

        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }; return _captured.count
        }

        func listModels() async throws -> [ModelDescriptor] { [] }

        func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            lock.lock()
            _captured.append(request)
            let chunks = turns.isEmpty ? [] : turns[min(turnIndex, turns.count - 1)]
            turnIndex += 1
            lock.unlock()
            return AsyncThrowingStream { cont in
                for c in chunks { cont.yield(c) }
                cont.finish()
            }
        }

        func cancel(streamID: UUID) async {}
    }

    func testNaturalFinishWithOpenGoalContinuesThenCanComplete() async throws {
        // Turn 1: model finishes without tools → goal open → continue
        // Turn 2: model finishes again → still open → continue until maxAttempts pause
        // Use maxAttempts via GoalOrchestrator default 5 — script 6 finishing turns.
        let finish: [ChatChunk] = [.contentDelta("All done!"), .done(finishReason: "stop")]
        let turns = Array(repeating: finish, count: 6)
        let backend = ScriptedBackend(turns: turns)
        let config = AgentLoop.Configuration(
            maxIterations: 20,
            verifyEdits: false,
            dreamEnabled: false,
            goalDescription: "Implement full auth system")
        let loop = AgentLoop(backend: backend, model: model, config: config)
        let collector = EventCollector()
        _ = try await loop.run(
            userMessage: "do auth",
            conversation: Conversation()) { event in
            collector.append(event)
        }
        // Should not finish on first empty-tool reply — goal forces more iterations
        // until maxAttempts (5) pause or iteration progress.
        XCTAssertGreaterThan(backend.requestCount, 1,
                             "open goal must not end on first natural finish")
        XCTAssertTrue(collector.events.contains {
            if case .finished = $0 { return true }
            return false
        })
    }

    func testNaturalFinishWithCompletePlanStops() async throws {
        let convoID = UUID()
        let convo = Conversation(id: convoID, title: "t")
        let plan = Plan(goal: "Small fix", todos: [
            Todo(id: "1", text: "Done step", status: .done),
        ])
        await PlanStore.shared.setPlan(plan, for: convoID)

        let finish: [ChatChunk] = [.contentDelta("Completed the fix."), .done(finishReason: "stop")]
        let backend = ScriptedBackend(turns: [finish])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(
                maxIterations: 10,
                verifyEdits: false,
                dreamEnabled: false,
                goalDescription: "Small fix"))
        let collector = EventCollector()
        _ = try await loop.run(userMessage: "fix", conversation: convo) { event in
            collector.append(event)
        }
        XCTAssertTrue(collector.events.contains {
            if case .finished = $0 { return true }
            return false
        })
        XCTAssertEqual(backend.requestCount, 1,
                       "complete plan should allow natural finish on first try")
        await PlanStore.shared.clear(for: convoID)
    }

    func testPrematureStopOnNaturalFinishInjectsContinuation() async throws {
        let bail: [ChatChunk] = [
            .contentDelta("I can't proceed without more information."),
            .done(finishReason: "stop"),
        ]
        let recover: [ChatChunk] = [
            .contentDelta("Continuing with a different approach."),
            .done(finishReason: "stop"),
        ]
        let backend = ScriptedBackend(turns: [bail, recover, recover, recover, recover, recover])
        let loop = AgentLoop(
            backend: backend,
            model: model,
            config: .init(
                maxIterations: 15,
                verifyEdits: false,
                dreamEnabled: false,
                goalDescription: "Finish the migration"))
        let collector = EventCollector()
        _ = try await loop.run(userMessage: "migrate", conversation: Conversation()) { event in
            collector.append(event)
        }
        XCTAssertGreaterThan(backend.requestCount, 1)
        let infos = collector.events.compactMap { e -> String? in
            if case .info(let s) = e { return s }
            return nil
        }
        XCTAssertTrue(
            infos.contains { $0.lowercased().contains("premature") || $0.lowercased().contains("goal") },
            "expected goal/premature info events, got \(infos)")
    }
}

/// Thread-safe LoopEvent collector for async callbacks.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LoopEvent] = []
    func append(_ e: LoopEvent) {
        lock.lock(); _events.append(e); lock.unlock()
    }
    var events: [LoopEvent] {
        lock.lock(); defer { lock.unlock() }; return _events
    }
}


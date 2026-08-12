//
//  UserQuestionCoordinatorTests.swift
//
//  FIFO queue for concurrent ask_user — never silent empty for dropped waits.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class UserQuestionCoordinatorTests: XCTestCase {

    func testSingleQuestionResolvesWithAnswer() async {
        let coord = UserQuestionCoordinator()
        let q = AgentQuestion(question: "Ship it?", options: ["Yes", "No"])

        async let answer = coord.ask(q)
        // Yield so ask installs pending state.
        await Task.yield()
        XCTAssertEqual(coord.pendingQuestion?.question, "Ship it?")
        XCTAssertEqual(coord.queuedCount, 0)

        coord.resolve(answer: "Yes")
        let result = await answer
        XCTAssertEqual(result, "Yes")
        XCTAssertNil(coord.pendingQuestion)
        XCTAssertEqual(coord.queuedCount, 0)
    }

    func testConcurrentQuestionsQueueFIFONeverEmptyDrop() async {
        let coord = UserQuestionCoordinator()
        let q1 = AgentQuestion(question: "First?")
        let q2 = AgentQuestion(question: "Second?")
        let q3 = AgentQuestion(question: "Third?")

        async let a1 = coord.ask(q1)
        await Task.yield()
        async let a2 = coord.ask(q2)
        await Task.yield()
        async let a3 = coord.ask(q3)
        await Task.yield()

        XCTAssertEqual(coord.pendingQuestion?.question, "First?")
        XCTAssertEqual(coord.queuedCount, 2)

        coord.resolve(answer: "A")
        await Task.yield()
        XCTAssertEqual(coord.pendingQuestion?.question, "Second?")
        XCTAssertEqual(coord.queuedCount, 1)

        coord.resolve(answer: "B")
        await Task.yield()
        XCTAssertEqual(coord.pendingQuestion?.question, "Third?")
        XCTAssertEqual(coord.queuedCount, 0)

        coord.resolve(answer: "C")
        let results = await (a1, a2, a3)
        XCTAssertEqual(results.0, "A")
        XCTAssertEqual(results.1, "B")
        XCTAssertEqual(results.2, "C")
        // None of the concurrent waiters received the old silent "" drop.
        XCTAssertFalse([results.0, results.1, results.2].contains(""))
        XCTAssertNil(coord.pendingQuestion)
    }

    func testEmptyAnswerIsOnlyFromExplicitResolve() async {
        let coord = UserQuestionCoordinator()
        async let answer = coord.ask(AgentQuestion(question: "Dismiss me?"))
        await Task.yield()
        coord.resolve(answer: "")
        let result = await answer
        XCTAssertEqual(result, "")
    }
}

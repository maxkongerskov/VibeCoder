//
//  OrchestratorTests.swift
//
//  Pins the two-model orchestrator handoff's pure pieces: the brief
//  block that gets injected into the worker's system prompt, and the
//  PlanResult success semantics that decide whether the worker runs
//  against a plan or solo.
//

import XCTest
@testable import AgentCore

final class OrchestratorTests: XCTestCase {

    // MARK: - orchestratorBriefBlock (system-prompt injection)

    func testBriefBlockNilForNilBrief() {
        XCTAssertNil(AgentSystemPromptComposer.orchestratorBriefBlock(nil))
    }

    func testBriefBlockNilForBlankBrief() {
        XCTAssertNil(AgentSystemPromptComposer.orchestratorBriefBlock("   \n\t  "))
    }

    func testBriefBlockWrapsContent() {
        let block = AgentSystemPromptComposer.orchestratorBriefBlock("1. Edit Foo.swift\n2. Build")
        XCTAssertNotNil(block)
        // The worker must see it labelled as the orchestrator's plan.
        XCTAssertTrue(block!.contains("Execution plan"))
        XCTAssertTrue(block!.contains("1. Edit Foo.swift"))
        XCTAssertTrue(block!.contains("2. Build"))
    }

    func testBriefBlockTrimsSurroundingWhitespace() {
        let block = AgentSystemPromptComposer.orchestratorBriefBlock("\n\n  do the thing  \n\n")
        XCTAssertNotNil(block)
        // No leading/trailing blank lines around the brief body.
        XCTAssertFalse(block!.contains("\n\n\n"))
        XCTAssertTrue(block!.contains("do the thing"))
    }

    // MARK: - PlanResult success semantics

    func testPlanResultEmptyIsNotSucceeded() {
        XCTAssertFalse(Orchestrator.PlanResult(brief: "", iterations: 0).succeeded)
        XCTAssertFalse(Orchestrator.PlanResult(brief: "   ", iterations: 3).succeeded)
    }

    func testPlanResultWithBriefSucceeds() {
        let r = Orchestrator.PlanResult(brief: "Step 1: do it", iterations: 2)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.iterations, 2)
    }
}

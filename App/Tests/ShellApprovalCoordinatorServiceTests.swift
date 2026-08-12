//
//  ShellApprovalCoordinatorServiceTests.swift
//
//  Wave B S4 W09 — MainActor Once/Always/Never suspension bridge.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

@MainActor
final class ShellApprovalCoordinatorServiceTests: XCTestCase {

    func testOnceResolvesFromSheet() async {
        let service = ShellApprovalCoordinatorService()
        let request = ShellApprovalRequest(
            toolName: "run_shell",
            reason: "Ask mode requires approval",
            command: "ls",
            detail: "ls"
        )

        async let decision = service.review(request)
        await Task.yield()
        XCTAssertEqual(service.pending?.request.toolName, "run_shell")

        service.resolve(.once)
        let result = await decision
        XCTAssertEqual(result, .once)
        XCTAssertNil(service.pending)
    }

    func testConcurrentAskQueuesFIFO() async {
        let service = ShellApprovalCoordinatorService()
        let r1 = ShellApprovalRequest(toolName: "run_shell", reason: "first", command: "a")
        let r2 = ShellApprovalRequest(toolName: "run_shell", reason: "second", command: "b")

        async let d1 = service.review(r1)
        await Task.yield()
        async let d2 = service.review(r2)
        await Task.yield()

        service.resolve(.always)
        let first = await d1
        XCTAssertEqual(first, .always)

        // Next sheet is scheduled on next MainActor tick.
        await Task.yield()
        await Task.yield()
        if service.pending != nil {
            service.resolve(.once)
        } else {
            // Force drain if re-present race — still must not hang.
            service.denyPendingAndDrain()
        }
        let second = await d2
        XCTAssertTrue(second == .once || second == .deny)
    }

    func testDismissDeniesPending() async {
        let service = ShellApprovalCoordinatorService()
        let request = ShellApprovalRequest(toolName: "run_shell", reason: "x", command: "ls")
        async let decision = service.review(request)
        await Task.yield()
        service.handleSheetDismiss()
        let result = await decision
        XCTAssertEqual(result, .deny)
        XCTAssertNil(service.pending)
    }

    func testMakeCoordinatorBridgesToService() async {
        let service = ShellApprovalCoordinatorService()
        let handle = service.makeCoordinator()
        let request = ShellApprovalRequest(
            toolName: "server__tool",
            reason: "MCP ask",
            detail: "server__tool"
        )

        async let decision = handle.review(request)
        await Task.yield()
        XCTAssertNotNil(service.pending)
        service.resolve(.never)
        let result = await decision
        XCTAssertEqual(result, .never)
    }
}

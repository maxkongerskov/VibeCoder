//
//  BuildGuardVerifyEditsTests.swift
//  S5 — BuildGuard outcome + system reminder contract.
//

import XCTest
@testable import AgentCore

final class BuildGuardVerifyEditsTests: XCTestCase {

    /// D04: shipped `BuildGuard.verify` on a Swift package that does not
    /// compile must return `.failed` with compiler text (injected to the model).
    func testVerifyBrokenSwiftPackageReturnsFailedLog() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let package = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "BrokenPkg",
            targets: [.target(name: "BrokenPkg")]
        )
        """
        try package.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let src = dir.appendingPathComponent("Sources/BrokenPkg", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "let x: Int = \"nope\"\n".write(
            to: src.appendingPathComponent("Broken.swift"), atomically: true, encoding: .utf8)

        let outcome = await BuildGuard.verify(at: dir)
        guard case .failed(let log) = outcome else {
            return XCTFail("expected failed compile, got \(outcome)")
        }
        let lower = log.lowercased()
        XCTAssertTrue(
            lower.contains("error") || lower.contains("cannot convert"),
            "failed log must contain compiler text, got: \(log.prefix(500))")
    }

    func testVerifyNoBuildSystemInEmptyDir() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await BuildGuard.verify(at: dir)
        if case .noBuildSystem = outcome {
            // expected
        } else {
            XCTFail("expected noBuildSystem, got \(outcome)")
        }
    }

    func testSystemReminderBuildGuardMarkers() {
        let ok = SystemReminder.buildGuard(succeeded: true)
        XCTAssertTrue(ok.contains("BuildGuard: build succeeded"))
        XCTAssertTrue(ok.contains("# System reminder — BuildGuard"))

        let fail = SystemReminder.buildGuard(succeeded: false, detail: "error: demo")
        XCTAssertTrue(fail.contains("BuildGuard: build failed"))
        XCTAssertTrue(fail.contains("error: demo"))
    }

    func testDefaultVerifyEditsIsOnInAppSettings() {
        let s = AppSettings()
        XCTAssertTrue(s.verifyEdits, "product default must keep auto-verify on")
    }

    func testAgentLoopConfigDefaultVerifyEdits() {
        let c = AgentLoop.Configuration()
        XCTAssertTrue(c.verifyEdits)
    }

    func testSystemReminderIsWireOnly() {
        XCTAssertTrue(SystemReminder.isWireOnly(SystemReminder.buildGuard(succeeded: true)))
        XCTAssertTrue(SystemReminder.isWireOnly(
            SystemReminder.buildGuard(succeeded: false, detail: "error: demo")))
        XCTAssertTrue(SystemReminder.isWireOnly(
            SystemReminder.autoVerify(path: "/tmp/a.swift", tail: "let x = 1")))
        XCTAssertTrue(SystemReminder.isWireOnly(SystemReminder.memoryFirstTurn("- note")))
        XCTAssertTrue(SystemReminder.isWireOnly(SystemReminder.interjection("stop")))
        XCTAssertTrue(SystemReminder.isWireOnly(
            "[system] Background job update for the parent agent:\noutput: hello"))
        XCTAssertTrue(SystemReminder.isWireOnly(
            "[Background job completed] kind=subagent task_id=X"))
        XCTAssertFalse(SystemReminder.isWireOnly("Please edit App.swift"))
        XCTAssertFalse(SystemReminder.isWireOnly(""))
    }

    func testWireOnlyReminderDoesNotAppearInTranscript() {
        let real = ChatMessage(role: .user, content: "fix the build")
        let log = ChatMessage(
            role: .user,
            content: SystemReminder.autoVerify(path: "App.swift", tail: "let x = 1")
        )
        let build = ChatMessage(
            role: .user,
            content: SystemReminder.buildGuard(succeeded: true)
        )
        XCTAssertTrue(real.appearsInTranscript)
        XCTAssertFalse(real.isWireOnlySystemReminder)
        XCTAssertTrue(log.isWireOnlySystemReminder)
        XCTAssertFalse(log.appearsInTranscript)
        XCTAssertTrue(build.isWireOnlySystemReminder)
        XCTAssertFalse(build.appearsInTranscript)
    }

    func testLastVisibleUserIndexSkipsHarnessLog() {
        let msgs = [
            ChatMessage(role: .user, content: "edit App.swift"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCallInvocation(id: "c1", name: "edit_file", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "ok", toolCallID: "c1"),
            ChatMessage(
                role: .user,
                content: SystemReminder.autoVerify(path: "App.swift", tail: "print(1)")
            ),
        ]
        XCTAssertEqual(msgs.lastVisibleUserIndex(), 0)
        XCTAssertEqual(msgs[msgs.lastVisibleUserIndex()!].content, "edit App.swift")
    }

    func testTurnGroupDoesNotTreatAutoVerifyAsANewUserTurn() {
        let user = ChatMessage(role: .user, content: "edit App.swift")
        let asst = ChatMessage(role: .assistant, content: "Done.")
        let log = ChatMessage(
            role: .user,
            content: SystemReminder.autoVerify(path: "App.swift", tail: "print(1)")
        )
        let turns = Turn.group([user, asst, log])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].user.content, "edit App.swift")
        XCTAssertEqual(turns[0].answer?.content, "Done.")
    }
}

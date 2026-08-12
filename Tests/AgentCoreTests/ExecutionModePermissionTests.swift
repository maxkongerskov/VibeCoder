//
//  ExecutionModePermissionTests.swift
//
//  Ensures the input-card permission modes are enforced at the registry,
//  not just shown in the UI.
//

import XCTest
@testable import AgentCore

final class ExecutionModePermissionTests: XCTestCase {

    override func setUp() async throws {
        await ToolRegistry.shared.registerBuiltins()
        await RememberedGrants.shared.clear()
    }

    /// Project root for tests — must match write paths under path confinement.
    private var projectRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentos-execmode-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
    }

    private func context(mode: ExecutionMode, withReviewer: Bool = false,
                         root: URL? = nil) -> ToolContext {
        let reviewer: PatchReviewer? = withReviewer
            ? PatchReviewer { _ in .rejectAll }
            : nil
        let rootURL = root ?? projectRoot
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return ToolContext(
            projectRoot: rootURL,
            patchReviewer: reviewer,
            conversationID: UUID(),
            executionMode: mode
        )
    }

    func testPlanModeDeniesWriteFile() async {
        let root = projectRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = context(mode: .plan, root: root)
        let path = root.appendingPathComponent("agentos-plan-test.txt").path
        let args = ToolArguments(dictionary: [
            "path": path,
            "content": "nope",
        ])
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file", arguments: args, context: ctx)
            XCTFail("Plan mode must deny write_file")
        } catch let err as ToolError {
            XCTAssertTrue("\(err)".lowercased().contains("plan")
                          || "\(err)".lowercased().contains("read-only")
                          || "\(err)".lowercased().contains("permission"))
        } catch {
            // ToolError may wrap differently
            XCTAssertTrue(error.localizedDescription.lowercased().contains("plan")
                          || error.localizedDescription.lowercased().contains("permission")
                          || error.localizedDescription.lowercased().contains("read-only"),
                          error.localizedDescription)
        }
    }

    func testPlanModeDeniesMutatingRunShell() async {
        let ctx = context(mode: .plan)
        // echo is safe-bash (allowed in plan); use a mutating command.
        let args = ToolArguments(dictionary: [
            "command": "touch \(projectRoot.path)/plan-mode-should-fail-\(UUID().uuidString)"
        ])
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "run_shell", arguments: args, context: ctx)
            XCTFail("Plan mode must deny mutating run_shell")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("plan")
                || error.localizedDescription.lowercased().contains("permission")
                || error.localizedDescription.lowercased().contains("read-only"),
                error.localizedDescription)
        }
    }

    func testPlanModeAllowsReadFile() async throws {
        // read_file may fail on missing path with a tool error content,
        // but must NOT fail with Plan mode permission denied.
        let root = projectRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = context(mode: .plan, root: root)
        let tmp = root.appendingPathComponent("agentos-plan-read-\(UUID().uuidString).txt")
        try "hello".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ToolArguments(dictionary: ["path": tmp.path])
        let result = try await ToolRegistry.shared.execute(
            name: "read_file", arguments: args, context: ctx)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("hello"))
    }

    func testYoloModeAllowsWriteWithoutReviewer() async throws {
        let root = projectRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = context(mode: .yolo, withReviewer: false, root: root)
        let tmp = root.appendingPathComponent("agentos-yolo-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ToolArguments(dictionary: [
            "path": tmp.path,
            "content": "yolo-ok",
        ])
        let result = try await ToolRegistry.shared.execute(
            name: "write_file", arguments: args, context: ctx)
        XCTAssertFalse(result.isError, result.content)
        let written = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(written, "yolo-ok")
    }

    func testAskModeRejectsWriteWhenReviewerDenies() async {
        let root = projectRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = context(mode: .build, withReviewer: true, root: root)
        let tmp = root.appendingPathComponent("agentos-ask-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ToolArguments(dictionary: [
            "path": tmp.path,
            "content": "should-not-write",
        ])
        do {
            _ = try await ToolRegistry.shared.execute(
                name: "write_file", arguments: args, context: ctx)
            // If it returns a result instead of throw, it should be error
            XCTFail("expected rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("reject")
                || error.localizedDescription.lowercased().contains("permission"),
                error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testExecutionModeCycle() {
        XCTAssertEqual(ExecutionMode.plan.next(), .build)
        XCTAssertEqual(ExecutionMode.build.next(), .edit)
        XCTAssertEqual(ExecutionMode.edit.next(), .yolo)
        XCTAssertEqual(ExecutionMode.yolo.next(), .plan)
    }
}

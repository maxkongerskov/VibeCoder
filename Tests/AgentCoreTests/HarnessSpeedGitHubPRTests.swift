//
//  HarnessSpeedGitHubPRTests.swift
//
//  Identical consecutive tools + prefer `gh` for GitHub PR status.
//

import XCTest
@testable import AgentCore

private final class ExecCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

final class HarnessSpeedGitHubPRTests: XCTestCase {

    private func fakeMeta(_ name: String) -> ToolRegistry.ToolMetadata {
        ToolRegistry.ToolMetadata(
            name: name,
            category: .debug,
            permission: .readOnly,
            availability: .core,
            schema: ToolSchema(
                name: name,
                description: "test probe",
                parameters: .init(properties: [
                    "x": .init(type: "integer", description: "payload")
                ])
            )
        )
    }

    func testIdenticalConsecutiveToolCallIsBlockedWithoutSecondExecute() async throws {
        let registry = ToolRegistry()
        let counter = ExecCounter()
        await registry.registerDynamicTool(metadata: fakeMeta("fake_probe")) { _, _ in
            let n = counter.bump()
            return ToolResult(content: "ran-\(n)", isError: false)
        }
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID())
        let args = ToolArguments(dictionary: ["x": 1])

        let first = try await registry.execute(name: "fake_probe", arguments: args, context: ctx)
        let second = try await registry.execute(name: "fake_probe", arguments: args, context: ctx)

        XCTAssertFalse(first.isError)
        XCTAssertEqual(first.content, "ran-1")
        XCTAssertTrue(second.isError)
        XCTAssertTrue(second.content.contains("Identical consecutive"))
        XCTAssertTrue(second.content.contains("previous"))
        XCTAssertEqual(counter.value, 1)
    }

    func testEquivalentJSONKeyOrderCountsAsIdentical() async throws {
        let registry = ToolRegistry()
        let counter = ExecCounter()
        await registry.registerDynamicTool(metadata: fakeMeta("fake_probe")) { _, _ in
            _ = counter.bump()
            return ToolResult(content: "ok", isError: false)
        }
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID())
        let a = try ToolArguments(json: #"{"b":2,"a":1}"#)
        let b = try ToolArguments(json: #"{"a":1,"b":2}"#)
        _ = try await registry.execute(name: "fake_probe", arguments: a, context: ctx)
        let second = try await registry.execute(name: "fake_probe", arguments: b, context: ctx)
        XCTAssertTrue(second.isError)
        XCTAssertEqual(counter.value, 1)
    }

    func testDifferentArgsAreNotBlocked() async throws {
        let registry = ToolRegistry()
        let counter = ExecCounter()
        await registry.registerDynamicTool(metadata: fakeMeta("fake_probe")) { _, _ in
            let n = counter.bump()
            return ToolResult(content: "ran-\(n)", isError: false)
        }
        let ctx = ToolContext(projectRoot: nil, conversationID: UUID())
        _ = try await registry.execute(
            name: "fake_probe",
            arguments: ToolArguments(dictionary: ["x": 1]),
            context: ctx)
        let second = try await registry.execute(
            name: "fake_probe",
            arguments: ToolArguments(dictionary: ["x": 2]),
            context: ctx)
        XCTAssertFalse(second.isError)
        XCTAssertEqual(second.content, "ran-2")
        XCTAssertEqual(counter.value, 2)
    }

    func testCurlGitHubPRAPIPrefersGh() {
        let cmd = "curl -s https://api.github.com/repos/foo/bar/pulls/12"
        let msg = GitHubPRStatusPolicy.preferGhDenial(forShellCommand: cmd)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("gh pr view"))
        XCTAssertTrue(msg!.contains("gh api"))
    }

    func testPythonGitHubComparePrefersGh() {
        let cmd = #"python3 -c "import urllib.request; urllib.request.urlopen('https://api.github.com/repos/foo/bar/compare/main...head')""#
        let msg = GitHubPRStatusPolicy.preferGhDenial(forShellCommand: cmd)
        XCTAssertNotNil(msg)
    }

    func testNonGitHubCurlIsAllowed() {
        XCTAssertNil(GitHubPRStatusPolicy.preferGhDenial(
            forShellCommand: "curl -s https://example.com/health"))
    }

    func testGhItselfIsAllowed() {
        XCTAssertNil(GitHubPRStatusPolicy.preferGhDenial(
            forShellCommand: "gh pr view 12 --json state,mergedAt"))
        XCTAssertNil(GitHubPRStatusPolicy.preferGhDenial(
            forShellCommand: "gh api repos/foo/bar/pulls/12"))
    }

    func testFetchURLGitHubPRPrefersGh() {
        let msg = GitHubPRStatusPolicy.preferGhDenial(
            forFetchURL: "https://api.github.com/repos/foo/bar/pulls/3")
        XCTAssertNotNil(msg)
    }

    func testMergedTrueSurfacesStopBanner() {
        let raw = #"{"url":"https://api.github.com/repos/o/r/pulls/1","merged": true, "state":"closed"}"#
        let out = GitHubPRStatusPolicy.decorateIfMerged(raw)
        XCTAssertTrue(out.hasPrefix("PR_STATUS: MERGED"))
        XCTAssertTrue(out.contains("do not call compare") || out.contains("Do not call compare"))
        XCTAssertTrue(GitHubPRStatusPolicy.looksMerged("MERGED"))
        XCTAssertFalse(GitHubPRStatusPolicy.looksMerged(#"{"merged": false}"#))
        XCTAssertFalse(GitHubPRStatusPolicy.looksMerged("UNMERGED"))
    }
}

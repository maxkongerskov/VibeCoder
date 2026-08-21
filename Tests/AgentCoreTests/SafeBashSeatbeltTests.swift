//
//  SafeBashSeatbeltTests.swift
//  PB8 — seatbelt profile generation + dry-run launch resolution.
//  Does not require SIP changes or live sandbox-exec success for CI.
//

import XCTest
@testable import AgentCore

final class SafeBashSeatbeltTests: XCTestCase {

    // MARK: - Enablement

    func testSeatbeltEnvForcesOn() {
        let env = ["VIBECODER_SHELL_SEATBELT": "1"]
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .yolo))
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .plan))
    }

    func testSeatbeltEnvForcesOff() {
        let env = ["VIBECODER_SHELL_SEATBELT": "off"]
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .edit))
    }

    func testSeatbeltDefaultOnForAutoEditOnly() {
        let env: [String: String] = [:]
        XCTAssertTrue(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .edit))
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .yolo))
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .plan))
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: .build))
        XCTAssertFalse(SafeBash.isSeatbeltEnabled(environment: env, executionMode: nil))
    }

    func testSeatbeltFailMode() {
        XCTAssertEqual(
            SafeBash.seatbeltFailMode(environment: [:]),
            .open
        )
        XCTAssertEqual(
            SafeBash.seatbeltFailMode(environment: ["VIBECODER_SHELL_SEATBELT_FAIL": "closed"]),
            .closed
        )
        XCTAssertEqual(
            SafeBash.seatbeltFailMode(environment: ["AGENTOS_SHELL_SEATBELT_FAIL": "open"]),
            .open
        )
    }

    // MARK: - Profile generation

    func testProfileContainsVersionAndWriteFence() {
        let profile = SafeBash.makeSeatbeltProfile(writableRoots: ["/Users/me/proj"])
        XCTAssertTrue(profile.hasPrefix("(version 1)\n") || profile.contains("(version 1)"))
        XCTAssertTrue(profile.contains("(allow default)"))
        XCTAssertTrue(profile.contains("(deny file-write*)"))
        XCTAssertTrue(profile.contains("(subpath \"/Users/me/proj\")"))
        // Temp areas always present
        XCTAssertTrue(profile.contains("/tmp") || profile.contains("/private/tmp"))
    }

    func testSbplStringEscapesQuotes() {
        let s = SafeBash.sbplString("path/with\"quote")
        XCTAssertEqual(s, "\"path/with\\\"quote\"")
    }

    func testWritableRootsWorktreeExcludesMainProject() {
        let proj = URL(fileURLWithPath: "/tmp/vc-seatbelt-proj")
        let wt = URL(fileURLWithPath: "/tmp/vc-seatbelt-wt")
        // cwd outside worktree must not re-open the main project.
        let roots = SafeBash.writableRoots(
            workingDirectory: proj,
            projectRoot: proj,
            worktreeRoot: wt
        )
        XCTAssertEqual(roots, [wt.path])
        XCTAssertFalse(roots.contains(proj.path))

        // cwd under worktree is allowed (same root).
        let roots2 = SafeBash.writableRoots(
            workingDirectory: wt.appendingPathComponent("src"),
            projectRoot: proj,
            worktreeRoot: wt
        )
        XCTAssertTrue(roots2.contains(wt.path))
        XCTAssertFalse(roots2.contains(proj.path))
    }

    func testProfileOmitsTempRootWhenMainProjectLivesThere() {
        let proj = URL(fileURLWithPath: "/tmp/vc-main-in-tmp")
        let wt = URL(fileURLWithPath: "/tmp/vc-wt-in-tmp")
        let profile = SafeBash.makeSeatbeltProfile(
            writableRoots: [wt.path],
            excludingWritesUnder: proj
        )
        XCTAssertTrue(
            profile.contains("(subpath \(SafeBash.sbplString((wt.path as NSString).standardizingPath)))"),
            profile)
        let tmp = ("/tmp" as NSString).standardizingPath
        let privateTmp = ("/private/tmp" as NSString).standardizingPath
        XCTAssertFalse(
            profile.contains("(subpath \(SafeBash.sbplString(tmp)))"),
            "blanket /tmp must not be writable when main lives there:\n\(profile)")
        XCTAssertFalse(
            profile.contains("(subpath \(SafeBash.sbplString(privateTmp)))"),
            "blanket /private/tmp must not be writable when main lives there:\n\(profile)")
    }

    func testProfileKeepsTempWhenProjectIsOutsideTemp() {
        let profile = SafeBash.makeSeatbeltProfile(
            writableRoots: ["/Users/me/proj"],
            excludingWritesUnder: URL(fileURLWithPath: "/Users/me/proj")
        )
        XCTAssertTrue(profile.contains("/tmp") || profile.contains("/private/tmp"), profile)
    }

    // MARK: - Dry-run launch path

    func testSeatbeltInvocationDryRunShape() {
        let launch = SafeBash.seatbeltInvocation(
            command: "echo hi",
            writableRoots: ["/tmp/project"],
            shellPath: "/bin/zsh",
            sandboxExecPath: "/usr/bin/sandbox-exec"
        )
        XCTAssertNotNil(launch)
        XCTAssertEqual(launch?.executable, "/usr/bin/sandbox-exec")
        XCTAssertEqual(launch?.arguments.first, "-p")
        XCTAssertTrue(launch?.sandboxed == true)
        XCTAssertEqual(launch?.arguments.dropFirst().first, launch?.profile)
        // … sandbox-exec -p PROFILE /bin/zsh -c command
        XCTAssertEqual(launch?.arguments.suffix(3).map { $0 }, ["/bin/zsh", "-c", "echo hi"])
        XCTAssertTrue(launch?.profile.contains("/tmp/project") == true)
    }

    func testResolveDisabledReturnsBareZsh() {
        let env = ["VIBECODER_SHELL_SEATBELT": "0"]
        let launch = SafeBash.resolveShellLaunch(
            command: "ls",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            projectRoot: URL(fileURLWithPath: "/tmp"),
            worktreeRoot: nil,
            executionMode: .edit,
            environment: env
        )
        XCTAssertFalse(launch.sandboxed)
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.arguments, ["-c", "ls"])
        XCTAssertNil(launch.note)
    }

    func testResolveEnabledMissingBinaryFailOpen() {
        let env: [String: String] = [
            "VIBECODER_SHELL_SEATBELT": "1",
            "VIBECODER_SHELL_SEATBELT_FAIL": "open",
        ]
        let launch = SafeBash.resolveShellLaunch(
            command: "ls",
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            worktreeRoot: nil,
            executionMode: .yolo,
            environment: env,
            sandboxExecPath: "/nonexistent/sandbox-exec-\(UUID().uuidString)"
        )
        XCTAssertFalse(launch.sandboxed)
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertTrue(launch.note?.contains("fail-open") == true)
        XCTAssertFalse(SafeBash.isSeatbeltRefusal(launch))
    }

    func testYoloWorktreeForcesSeatbeltEvenWhenEnvOff() {
        let proj = URL(fileURLWithPath: "/tmp/vc-yolo-main")
        let wt = URL(fileURLWithPath: "/tmp/vc-yolo-wt")
        let env = ["VIBECODER_SHELL_SEATBELT": "0"]
        let launch = SafeBash.resolveShellLaunch(
            command: "echo hi",
            workingDirectory: wt,
            projectRoot: proj,
            worktreeRoot: wt,
            executionMode: .yolo,
            environment: env,
            sandboxExecPath: "/usr/bin/sandbox-exec"
        )
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            XCTAssertTrue(launch.sandboxed, launch.note ?? "expected worktree fence in yolo")
            XCTAssertTrue(launch.profile.contains(wt.path), launch.profile)
            XCTAssertFalse(launch.profile.contains("(subpath \"\(proj.path)\")"))
        } else {
            XCTAssertTrue(SafeBash.isSeatbeltRefusal(launch), launch.note ?? "")
        }
    }

    func testYoloWorktreeMissingBinaryFailClosed() {
        let proj = URL(fileURLWithPath: "/tmp/vc-yolo-main")
        let wt = URL(fileURLWithPath: "/tmp/vc-yolo-wt")
        let launch = SafeBash.resolveShellLaunch(
            command: "echo hi",
            workingDirectory: wt,
            projectRoot: proj,
            worktreeRoot: wt,
            executionMode: .yolo,
            environment: ["VIBECODER_SHELL_SEATBELT_FAIL": "open"],
            sandboxExecPath: "/nonexistent/sandbox-exec-\(UUID().uuidString)"
        )
        XCTAssertTrue(
            SafeBash.isSeatbeltRefusal(launch),
            "worktree isolation must fail-closed without sandbox-exec: \(launch.note ?? "")")
    }

    func testResolveEnabledMissingBinaryFailClosed() {
        let env: [String: String] = [
            "VIBECODER_SHELL_SEATBELT": "1",
            "VIBECODER_SHELL_SEATBELT_FAIL": "closed",
        ]
        let launch = SafeBash.resolveShellLaunch(
            command: "ls",
            workingDirectory: URL(fileURLWithPath: "/tmp/proj"),
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            worktreeRoot: nil,
            executionMode: .edit,
            environment: env,
            sandboxExecPath: "/nonexistent/sandbox-exec-\(UUID().uuidString)"
        )
        XCTAssertFalse(launch.sandboxed)
        XCTAssertTrue(SafeBash.isSeatbeltRefusal(launch))
        XCTAssertTrue(launch.note?.contains("fail-closed") == true)
    }

    func testResolveEnabledWithRealBinarySandboxes() {
        // Dry-run shape only — does not execute sandbox-exec (no SIP dependency).
        let env = ["VIBECODER_SHELL_SEATBELT": "1"]
        let launch = SafeBash.resolveShellLaunch(
            command: "pwd",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            projectRoot: URL(fileURLWithPath: "/tmp"),
            worktreeRoot: nil,
            executionMode: .edit,
            environment: env,
            sandboxExecPath: "/usr/bin/sandbox-exec"
        )
        // On macOS CI/dev hosts sandbox-exec exists; if missing, fail-open note.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            XCTAssertTrue(launch.sandboxed, launch.note ?? "")
            XCTAssertEqual(launch.executable, "/usr/bin/sandbox-exec")
            XCTAssertEqual(launch.arguments.first, "-p")
            XCTAssertFalse(launch.profile.isEmpty)
        } else {
            XCTAssertFalse(launch.sandboxed)
        }
    }

    func testIsSeatbeltRefusalFalseForHappyPath() {
        let launch = SafeBash.ShellLaunch(
            executable: "/usr/bin/sandbox-exec",
            arguments: ["-p", "(version 1)", "/bin/zsh", "-c", "true"],
            sandboxed: true
        )
        XCTAssertFalse(SafeBash.isSeatbeltRefusal(launch))
    }
}

//
//  ShellRunnerTests.swift
//
//  Pins the pipe-drain behaviour: before the 2026-06-09 fix, any child
//  process writing more than the ~64 KB pipe buffer deadlocked
//  ShellRunner until the timeout watchdog killed it (the child blocked
//  on write, the parent blocked on waitUntilExit).
//

import XCTest
@testable import AgentCore

final class ShellRunnerTests: XCTestCase {

    func testLargeOutputDoesNotDeadlockAndIsReturnedFully() {
        // 1 MB — way past the pipe buffer. Must return promptly with the
        // full payload and a zero exit code.
        let start = Date()
        let result = ShellRunner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "head -c 1000000 < /dev/zero | tr '\\0' 'x'"],
            timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 25,
                          "large output must not stall until the timeout")
    }

    func testLargeStderrIsAlsoDrained() {
        let result = ShellRunner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "head -c 200000 < /dev/zero | tr '\\0' 'e' 1>&2"],
            timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.utf8.count, 200_000)
    }

    func testTimeoutTerminatesAndReturnsPartialOutput() {
        let start = Date()
        let result = ShellRunner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "echo before-sleep; sleep 60; echo after-sleep"],
            timeout: 2
        )
        XCTAssertNotEqual(result.exitCode, 0, "timed-out process must not report success")
        XCTAssertTrue(result.stdout.contains("before-sleep"),
                      "output printed before the timeout must be preserved")
        XCTAssertFalse(result.stdout.contains("after-sleep"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testExitCodeAndEnvInheritance() {
        let result = ShellRunner.run(executable: "/bin/zsh", arguments: ["-c", "echo $HOME; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "HOME must be inherited (or backfilled) in the child env")
    }

    /// C2: cooperative cancel must terminate a long foreground shell
    /// without waiting for the full timeout.
    func testShouldCancelTerminatesChildPromptly() {
        let start = Date()
        let flag = CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            flag.cancel()
        }
        let result = ShellRunner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "echo started; sleep 60; echo never"],
            timeout: 30,
            shouldCancel: { flag.isCancelled }
        )
        XCTAssertEqual(result.exitCode, 130, "user cancel uses exit 130")
        XCTAssertTrue(result.stdout.contains("started") || result.stderr.contains("cancelled"),
                      "partial output or cancel note expected")
        XCTAssertFalse(result.stdout.contains("never"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10,
                          "cancel must not wait for the 30s timeout")
    }
}

/// Thread-safe cancel flag for ShellRunnerTests.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
}

//
//  AgentCoreFailClosedTeardown.swift
//
//  Fail-closed leftover process / Task / URLProtocol cleanup for AgentCoreTests.
//
//  Hang: `swift test --filter Agent` passed ~557 tests then stalled at
//  JobMonitorTests.testFormatElapsedHelpers (isolated JobMonitor is 4/4).
//  Prefix A–I includes BugHuntLSP / CodeNav which spawn sourcekit-lsp and
//  leave ProcessLSPTransport stderr Tasks + LSPClientSessionPool.sweepTask
//  (idle 120s). XCTest then never drains the suite.
//
//  Observer is registered from this class's `setUp` (alphabetically first
//  AgentCore* class). Per-case: URLCache only. Per-suite + bundle finish:
//  SIGTERM/SIGKILL leftover sourcekit-lsp children and reset LSP pool.
//

import Darwin
import Foundation
import XCTest
@testable import AgentCore

enum AgentCoreTestCleanup {
    /// Cheap per-test path: kill leftover LSP children, clear URL cache,
    /// fire-and-forget actor reset. Must **not** `semaphore.wait` — that
    /// deadlocks when XCTest invokes tearDown on a Swift cooperative thread.
    static func runCheap() {
        killLiveLSPProcesses()
        resetURLProtocol()
        kickActorReset()
    }

    /// Bundle-finish path: cheap cleanup plus a short poll so children die
    /// before the xctest process exits. Still no cooperative-pool wait.
    static func runSync() {
        runCheap()
        usleep(100_000)
        killLiveLSPProcesses()
    }

    static func kickActorReset() {
        Task.detached(priority: .userInitiated) {
            await CodeNavService.resetTestSeams()
            await BackgroundJobManager.shared.cleanup()
            await SubagentSessionStore.shared.resetForTests()
        }
    }

    /// SIGTERM then SIGKILL `pid`. No-op for pid ≤ 0.
    static func terminatePID(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        usleep(50_000)
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    /// Kill transports that never `close()`d, plus direct-child `sourcekit-lsp`.
    /// Does not touch Xcode's unrelated SourceKit (different parent).
    static func killLiveLSPProcesses() {
        for pid in ProcessLSPTransport.liveProcessIDs() {
            terminatePID(pid)
        }
        let selfPID = getpid()
        for pid in pgrep(name: "sourcekit-lsp", parent: selfPID) {
            terminatePID(pid)
        }
    }

    static func killDescendantSourceKitLSP() {
        killLiveLSPProcesses()
    }

    /// Suites attach MockURLProtocol via ephemeral `protocolClasses`, not
    /// `URLProtocol.registerClass`. Clear the shared cache so a leaked
    /// handler cannot replay into a later test's URLSession.shared call.
    static func resetURLProtocol() {
        URLCache.shared.removeAllCachedResponses()
    }

    private static func pgrep(name: String, parent: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", "\(parent)", "-x", name]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}

extension XCTestCase {
    /// Per-test fail-closed teardown. Also invoked by the bundle observer.
    func failClosedTearDownLeftovers() {
        AgentCoreTestCleanup.runCheap()
    }
}

extension Process {
    /// `terminate()` + unbounded `waitUntilExit()` hung GHA for ~37m when a
    /// python mock ignored SIGTERM. SIGKILL after a short wait.
    func terminateAndWait(timeout: TimeInterval = 2) {
        guard isRunning else { return }
        terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isRunning {
            kill(processIdentifier, SIGKILL)
            waitUntilExit()
        }
    }
}

/// Runs after every test regardless of whether the case called `super.tearDown()`.
final class AgentCoreFailClosedObserver: NSObject, XCTestObservation {
    static let shared = AgentCoreFailClosedObserver()
    private static let lock = NSLock()
    private static var registered = false

    static func registerOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        AgentCoreFailClosedObserver.registerOnce()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // URL cache only. Do **not** SIGKILL live LSP PIDs here: XCTest can
        // start the next case before this observer returns, and makeClient
        // then hangs on a dead sourcekit-lsp (no 12s timeout observed).
        AgentCoreTestCleanup.resetURLProtocol()
    }

    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        AgentCoreTestCleanup.runCheap()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        AgentCoreTestCleanup.runSync()
    }
}

/// Alphabetically first AgentCore* class so `class setUp` registers the
/// observer before BugHuntLSP / CodeNav spawn sourcekit-lsp.
final class AgentCoreFailClosedTeardownTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        AgentCoreFailClosedObserver.registerOnce()
    }

    override func setUp() {
        super.setUp()
        AgentCoreFailClosedObserver.registerOnce()
    }

    override func tearDown() {
        failClosedTearDownLeftovers()
        super.tearDown()
    }

    func testFailClosedCleanupIsIdempotent() {
        AgentCoreTestCleanup.runSync()
        AgentCoreTestCleanup.runSync()
    }

    func testFailClosedTerminatesTrackedChild() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        proc.standardInput = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        XCTAssertTrue(proc.isRunning)
        let pid = proc.processIdentifier
        AgentCoreTestCleanup.terminatePID(pid)
        let deadline = Date().addingTimeInterval(1)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(proc.isRunning, "terminatePID must SIGTERM/SIGKILL the child")
    }

    func testFailClosedKillsDescendantSourceKitLSP() throws {
        guard let bin = SourceKitLSPHost.resolveBinary() else {
            throw XCTSkip("sourcekit-lsp not installed")
        }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = []
        proc.standardInput = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        XCTAssertTrue(proc.isRunning, "fixture: spawned sourcekit-lsp")
        AgentCoreTestCleanup.runSync()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            if pid > 0 { kill(pid, SIGKILL) }
            XCTFail("fail-closed teardown must kill descendant sourcekit-lsp pid \(proc.processIdentifier)")
        }
    }
}

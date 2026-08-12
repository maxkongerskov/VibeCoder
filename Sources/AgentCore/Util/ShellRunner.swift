//
//  ShellRunner.swift
//
//  Tiny synchronous Process wrapper with a hard timeout. Every shell-
//  touching tool routes through this so the timeout behavior is
//  consistent. The original AgentOS had per-tool timeout logic in 5+
//  places — easy to drift.
//

import Foundation

public struct ShellResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum ShellRunner {

    /// Thread-safe byte accumulator for the pipe-drain workers.
    /// `@unchecked Sendable` — every access goes through the lock.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// - Parameters:
    ///   - shouldCancel: Optional cooperative cancel (e.g. agent turn stop).
    ///     Polled on the calling thread ~every 50ms while the child runs.
    ///     When true, the process group is SIGTERM'd then SIGKILL'd.
    public static func run(executable: String,
                           arguments: [String],
                           workingDirectory: URL? = nil,
                           timeout: TimeInterval = 60,
                           shouldCancel: (() -> Bool)? = nil) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd = workingDirectory { proc.currentDirectoryURL = cwd }
        // Inherit the parent process's environment. Without this the
        // child shell launches with an empty env — HOME is unset, so
        // zsh's `~` expansion returns "/" (root, read-only on macOS),
        // PATH is empty so unqualified commands fail, etc. Belt-and-
        // suspenders: ensure HOME is always set even if the host
        // environment somehow doesn't carry it (rare, but possible
        // when invoked from a sandboxed launchd context).
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil || env["HOME"]?.isEmpty == true {
            env["HOME"] = NSHomeDirectory()
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Put the child in its own process group so cancel can SIGTERM/SIGKILL
        // the whole tree (shell + grandchildren), not just the zsh PID.
        proc.qualityOfService = .userInitiated

        do {
            try proc.run()
        } catch {
            return ShellResult(stdout: "", stderr: "Failed to launch \(executable): \(error)", exitCode: -1)
        }

        // setpgid(child, child) so kill(-pgid) covers the tree. Best-effort:
        // if this fails we still fall back to PID kill.
        let childPid = proc.processIdentifier
        if childPid > 0 {
            _ = setpgid(childPid, childPid)
        }

        // Drain both pipes WHILE the process runs. Draining after
        // waitUntilExit deadlocks the moment a child writes more than
        // the ~64 KB pipe buffer (xcodebuild, swift build, and test
        // runners all do): the child blocks on write(2), the parent
        // blocks on exit — until the timeout watchdog kills the child
        // and the caller gets a truncated log. Incremental reads
        // (`availableData` until EOF) also mean a timed-out process
        // still returns everything it printed before termination.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let drained = DispatchGroup()
        for (pipe, box) in [(outPipe, stdoutBox), (errPipe, stderrBox)] {
            drained.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData   // blocks until data or EOF
                    if chunk.isEmpty { break }         // EOF
                    box.append(chunk)
                }
                drained.leave()
            }
        }

        // Timeout + cooperative-cancel poll on the calling thread.
        // (A global-queue watchdog cannot see Task.isCancelled of the
        // agent turn — cancel must be checked here.)
        let deadline = Date().addingTimeInterval(timeout)
        var userCancelled = false
        while proc.isRunning {
            if let shouldCancel, shouldCancel() {
                userCancelled = true
                Self.terminateProcessGroup(proc)
                break
            }
            if Date() >= deadline {
                Self.terminateProcessGroup(proc)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.waitUntilExit()
        }
        // EOF normally lands immediately after exit. The bounded wait
        // covers the pathological case of a grandchild inheriting the
        // pipe and holding it open — we return what's been read rather
        // than hanging forever.
        _ = drained.wait(timeout: .now() + 10)
        var stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
        if userCancelled {
            let note = "\n[cancelled by user — process terminated]"
            stderr = stderr.isEmpty ? note.trimmingCharacters(in: .newlines) : stderr + note
        }
        return ShellResult(
            stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
            stderr: stderr,
            exitCode: userCancelled ? 130 : proc.terminationStatus
        )
    }

    /// SIGTERM then SIGKILL. When the child is its own process-group leader
    /// (we called `setpgid(pid, pid)` after `run`), kill the whole group so
    /// shell grandchildren die. Otherwise kill only the PID — never send
    /// `kill(-pid)` into a shared process group (would nuke the host/tests).
    private static func terminateProcessGroup(_ proc: Process) {
        guard proc.isRunning else { return }
        let pid = proc.processIdentifier
        guard pid > 0 else {
            proc.terminate()
            return
        }
        let pgid = getpgid(pid)
        let isGroupLeader = (pgid == pid)
        if isGroupLeader {
            kill(-pid, SIGTERM)
        }
        proc.terminate()
        let killAt = Date().addingTimeInterval(5)
        while Date() < killAt && proc.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            if isGroupLeader {
                kill(-pid, SIGKILL)
            }
            kill(pid, SIGKILL)
        }
    }

    /// Public alias for BackgroundJobManager / tests.
    public static func forceTerminateProcess(_ proc: Process) {
        terminateProcessGroup(proc)
    }
}

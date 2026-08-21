//
//  SourceKitLSPHost.swift
//  Optional SourceKit-LSP process host. Spawns `sourcekit-lsp` when present;
//  returns nil when unavailable (CI / machines without toolchain).
//

import Darwin
import Foundation

public enum SourceKitLSPHost {
    /// Resolve sourcekit-lsp binary path, if any.
    public static func resolveBinary() -> URL? {
        let candidates = [
            "/usr/bin/sourcekit-lsp",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // `xcrun --find sourcekit-lsp`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", "sourcekit-lsp"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    public static var isAvailable: Bool { resolveBinary() != nil }

    /// Spawn a live SourceKit-LSP client for `projectRoot`, or nil.
    /// Prefer `LSPClientSessionPool.shared.client(for:)` so sessions are reused;
    /// the pool owns idle shutdown. Direct callers must still call `shutdown()`.
    public static func makeClient(projectRoot: URL) async -> LSPClient? {
        guard let bin = resolveBinary() else { return nil }
        do {
            let transport = try ProcessLSPTransport(executable: bin, arguments: [])
            let client = LSPClient(transport: transport, requestTimeoutSeconds: 12)
            try await client.initialize(rootURI: projectRoot.standardizedFileURL)
            return client
        } catch {
            return nil
        }
    }
}

/// stdio Process transport for a language server binary.
public final class ProcessLSPTransport: LSPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let lock = NSLock()
    private var closed = false
    private var stderrTask: Task<Void, Never>?

    private static let pidLock = NSLock()
    /// Guarded by `pidLock`.
    nonisolated(unsafe) private static var livePIDs: Set<pid_t> = []

    /// PIDs of transports that have not yet `close()`d. XCTest tearDown
    /// kills these so a leaked sourcekit-lsp cannot stall the suite.
    public static func liveProcessIDs() -> Set<pid_t> {
        pidLock.lock()
        defer { pidLock.unlock() }
        return livePIDs
    }

    private static func registerPID(_ pid: pid_t) {
        guard pid > 0 else { return }
        pidLock.lock()
        livePIDs.insert(pid)
        pidLock.unlock()
    }

    private static func unregisterPID(_ pid: pid_t) {
        guard pid > 0 else { return }
        pidLock.lock()
        livePIDs.remove(pid)
        pidLock.unlock()
    }

    public init(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        Self.registerPID(process.processIdentifier)

        // Read stderr in the background to prevent pipe buffer overflow.
        // macOS pipes are ~64 KB; without a reader the LSP server deadlocks.
        // Cancelled + handle-close in `close()` so this Task cannot keep
        // XCTest alive after the child dies.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrTask = Task.detached {
            while !Task.isCancelled {
                let data = (try? stderrHandle.read(upToCount: 65536)) ?? Data()
                if data.isEmpty { break }
            }
        }
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stderrTask = stderrTask
    }

    public func write(_ data: Data) async throws {
        // NSLock is unavailable in async contexts under Swift 6 — hop to a
        // cooperative queue before taking the lock.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.closed {
                    cont.resume(throwing: LSPError.transportClosed)
                    return
                }
                do {
                    try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func read() async throws -> Data {
        // Blocking read on a cooperative thread.
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                let closed = self.closed
                self.lock.unlock()
                if closed {
                    cont.resume(returning: Data())
                    return
                }
                let data = self.stdoutPipe.fileHandleForReading.availableData
                cont.resume(returning: data)
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.lock.lock()
                self.closed = true
                let task = self.stderrTask
                self.stderrTask = nil
                self.lock.unlock()
                try? self.stdinPipe.fileHandleForWriting.close()
                try? self.stdoutPipe.fileHandleForReading.close()
                try? self.stderrPipe.fileHandleForReading.close()
                task?.cancel()
                let pid = self.process.processIdentifier
                if self.process.isRunning {
                    self.process.terminate()
                }
                if self.process.isRunning, pid > 0 {
                    kill(pid, SIGKILL)
                }
                Self.unregisterPID(pid)
                cont.resume()
            }
        }
    }

    deinit {
        stderrTask?.cancel()
        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        Self.unregisterPID(pid)
    }
}

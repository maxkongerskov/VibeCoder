//
//  SourceKitLSPHost.swift
//  Optional SourceKit-LSP process host. Spawns `sourcekit-lsp` when present;
//  returns nil when unavailable (CI / machines without toolchain).
//

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
    private let lock = NSLock()
    private var closed = false

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

        // Read stderr in the background to prevent pipe buffer overflow.
        // macOS pipes are ~64 KB; without a reader the LSP server deadlocks.
        Task.detached {
            for handle in [stderrPipe.fileHandleForReading] {
                while let data = try? handle.read(upToCount: 65536), !data.isEmpty {
                    // Discard LSP server logs (written to diagnostics).
                }
            }
        }
        try process.run()
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
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
                self.lock.unlock()
                try? self.stdinPipe.fileHandleForWriting.close()
                if self.process.isRunning {
                    self.process.terminate()
                }
                cont.resume()
            }
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }
}

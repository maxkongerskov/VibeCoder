//
//  MCPStdioClient.swift
//
//  Minimal JSON-RPC 2.0 client over a subprocess stdio transport.
//  Speaks the Model Context Protocol to Apple's `mcpbridge` binary
//  (shipped with Xcode 26.3+). Deliberately dependency-free — the
//  official swift-sdk targets Swift 6; AgentOS stays on 5.10.
//

import Foundation

public enum MCPClientError: Error, LocalizedError, Sendable {
    case notConnected
    case processLaunchFailed(String)
    case processExited(code: Int32)
    case invalidResponse(String)
    case serverError(code: Int, message: String)
    case timeout(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP client is not connected"
        case .processLaunchFailed(let s): return "Failed to launch MCP bridge: \(s)"
        case .processExited(let code): return "MCP bridge process exited (code \(code))"
        case .invalidResponse(let s): return "Invalid MCP response: \(s)"
        case .serverError(_, let message): return message
        case .timeout(let s): return "MCP request timed out: \(s)"
        case .encodingFailed: return "Failed to encode MCP request"
        }
    }
}

/// Events forwarded from the stdout pump — `Sendable` so the readability
/// handler never captures the actor.
private enum MCPReadEvent: Sendable {
    case chunk(String)
    case ended(exitCode: Int32)
}

/// Mutable leftover bytes for the stdout pump. `@unchecked Sendable` because
/// `FileHandle.readabilityHandler` is invoked on a serial queue.
private final class MCPUTF8Leftover: @unchecked Sendable {
    var data = Data()
}

/// JSON-RPC result payload. `[String: Any]` is not `Sendable`; this box
/// is safe because the dictionary is freshly parsed JSON owned by one caller.
public struct MCPJSONPayload: @unchecked Sendable {
    public let value: [String: Any]

    public init(value: [String: Any]) {
        self.value = value
    }
}

/// Low-level stdio MCP session. One instance per `mcpbridge` process.
public actor MCPStdioClient {

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var lineBuffer = ""
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<MCPJSONPayload, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private(set) var isConnected = false
    /// Bumps on every connect/disconnect so a stale stdout loop from a
    /// previous process cannot clear `isConnected` on the new session
    /// (classic race → "MCP client is not connected" during handshake).
    private var connectionGeneration: UInt64 = 0

    public init() {}

    deinit {
        readTask?.cancel()
        process?.terminate()
    }

    /// Spawn `executable` and complete the MCP initialize handshake.
    ///
    /// - Parameter env: Optional environment overrides. Keys present here
    ///   are merged into the parent process environment (existing keys
    ///   overwritten, new keys added). nil = inherit parent env entirely.
    public func connect(executable: URL, arguments: [String] = [],
                        clientName: String = AppBranding.displayName,
                        clientVersion: String = AgentCore.version,
                        env: [String: String]? = nil) async throws {
        // Tear down any prior session and wait for its read loop to exit
        // so EOF from the old process cannot race the new handshake.
        await teardownSession(failPendingWith: MCPClientError.notConnected)

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments

        // Apply env overrides: merge with parent environment.
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            proc.environment = merged
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Drain stderr to /dev/null so a chatty bridge cannot fill a
        // unread Pipe and block/die mid-handshake.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw MCPClientError.processLaunchFailed(error.localizedDescription)
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        isConnected = true
        lineBuffer = ""
        nextID = 1

        startReadLoop(
            stdout: stdoutPipe.fileHandleForReading,
            process: proc,
            generation: generation
        )

        // Brief yield so the child can open its end of the pipes before
        // we write initialize (reduces races on cold launch).
        try? await Task.sleep(nanoseconds: 30_000_000)

        guard isConnected, connectionGeneration == generation, proc.isRunning else {
            await teardownSession(failPendingWith: MCPClientError.processExited(code: proc.terminationStatus))
            throw MCPClientError.processExited(code: proc.terminationStatus)
        }

        let initParams: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": clientName,
                "version": clientVersion,
            ],
        ]
        do {
            _ = try await request(method: "initialize", params: initParams, timeout: 30)
            try notify(method: "notifications/initialized", params: [:])
        } catch {
            await teardownSession(failPendingWith: error)
            throw error
        }
    }

    public func disconnect() {
        // Sync path for callers; invalidate generation immediately so any
        // in-flight read loop becomes a no-op, then tear down handles.
        connectionGeneration &+= 1
        hardCloseHandles(failPendingWith: MCPClientError.notConnected)
    }

    /// Async teardown that waits for the read loop to finish (preferred
    /// before a new connect).
    public func teardownSession(failPendingWith error: Error) async {
        connectionGeneration &+= 1
        let task = readTask
        hardCloseHandles(failPendingWith: error)
        if let task {
            // Bound wait so a stuck readability handler cannot hang reconnect.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func hardCloseHandles(failPendingWith error: Error) {
        readTask?.cancel()
        readTask = nil
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
        stdinHandle?.closeFile()
        stdinHandle = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        lineBuffer = ""
        isConnected = false
    }

    public func request(method: String, params: [String: Any],
                        timeout seconds: TimeInterval = 120) async throws -> MCPJSONPayload {
        guard isConnected, stdinHandle != nil else {
            throw MCPClientError.notConnected
        }
        let id = nextID
        nextID += 1

        let requestLine: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        try writePayload(requestLine)

        let response = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            let sleepNanos = UInt64(seconds * 1_000_000_000)
            timeoutTasks[id] = Task {
                try? await Task.sleep(nanoseconds: sleepNanos)
                await self.timeoutPendingRequest(id: id, method: method)
            }
        }
        return response
    }

    /// Drop a still-pending request after the deadline. Yields once so
    /// callers crossing actor boundaries get a real suspension point.
    private func timeoutPendingRequest(id: Int, method: String) async {
        await Task.yield()
        timeoutTasks.removeValue(forKey: id)
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: MCPClientError.timeout(method))
    }

    public func notify(method: String, params: [String: Any]) throws {
        guard isConnected, stdinHandle != nil else {
            throw MCPClientError.notConnected
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        try writePayload(payload)
    }

    /// True when the subprocess is still alive and the client thinks it is connected.
    public func isHealthy() -> Bool {
        isConnected && (process?.isRunning == true) && stdinHandle != nil
    }

    // MARK: - Transport

    private func writePayload(_ payload: [String: Any]) throws {
        guard let stdin = stdinHandle else { throw MCPClientError.notConnected }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { throw MCPClientError.encodingFailed }
        line.append("\n")
        guard let out = line.data(using: .utf8) else { throw MCPClientError.encodingFailed }
        try stdin.write(contentsOf: out)
    }

    private func startReadLoop(stdout: FileHandle, process: Process, generation: UInt64) {
        let fd = stdout.fileDescriptor
        readTask = Task {
            let events = Self.makeStdoutEventStream(fileDescriptor: fd, process: process)
            for await event in events {
                switch event {
                case .chunk(let text):
                    // Non-async actor methods — no `await` (Swift 6 warning).
                    ingest(text, generation: generation)
                case .ended(let code):
                    handleProcessEnded(exitCode: code, generation: generation)
                    return
                }
            }
        }
    }

    /// Bridge stdout readability callbacks into an `AsyncStream` so the
    /// handler closure never captures `self` (Swift 6 concurrency-safe).
    private static func makeStdoutEventStream(fileDescriptor: Int32,
                                              process: Process)
    -> AsyncStream<MCPReadEvent> {
        AsyncStream { continuation in
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            // Incomplete UTF-8 at a kernel-chunk boundary is held here until
            // the rest of the sequence arrives. Decoding each `availableData`
            // with `String(data:encoding:.utf8)` would drop those responses.
            let leftover = MCPUTF8Leftover()
            handle.readabilityHandler = { source in
                let chunk = source.availableData
                if chunk.isEmpty {
                    source.readabilityHandler = nil
                    let code = process.isRunning ? 0 : process.terminationStatus
                    continuation.yield(.ended(exitCode: code))
                    continuation.finish()
                    return
                }
                leftover.data.append(chunk)
                if let text = decodeUTF8Prefix(from: &leftover.data), !text.isEmpty {
                    continuation.yield(.chunk(text))
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    /// Decode complete UTF-8 from `buffer`, leaving a trailing incomplete
    /// multi-byte sequence (at most 3 bytes) for the next read.
    private static func decodeUTF8Prefix(from buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }
        if let text = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return text
        }
        let count = buffer.count
        let maxLookback = min(3, count)
        for drop in 1...maxLookback {
            let keep = count - drop
            if let text = String(data: buffer.prefix(keep), encoding: .utf8) {
                buffer.removeFirst(keep)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    private func handleProcessEnded(exitCode: Int32, generation: UInt64) {
        // Ignore EOF from a previous connection generation.
        guard generation == connectionGeneration else { return }
        isConnected = false
        stdinHandle = nil
        process = nil
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: MCPClientError.processExited(code: exitCode))
        }
        pending.removeAll()
    }

    private func ingest(_ text: String, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        lineBuffer.append(text)
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            dispatchLine(trimmed)
        }
    }

    private func dispatchLine(_ line: String) {
        switch MCPJSONRPCParser.parse(line: line) {
        case .none:
            return
        case .success(let id, let payload):
            fulfillRequest(id: id, result: .success(MCPJSONPayload(value: payload)))
        case .failure(let id, let error):
            fulfillRequest(id: id, result: .failure(error))
        }
    }

    private func fulfillRequest(id: Int, result: Result<MCPJSONPayload, Error>) {
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        guard let cont = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let payload):
            cont.resume(returning: payload)
        case .failure(let error):
            cont.resume(throwing: error)
        }
    }

}

// MARK: - JSON-RPC line parsing (testable)

enum MCPJSONRPCParser {
    enum Parsed {
        case success(id: Int, payload: [String: Any])
        case failure(id: Int, error: MCPClientError)
    }

    static func parse(line: String) -> Parsed? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = json["error"] as? [String: Any] {
            guard let id = coerceID(json["id"]) else { return nil }
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown MCP error"
            return .failure(id: id, error: .serverError(code: code, message: message))
        }

        guard let id = coerceID(json["id"]) else { return nil }

        if let result = json["result"] as? [String: Any] {
            return .success(id: id, payload: result)
        }
        return .failure(id: id, error: .invalidResponse("Missing result for id \(id)"))
    }

    /// JSON-RPC 2.0 ids may be number or string. We allocate Int ids, so
    /// coerce string echoes (`"id":"1"`) back to Int so waiters still match.
    static func coerceID(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(exactly: d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

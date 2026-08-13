//
//  LSPClient.swift
//  JSON-RPC 2.0 client over Content-Length framed transport.
//

import Foundation

public enum LSPError: Error, Sendable, Equatable {
    case transportClosed
    case notInitialized
    case timeout
    case serverError(code: Int, message: String)
    case invalidResponse(String)
    case unavailable(String)
}

/// JSON-RPC object boxed for cross-task hops (`[String: Any]` is not Sendable).
private struct JSONObject: @unchecked Sendable {
    let dict: [String: Any]
}

/// Continuation wrapper that resumes at most once. Timeout `failPending`
/// and a later `transport.write` throw must not double-resume.
private final class OneShotContinuation: @unchecked Sendable {
    private let continuation: CheckedContinuation<JSONObject, Error>
    private var didResume = false

    init(_ continuation: CheckedContinuation<JSONObject, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: JSONObject) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}

/// Thin LSP JSON-RPC client. Supports initialize, definition, references,
/// workspace/symbol, didOpen/didChange/didSave. Not a full multi-language
/// IDE host — honest partial bridge for SourceKit (or mock) sessions.
public actor LSPClient {
    private let transport: any LSPTransport
    private var nextId = 1
    private var pending: [Int: OneShotContinuation] = [:]
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var initialized = false
    private let requestTimeoutNs: UInt64
    /// Open documents: uri → version + last synced text.
    private var openDocs: [String: OpenDocument] = [:]
    /// Monotonic open/change counter for tests (didOpen + didChange events).
    private(set) public var documentSyncEventCount: Int = 0

    private struct OpenDocument {
        var version: Int
        var text: String
    }

    public init(transport: any LSPTransport, requestTimeoutSeconds: Double = 8) {
        self.transport = transport
        self.requestTimeoutNs = UInt64(max(1, requestTimeoutSeconds) * 1_000_000_000)
    }

    /// Stable identity for pool reuse tests (actor instance).
    public nonisolated var objectID: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task {
            await self.readLoop()
        }
    }

    public func shutdown() async {
        readTask?.cancel()
        readTask = nil
        if initialized {
            // Best-effort exit notification only — do not await a `shutdown`
            // RPC reply (idle eviction and tests must not hang on missing response).
            try? await notify(method: "exit", params: nil)
        }
        await transport.close()
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: LSPError.transportClosed)
        }
        initialized = false
        openDocs.removeAll()
    }

    public var isInitialized: Bool { initialized }

    public var openDocumentCount: Int { openDocs.count }

    public func initialize(rootURI: URL, processId: Int? = nil) async throws {
        start()
        let root = rootURI.absoluteString
        var params: [String: Any] = [
            "rootUri": root,
            "capabilities": [
                "textDocument": [
                    "definition": ["linkSupport": true],
                    "references": [String: Any](),
                ],
                "workspace": [
                    "symbol": [String: Any](),
                ],
            ],
            "clientInfo": [
                "name": "VibeCoder",
                "version": "1.0",
            ],
        ]
        if let processId {
            params["processId"] = processId
        } else {
            params["processId"] = NSNull()
        }
        _ = try await request(method: "initialize", params: params)
        try await notify(method: "initialized", params: [String: Any]())
        initialized = true
    }

    // MARK: - High-level nav

    /// textDocument/definition — 0-based line/character.
    public func definition(file: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        try ensureReady()
        try await ensureDocumentSynced(file: file)
        let params: [String: Any] = [
            "textDocument": ["uri": file.standardizedFileURL.absoluteString],
            "position": ["line": line, "character": character],
        ]
        let result = try await request(method: "textDocument/definition", params: params)
        return Self.parseLocations(result)
    }

    /// textDocument/references — 0-based line/character.
    public func references(file: URL, line: Int, character: Int, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        try ensureReady()
        try await ensureDocumentSynced(file: file)
        let params: [String: Any] = [
            "textDocument": ["uri": file.standardizedFileURL.absoluteString],
            "position": ["line": line, "character": character],
            "context": ["includeDeclaration": includeDeclaration],
        ]
        let result = try await request(method: "textDocument/references", params: params)
        return Self.parseLocations(result)
    }

    /// Notify the server that a file changed (full-text didChange).
    /// Used by the session pool when the agent edits files between nav calls.
    public func notifyDocumentDidChange(file: URL, text: String) async throws {
        try ensureReady()
        try await applyDocumentText(file: file, text: text, force: true)
    }

    /// textDocument/didSave (optional; some servers refresh on save).
    public func notifyDocumentDidSave(file: URL, text: String? = nil) async throws {
        try ensureReady()
        try await ensureDocumentSynced(file: file, overrideText: text)
        var params: [String: Any] = [
            "textDocument": ["uri": file.standardizedFileURL.absoluteString],
        ]
        if let text {
            params["text"] = text
        }
        try await notify(method: "textDocument/didSave", params: params)
    }

    /// workspace/symbol
    public func workspaceSymbol(query: String) async throws -> [LSPSymbolInformation] {
        try ensureReady()
        let result = try await request(
            method: "workspace/symbol",
            params: ["query": query]
        )
        return Self.parseSymbolInformation(result)
    }

    // MARK: - Wire

    private func ensureReady() throws {
        guard initialized else { throw LSPError.notInitialized }
    }

    /// Sync document from disk (or override) via didOpen / didChange.
    private func ensureDocumentSynced(file: URL, overrideText: String? = nil) async throws {
        let text = overrideText ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try await applyDocumentText(file: file, text: text, force: false)
    }

    private func applyDocumentText(file: URL, text: String, force: Bool) async throws {
        let uri = file.standardizedFileURL.absoluteString
        if let existing = openDocs[uri] {
            if !force && existing.text == text { return }
            let newVersion = existing.version + 1
            let params: [String: Any] = [
                "textDocument": [
                    "uri": uri,
                    "version": newVersion,
                ],
                // Full-document sync (TextDocumentSyncKind.Full).
                "contentChanges": [
                    ["text": text],
                ],
            ]
            try await notify(method: "textDocument/didChange", params: params)
            openDocs[uri] = OpenDocument(version: newVersion, text: text)
            documentSyncEventCount += 1
        } else {
            let lang = languageId(for: file)
            let params: [String: Any] = [
                "textDocument": [
                    "uri": uri,
                    "languageId": lang,
                    "version": 1,
                    "text": text,
                ],
            ]
            try await notify(method: "textDocument/didOpen", params: params)
            openDocs[uri] = OpenDocument(version: 1, text: text)
            documentSyncEventCount += 1
        }
    }

    private func languageId(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "swift": return "swift"
        case "m", "h": return "objective-c"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        default: return "plaintext"
        }
    }

    private func request(method: String, params: [String: Any]?) async throws -> Any? {
        let id = nextId
        nextId += 1
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            msg["params"] = params
        }
        let body = try JSONSerialization.data(withJSONObject: msg, options: [])
        let framed = LSPFraming.encode(body)

        // Register pending *before* write so a fast mock response cannot race.
        let responseBox: JSONObject = try await withThrowingTaskGroup(of: JSONObject.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONObject, Error>) in
                    Task {
                        await self.sendRequest(id: id, framed: framed, cont: cont)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.requestTimeoutNs)
                await self.failPending(id: id, error: LSPError.timeout)
                throw LSPError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let response = responseBox.dict

        if let error = response["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown"
            throw LSPError.serverError(code: code, message: message)
        }
        return response["result"]
    }

    private func sendRequest(
        id: Int,
        framed: Data,
        cont: CheckedContinuation<JSONObject, Error>
    ) async {
        let oneShot = OneShotContinuation(cont)
        pending[id] = oneShot
        do {
            try await transport.write(framed)
        } catch {
            pending.removeValue(forKey: id)
            oneShot.resume(throwing: error)
        }
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func notify(method: String, params: [String: Any]?) async throws {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            msg["params"] = params
        }
        let body = try JSONSerialization.data(withJSONObject: msg, options: [])
        try await transport.write(LSPFraming.encode(body))
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let chunk = try await transport.read()
                if chunk.isEmpty { break }
                buffer.append(chunk)
                let messages = LSPFraming.decode(buffer: &buffer)
                for raw in messages {
                    handleMessage(raw)
                }
            } catch {
                break
            }
        }
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: LSPError.transportClosed)
        }
    }

    private func handleMessage(_ raw: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return }
        // Response (has id, no method)
        if let id = obj["id"] as? Int, obj["method"] == nil {
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: JSONObject(dict: obj))
            }
            return
        }
        // Notifications / server requests ignored for this partial host.
    }

    // MARK: - Parse helpers

    public static func parseLocations(_ result: Any?) -> [LSPLocation] {
        guard let result else { return [] }
        if let dict = result as? [String: Any], let loc = LSPLocation(dict: dict) {
            return [loc]
        }
        if let arr = result as? [[String: Any]] {
            return arr.compactMap { LSPLocation(dict: $0) }
        }
        return []
    }

    public static func parseSymbolInformation(_ result: Any?) -> [LSPSymbolInformation] {
        guard let arr = result as? [[String: Any]] else { return [] }
        return arr.compactMap { LSPSymbolInformation(dict: $0) }
    }
}

public struct LSPLocation: Sendable, Equatable {
    public var uri: String
    /// 0-based line
    public var line: Int
    /// 0-based character
    public var character: Int

    public init(uri: String, line: Int, character: Int) {
        self.uri = uri
        self.line = line
        self.character = character
    }

    public init?(dict: [String: Any]) {
        // Location: { uri, range: { start: { line, character } } }
        if let uri = dict["uri"] as? String {
            let range = dict["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            self.uri = uri
            self.line = (start?["line"] as? Int) ?? 0
            self.character = (start?["character"] as? Int) ?? 0
            return
        }
        // LocationLink
        if let uri = dict["targetUri"] as? String {
            let range = dict["targetSelectionRange"] as? [String: Any]
                ?? dict["targetRange"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            self.uri = uri
            self.line = (start?["line"] as? Int) ?? 0
            self.character = (start?["character"] as? Int) ?? 0
            return
        }
        return nil
    }

    public var fileURL: URL? {
        URL(string: uri)
    }

    /// 1-based line for tool output.
    public var displayLine: Int { line + 1 }
}

public struct LSPSymbolInformation: Sendable, Equatable {
    public var name: String
    public var kind: Int
    public var location: LSPLocation

    public init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String else { return nil }
        self.name = name
        self.kind = (dict["kind"] as? Int) ?? 0
        if let locDict = dict["location"] as? [String: Any],
           let loc = LSPLocation(dict: locDict) {
            self.location = loc
        } else if let loc = LSPLocation(dict: dict) {
            self.location = loc
        } else {
            return nil
        }
    }
}

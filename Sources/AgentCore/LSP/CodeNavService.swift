//
//  CodeNavService.swift
//  High-level code navigation: LSP when available, SymbolIndex fallback.
//

import Foundation

public enum CodeNavAction: String, Sendable, CaseIterable {
    case definition
    case references
    case workspaceSymbol = "workspace_symbol"

    public static func parse(_ raw: String?) -> CodeNavAction {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return .workspaceSymbol
        }
        switch raw {
        case "definition", "def", "goto_definition", "go_to_definition":
            return .definition
        case "references", "refs", "find_references":
            return .references
        case "workspace_symbol", "workspace-symbol", "symbol", "search":
            return .workspaceSymbol
        default:
            return .workspaceSymbol
        }
    }
}

public struct CodeNavHit: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var snippet: String
    public var source: Source

    public enum Source: String, Sendable {
        case lsp
        case textIndex = "text-index"
    }

    public init(path: String, line: Int, snippet: String, source: Source) {
        self.path = path
        self.line = line
        self.snippet = snippet
        self.source = source
    }
}

/// Backend label for user/tool-facing output. Only these two values are
/// ever emitted — never a hybrid marketing string.
public enum CodeNavBackend: String, Sendable, Equatable {
    case lsp = "lsp"
    case textIndex = "text-index"
}

public struct CodeNavResult: Sendable {
    public var action: CodeNavAction
    public var hits: [CodeNavHit]
    public var backend: CodeNavBackend
    public var note: String?

    public init(action: CodeNavAction, hits: [CodeNavHit], backend: CodeNavBackend, note: String? = nil) {
        self.action = action
        self.hits = hits
        self.backend = backend
        self.note = note
    }

    /// Short honesty line for models/users (always present in tool output).
    public static let honestyLine =
        "honesty: Not full IDE navigation. backend=lsp means SourceKit-LSP answered; backend=text-index is a SymbolIndex substring scan (not semantic)."

    /// Canonical tool-facing text: always includes `backend: lsp|text-index`.
    public func formatToolOutput(symbol: String) -> String {
        var lines: [String] = []
        if hits.isEmpty {
            lines.append("No hits for \(symbol)")
        } else {
            lines.append("# Symbol hits for \(symbol)")
        }
        lines.append("action: \(action.rawValue)")
        lines.append("backend: \(backend.rawValue)")
        lines.append(Self.honestyLine)
        if let note, !note.isEmpty {
            lines.append("note: \(note)")
        }
        if !hits.isEmpty {
            lines.append("")
            for h in hits {
                lines.append("\(h.path):\(h.line): [\(h.source.rawValue)] \(h.snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Coordinates optional LSP client with SymbolIndex fallback.
/// LSP sessions are **pooled** per project root (`LSPClientSessionPool`) —
/// not spawn-per-call. Still not a full multi-language IDE host.
public enum CodeNavService {
    /// Test seam: when set, used as pool factory instead of SourceKit-LSP.
    /// Marked nonisolated(unsafe) for XCTest injection only — not concurrent production use.
    nonisolated(unsafe) public static var testClientProvider: (@Sendable (URL) async -> LSPClient?)?

    /// Test seam: force fallback path (ignore LSP entirely).
    nonisolated(unsafe) public static var forceTextIndexOnly: Bool = false

    public static func resetTestSeams() async {
        testClientProvider = nil
        forceTextIndexOnly = false
        await LSPClientSessionPool.shared.resetForTests()
    }

    /// Notify pooled LSP that a file was edited (didChange). No-op if no session.
    public static func notifyFileEdited(
        projectRoot: URL,
        filePath: String,
        content: String? = nil
    ) async {
        let root = projectRoot.standardizedFileURL
        let file: URL
        if filePath.hasPrefix("/") {
            file = URL(fileURLWithPath: filePath)
        } else {
            file = root.appendingPathComponent(filePath)
        }
        await LSPClientSessionPool.shared.notifyFileChanged(
            projectRoot: root,
            file: file.standardizedFileURL,
            content: content
        )
    }

    public static func navigate(
        action: CodeNavAction,
        symbol: String,
        projectRoot: URL,
        filePath: String?,
        line: Int?,
        character: Int?,
        maxResults: Int
    ) async -> CodeNavResult {
        let root = projectRoot.standardizedFileURL
        let max = max(1, min(50, maxResults))

        if !forceTextIndexOnly {
            if let client = await resolveClient(projectRoot: root) {
                // Do NOT shutdown after each call — pool owns lifecycle + idle eviction.
                do {
                    switch action {
                    case .definition:
                        if let hits = try await lspDefinition(
                            client: client,
                            root: root,
                            filePath: filePath,
                            line: line,
                            character: character,
                            symbol: symbol,
                            max: max
                        ) {
                            return CodeNavResult(
                                action: action,
                                hits: hits,
                                backend: .lsp,
                                note: "textDocument/definition via pooled SourceKit-LSP session"
                            )
                        }
                    case .references:
                        if let hits = try await lspReferences(
                            client: client,
                            root: root,
                            filePath: filePath,
                            line: line,
                            character: character,
                            symbol: symbol,
                            max: max
                        ) {
                            return CodeNavResult(
                                action: action,
                                hits: hits,
                                backend: .lsp,
                                note: "textDocument/references via pooled SourceKit-LSP session"
                            )
                        }
                    case .workspaceSymbol:
                        let symbols = try await client.workspaceSymbol(query: symbol)
                        if !symbols.isEmpty {
                            let hits = symbols.prefix(max).map { sym -> CodeNavHit in
                                let path = pathFromURI(sym.location.uri) ?? sym.location.uri
                                let snip = snippetAt(path: path, line1: sym.location.displayLine)
                                    ?? sym.name
                                return CodeNavHit(
                                    path: path,
                                    line: sym.location.displayLine,
                                    snippet: snip,
                                    source: .lsp
                                )
                            }
                            return CodeNavResult(
                                action: action,
                                hits: Array(hits),
                                backend: .lsp,
                                note: "workspace/symbol via pooled SourceKit-LSP session"
                            )
                        }
                    }
                } catch {
                    // Fall through to text index; still a single backend label.
                    let fallback = textFallback(
                        action: action,
                        symbol: symbol,
                        root: root,
                        max: max
                    )
                    return CodeNavResult(
                        action: action,
                        hits: fallback,
                        backend: .textIndex,
                        note: "LSP request failed (\(error)); results are text-index only"
                    )
                }
            }
        }

        let hits = textFallback(action: action, symbol: symbol, root: root, max: max)
        return CodeNavResult(
            action: action,
            hits: hits,
            backend: .textIndex,
            note: forceTextIndexOnly
                ? "text-index forced (test seam)"
                : "SourceKit-LSP unavailable, no position for def/refs, or empty LSP result; SymbolIndex text scan"
        )
    }

    // MARK: - Internals

    private static func resolveClient(projectRoot: URL) async -> LSPClient? {
        // Install test factory on the shared pool when present so sequential
        // navigate() calls reuse the same mock client (D2 acceptance).
        if let provider = testClientProvider {
            await LSPClientSessionPool.shared.setClientFactory(provider)
        }
        return await LSPClientSessionPool.shared.client(for: projectRoot)
    }

    private static func resolveFileURL(filePath: String?, root: URL) -> URL? {
        guard let filePath, !filePath.isEmpty else { return nil }
        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath).standardizedFileURL
        }
        return root.appendingPathComponent(filePath).standardizedFileURL
    }

    /// Prefer explicit path+line; else first text hit for symbol as position.
    private static func resolvePosition(
        root: URL,
        filePath: String?,
        line: Int?,
        character: Int?,
        symbol: String
    ) -> (URL, Int, Int)? {
        if let url = resolveFileURL(filePath: filePath, root: root),
           let line1 = line, line1 >= 1 {
            // Tool API is 1-based line; character 0-based (default 0).
            let char = max(0, character ?? 0)
            return (url, line1 - 1, char)
        }
        // Infer from text index: first hit of symbol.
        let hits = SymbolIndex.find(symbol: symbol, projectRoot: root, maxResults: 1)
        guard let first = hits.first else { return nil }
        let url = URL(fileURLWithPath: first.path)
        // LSP character is UTF-16 on the raw line, including leading indent.
        // Do not use the trimmed snippet or Swift Character distance.
        let col = utf16Column(of: symbol, inFile: first.path, line1: first.line)
        return (url, max(0, first.line - 1), max(0, col))
    }

    /// 0-based UTF-16 offset of `symbol` on the untrimmed source line.
    private static func utf16Column(of symbol: String, inFile path: String, line1: Int) -> Int {
        guard line1 >= 1,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line1 <= lines.count else { return 0 }
        let raw = String(lines[line1 - 1])
        guard let range = raw.range(of: symbol) else { return 0 }
        return raw.utf16.distance(from: raw.startIndex, to: range.lowerBound)
    }

    private static func lspDefinition(
        client: LSPClient,
        root: URL,
        filePath: String?,
        line: Int?,
        character: Int?,
        symbol: String,
        max: Int
    ) async throws -> [CodeNavHit]? {
        guard let (url, line0, char0) = resolvePosition(
            root: root, filePath: filePath, line: line, character: character, symbol: symbol
        ) else { return nil }
        let locs = try await client.definition(file: url, line: line0, character: char0)
        if locs.isEmpty { return nil }
        return locs.prefix(max).map { loc in
            let path = pathFromURI(loc.uri) ?? loc.uri
            let snip = snippetAt(path: path, line1: loc.displayLine) ?? ""
            return CodeNavHit(path: path, line: loc.displayLine, snippet: snip, source: .lsp)
        }
    }

    private static func lspReferences(
        client: LSPClient,
        root: URL,
        filePath: String?,
        line: Int?,
        character: Int?,
        symbol: String,
        max: Int
    ) async throws -> [CodeNavHit]? {
        guard let (url, line0, char0) = resolvePosition(
            root: root, filePath: filePath, line: line, character: character, symbol: symbol
        ) else { return nil }
        let locs = try await client.references(file: url, line: line0, character: char0)
        if locs.isEmpty { return nil }
        return locs.prefix(max).map { loc in
            let path = pathFromURI(loc.uri) ?? loc.uri
            let snip = snippetAt(path: path, line1: loc.displayLine) ?? ""
            return CodeNavHit(path: path, line: loc.displayLine, snippet: snip, source: .lsp)
        }
    }

    private static func textFallback(
        action: CodeNavAction,
        symbol: String,
        root: URL,
        max: Int
    ) -> [CodeNavHit] {
        // Prefer definition-looking lines when action is definition.
        let raw = SymbolIndex.find(symbol: symbol, projectRoot: root, maxResults: max * 2)
        let ranked: [SymbolHit]
        if action == .definition {
            ranked = raw.sorted { a, b in
                definitionScore(a.snippet, symbol: symbol) > definitionScore(b.snippet, symbol: symbol)
            }
        } else {
            ranked = raw
        }
        return ranked.prefix(max).map {
            CodeNavHit(path: $0.path, line: $0.line, snippet: $0.snippet, source: .textIndex)
        }
    }

    private static func definitionScore(_ snippet: String, symbol: String) -> Int {
        let s = snippet.trimmingCharacters(in: .whitespaces)
        var score = 0
        let keywords = ["func ", "class ", "struct ", "enum ", "protocol ", "actor ", "typealias ", "var ", "let "]
        for k in keywords where s.contains(k + symbol) || s.contains(k) && s.contains(symbol) {
            score += 10
        }
        if s.contains("func \(symbol)") || s.contains("struct \(symbol)")
            || s.contains("class \(symbol)") || s.contains("enum \(symbol)")
            || s.contains("protocol \(symbol)") {
            score += 20
        }
        return score
    }

    private static func pathFromURI(_ uri: String) -> String? {
        guard let url = URL(string: uri) else { return nil }
        if url.isFileURL { return url.standardizedFileURL.path }
        return nil
    }

    private static func snippetAt(path: String, line1: Int) -> String? {
        guard line1 >= 1,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line1 <= lines.count else { return nil }
        return String(lines[line1 - 1]).trimmingCharacters(in: .whitespaces)
    }
}

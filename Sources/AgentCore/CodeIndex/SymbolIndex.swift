//
//  SymbolIndex.swift
//  Lightweight path/symbol index for code nav (Grok codebase-graph lite).
//

import Foundation

public struct SymbolHit: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var snippet: String
    public init(path: String, line: Int, snippet: String) {
        self.path = path
        self.line = line
        self.snippet = snippet
    }
}

public enum SymbolIndex {

    /// Grep-like symbol search under project root (no LSP required).
    public static func find(
        symbol: String,
        projectRoot: URL,
        maxResults: Int = 20
    ) -> [SymbolHit] {
        let needle = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !needle.contains("..") else { return [] }
        var hits: [SymbolHit] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let exts: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "m", "h"]
        for case let url as URL in enumerator {
            if hits.count >= maxResults { break }
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.path
            if path.contains("/.build/") || path.contains("/node_modules/")
                || path.contains("/DerivedData/") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lineNo = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNo += 1
                if line.contains(needle) {
                    hits.append(SymbolHit(
                        path: url.path,
                        line: lineNo,
                        snippet: String(line).trimmingCharacters(in: .whitespaces)))
                    if hits.count >= maxResults { break }
                }
            }
        }
        return hits
    }
}

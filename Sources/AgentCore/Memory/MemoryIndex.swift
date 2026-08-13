//
//  MemoryIndex.swift
//  Chunk store + keyword (FTS-style) hybrid search without sqlite-vec.
//

import Foundation

public struct MemoryChunk: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var source: String
    public var text: String
    public var startLine: Int
    public var endLine: Int
    public var createdAt: TimeInterval

    public init(id: String = UUID().uuidString,
                path: String,
                source: String,
                text: String,
                startLine: Int = 1,
                endLine: Int = 1,
                createdAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.path = path
        self.source = source
        self.text = text
        self.startLine = startLine
        self.endLine = endLine
        self.createdAt = createdAt
    }
}

public struct MemorySearchHit: Sendable, Equatable {
    public var chunk: MemoryChunk
    public var score: Double
    public var snippet: String
    public init(chunk: MemoryChunk, score: Double, snippet: String) {
        self.chunk = chunk
        self.score = score
        self.snippet = snippet
    }
}

public final class MemoryIndex: @unchecked Sendable {
    private let indexURL: URL
    private var chunks: [MemoryChunk] = []
    private let lock = NSLock()

    public init(indexURL: URL) {
        self.indexURL = indexURL
        load()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return chunks.count
    }

    public func allChunks() -> [MemoryChunk] {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }

    public func upsert(_ chunk: MemoryChunk) {
        lock.lock()
        if let i = chunks.firstIndex(where: { $0.id == chunk.id }) {
            chunks[i] = chunk
        } else {
            chunks.append(chunk)
        }
        let snapshot = chunks
        lock.unlock()
        persist(snapshot)
    }

    public func upsertMany(_ newChunks: [MemoryChunk]) {
        lock.lock()
        for c in newChunks {
            if let i = chunks.firstIndex(where: { $0.id == c.id }) {
                chunks[i] = c
            } else {
                chunks.append(c)
            }
        }
        // Read snapshot under lock to prevent concurrent modifies from being lost.
        let snapshot = chunks
        lock.unlock()
        persist(snapshot)
    }

    public func reindex(storage: MemoryStorage) {
        var built: [MemoryChunk] = []
        if let g = storage.readMemory(scope: .global) {
            built.append(contentsOf: Self.chunkMarkdown(
                g, path: storage.globalMemoryFile.path, source: "global"))
        }
        if let w = storage.readMemory(scope: .workspace) {
            built.append(contentsOf: Self.chunkMarkdown(
                w, path: storage.workspaceMemoryFile.path, source: "workspace"))
        }
        for session in storage.listSessionLogs() {
            if let text = storage.readFile(session) {
                built.append(contentsOf: Self.chunkMarkdown(
                    text, path: session.path, source: "session"))
            }
        }
        let projectRoot = storage.workspacePath
        for name in ["MEMORY.md", "DECISIONS.md", "SESSION_HANDOFF.md"] {
            let url = projectRoot.appendingPathComponent(name)
            if let text = storage.readFile(url), !text.isEmpty {
                built.append(contentsOf: Self.chunkMarkdown(
                    text, path: url.path, source: "workspace"))
            }
        }
        lock.lock()
        // Keep existing tool/injection/compaction_recovery chunks that were
        // explicitly upserted by the agent. Drop older auto-generated ones
        // so reindex can replace them with fresh content from memory files.
        let previous = chunks
        let keep = previous.filter {
            ["tool", "injection", "compaction_recovery"].contains($0.source)
        }
        // Deduplicate: remove old chunks whose text matches new content.
        let newTexts = Set(built.map { $0.text })
        let kept = keep.filter { !newTexts.contains($0.text) }
        // Preserve createdAt so age decay still applies after reindex.
        var ageByKey: [String: TimeInterval] = [:]
        for c in previous {
            ageByKey["\(c.path)\u{0}\(c.text)"] = c.createdAt
        }
        let aged = built.map { chunk -> MemoryChunk in
            var copy = chunk
            if let old = ageByKey["\(chunk.path)\u{0}\(chunk.text)"] {
                copy.createdAt = old
            }
            return copy
        }
        chunks = kept + aged
        lock.unlock()
        persist()
    }

    public func search(query: String, maxResults: Int = 8, minScore: Double = 0.05) -> [MemorySearchHit] {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return [] }
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        var hits: [MemorySearchHit] = []
        let now = Date().timeIntervalSince1970
        for chunk in snapshot {
            if Self.isContentFree(chunk.text, source: chunk.source) { continue }
            let score = Self.score(tokens: tokens, text: chunk.text, source: chunk.source,
                                   createdAt: chunk.createdAt, now: now)
            if score < minScore { continue }
            hits.append(MemorySearchHit(
                chunk: chunk, score: score,
                snippet: Self.makeSnippet(chunk.text, tokens: tokens)))
        }
        hits.sort { $0.score > $1.score }
        var selected: [MemorySearchHit] = []
        for h in hits {
            let tooSimilar = selected.contains {
                Self.jaccard(Self.tokenize($0.snippet), Self.tokenize(h.snippet)) > 0.85
            }
            if !tooSimilar { selected.append(h) }
            if selected.count >= maxResults { break }
        }
        return selected
    }

    public static func chunkMarkdown(_ text: String, path: String, source: String,
                                     maxChars: Int = 1200) -> [MemoryChunk] {
        let sections = text.components(separatedBy: "\n## ")
        var out: [MemoryChunk] = []
        var lineCursor = 1
        for (i, raw) in sections.enumerated() {
            let body = i == 0 ? raw : "## " + raw
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChars {
                let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
                out.append(MemoryChunk(
                    path: path, source: source, text: trimmed,
                    startLine: lineCursor, endLine: lineCursor + lines - 1))
                lineCursor += lines
            } else {
                var start = trimmed.startIndex
                while start < trimmed.endIndex {
                    let end = trimmed.index(start, offsetBy: maxChars, limitedBy: trimmed.endIndex)
                        ?? trimmed.endIndex
                    let piece = String(trimmed[start..<end])
                    let lines = piece.split(separator: "\n", omittingEmptySubsequences: false).count
                    out.append(MemoryChunk(
                        path: path, source: source, text: piece,
                        startLine: lineCursor, endLine: lineCursor + lines - 1))
                    lineCursor += lines
                    start = end
                }
            }
        }
        return out
    }

    public static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "your",
        "have", "been", "were", "was", "are", "but", "not", "you", "all",
        "any", "can", "our", "out", "use", "using", "via", "about"
    ]

    private static func score(tokens: [String], text: String, source: String,
                              createdAt: TimeInterval, now: TimeInterval) -> Double {
        let doc = tokenize(text)
        guard !doc.isEmpty else { return 0 }
        let set = Set(doc)
        var hits = 0
        for t in tokens where set.contains(t) { hits += 1 }
        guard hits > 0 else { return 0 }
        var base = Double(hits) / Double(tokens.count)
        if tokens.count >= 2 {
            let joined = tokens.joined(separator: " ")
            if text.lowercased().contains(joined) { base += 0.15 }
        }
        let weight: Double
        switch source {
        case "global", "workspace": weight = 1.15
        case "tool", "injection", "compaction_recovery": weight = 1.05
        default: weight = 1.0
        }
        base *= weight
        // Age decay: session memories expire faster (14-day half-life) while
        // global/workspace are more permanent but still decay slowly to prevent
        // 100-day-old content from permanently dominating fresh results.
        let ageDays = max(0, (now - createdAt) / 86_400)
        if source == "session" {
            let halfLife = 14.0
            let lambda = log(2.0) / halfLife
            base *= exp(-lambda * ageDays)
        } else if source == "global" || source == "workspace" {
            // 180-day half-life for permanent memories — slow decay prevents stale results
            let halfLife = 180.0
            let lambda = log(2.0) / halfLife
            base *= exp(-lambda * ageDays)
        }
        return min(1.0, base)
    }

    private static func makeSnippet(_ text: String, tokens: [String], maxLen: Int = 240) -> String {
        let lower = text.lowercased()
        if let t = tokens.first, let r = lower.range(of: t) {
            let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex)
                ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: maxLen, limitedBy: text.endIndex)
                ?? text.endIndex
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text.prefix(maxLen))
    }

    private static func isContentFree(_ text: String, source: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let contentLines = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") }
        if contentLines.isEmpty { return true }
        if (source == "global" || source == "workspace"),
           t.contains("Curated long-term notes") && contentLines.count < 2 {
            return true
        }
        return false
    }

    private static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a), sb = Set(b)
        guard !sa.isEmpty || !sb.isEmpty else { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    private func load() {
        let raw = try? Data(contentsOf: indexURL)
        guard let lines = raw.flatMap({ String(data: $0, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true) }) else {
            if raw != nil, !raw!.isEmpty {
                Diagnostics.warn("MemoryIndex: index file is corrupted or unreadable (\(raw!.count) bytes)")
            }
            chunks = []
            return
        }
        let decoder = JSONDecoder()
        var decoded: [MemoryChunk] = []
        for line in lines {
            guard let d = line.data(using: .utf8) else { continue }
            if let chunk = try? decoder.decode(MemoryChunk.self, from: d) {
                decoded.append(chunk)
            } else {
                // Skip lines that can't be decoded rather than discarding the whole file.
            }
        }
        chunks = decoded
    }

    private func persist() {
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [MemoryChunk]) {
        let dir = indexURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var out = ""
        for c in snapshot {
            if let d = try? encoder.encode(c), let s = String(data: d, encoding: .utf8) {
                out += s + "\n"
            }
        }
        // Always write, including an empty snapshot, so a full reindex
        // cannot leave a stale index.jsonl behind.
        try? out.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}

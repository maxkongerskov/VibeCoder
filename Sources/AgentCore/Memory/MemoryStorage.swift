//
//  MemoryStorage.swift
//  Markdown memory layout ported from Grok Build xai-grok-memory.
//

import Foundation
import CryptoKit

public enum MemoryScope: String, Sendable, Codable, Equatable {
    case global
    case workspace
    case session
}

public struct MemoryStorage: Sendable {
    public let globalDir: URL
    public let workspaceDir: URL
    public let workspacePath: URL
    public let ephemeral: Bool

    public static func defaultRoot() -> URL {
        AppSupport.directory("memory")
    }

    public init(workspacePath: URL, root: URL? = nil) {
        let global = root ?? Self.defaultRoot()
        self.globalDir = global
        self.workspacePath = workspacePath
        let hash = Self.workspaceHash(workspacePath)
        self.workspaceDir = global.appendingPathComponent(hash, isDirectory: true)
        let path = workspacePath.path
        self.ephemeral = path.hasPrefix(NSTemporaryDirectory())
            || path.contains("/T/")
            || path.contains("TemporaryDirectory")
    }

    public init(globalDir: URL, workspaceDir: URL, workspacePath: URL, ephemeral: Bool = false) {
        self.globalDir = globalDir
        self.workspaceDir = workspaceDir
        self.workspacePath = workspacePath
        self.ephemeral = ephemeral
    }

    public static func workspaceHash(_ path: URL) -> String {
        let normalized = path.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let slug = path.lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
            .prefix(32)
        return "\(slug)-\(hex.prefix(8))"
    }

    public var globalMemoryFile: URL { globalDir.appendingPathComponent("MEMORY.md") }
    public var workspaceMemoryFile: URL { workspaceDir.appendingPathComponent("MEMORY.md") }
    public var sessionsDir: URL { workspaceDir.appendingPathComponent("sessions", isDirectory: true) }
    public var indexFile: URL { workspaceDir.appendingPathComponent("index.jsonl") }
    public var dreamLockFile: URL { workspaceDir.appendingPathComponent(".dream-lock") }

    public func ensureDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: globalDir, withIntermediateDirectories: true)
        if !ephemeral {
            try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        }
    }

    public func readMemory(scope: MemoryScope) -> String? {
        let url: URL = scope == .global ? globalMemoryFile : workspaceMemoryFile
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public func appendMemory(scope: MemoryScope, text: String) throws {
        try ensureDirs()
        if ephemeral && scope != .global { return }
        let url = scope == .global ? globalMemoryFile : workspaceMemoryFile
        let stamp = ISO8601DateFormatter().string(from: Date())
        let block = "\n\n## \(stamp)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if FileManager.default.fileExists(atPath: url.path) {
            // Atomic append: read existing content, append new block, write back atomically.
            // FileHandle seek/write is not atomic and a crash in the middle corrupts the file.
            var existing = ""
            if let data = try? Data(contentsOf: url), let content = String(data: data, encoding: .utf8) {
                existing = content
            }
            let updated = existing + block
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let header = "# Memory\n\nCurated long-term notes for this \(scope == .global ? "machine" : "project").\n"
            try (header + block).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func writeSessionLog(sessionId: String, content: String) throws -> URL? {
        try ensureDirs()
        if ephemeral { return nil }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let slug = String(workspacePath.lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
            .prefix(16))
        let sid8 = String(sessionId.replacingOccurrences(of: "-", with: "").prefix(8))
        // Unique suffix per flush so multi-turn same-day sessions do not
        // overwrite prior logs when dream is throttled (Wave C2).
        let uniq = String(UUID().uuidString.prefix(8))
        let name = "\(day)-\(slug)-\(sid8)-\(uniq).md"
        let url = sessionsDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public func listSessionLogs() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func readFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

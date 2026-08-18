//
//  ConversationStore.swift
//
//  Atomic JSON-per-conversation persistence under Application Support:
//  ~/Library/Application Support/VibeCoder/conversations/
//

import Foundation

/// A conversation JSON file that `list()` could not decode.
public struct ConversationLoadFailure: Sendable, Equatable, Identifiable {
    public let url: URL
    public let filename: String
    public let reason: String
    public var id: String { url.path }

    public init(url: URL, reason: String) {
        self.url = url
        self.filename = url.lastPathComponent
        self.reason = reason
    }
}

/// One pass over the conversations directory: healthy rows plus files that
/// failed to decode. `list()` stays `[Conversation]` for existing callers.
public struct ConversationDirectoryListing: Sendable {
    public var conversations: [Conversation]
    public var unloadable: [ConversationLoadFailure]

    public init(conversations: [Conversation], unloadable: [ConversationLoadFailure]) {
        self.conversations = conversations
        self.unloadable = unloadable
    }
}

public protocol ConversationStoring: Sendable {
    func load(id: UUID) async throws -> Conversation?
    func save(_ conversation: Conversation) async throws
    func list() async throws -> [Conversation]
    func listDirectory() async throws -> ConversationDirectoryListing
    func delete(id: UUID) async throws
}

extension ConversationStoring {
    /// Stores that only implement `list()` report no unloadable files.
    public func listDirectory() async throws -> ConversationDirectoryListing {
        ConversationDirectoryListing(conversations: try await list(), unloadable: [])
    }
}

/// `Set<String>` Codable on `Conversation.sessionReadPaths` SIGSEGVs in
/// JSONEncoder/JSONDecoder (unkeyed Set). Persist the field as a JSON
/// string array and rebuild the in-memory Set ourselves.
public enum ConversationSessionReadCodec: Sendable {
    public static let jsonKey = "sessionReadPaths"

    public static func normalized<S: Sequence<String>>(_ paths: S) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in paths {
            let norm = SafeModeConfig.normalizePath(raw)
            guard !norm.isEmpty, seen.insert(norm).inserted else { continue }
            out.append(norm)
        }
        return out.sorted()
    }

    public static func decode(_ data: Data) throws -> Conversation {
        let extracted = extract(from: data)
        let payload: Data
        if extracted.hadKey {
            payload = try stripKey(from: data)
        } else {
            payload = data
        }
        var convo = try JSONDecoder.iso8601.decode(Conversation.self, from: payload)
        convo.sessionReadPaths = Set(extracted.paths)
        return convo
    }

    public static func encode(_ conversation: Conversation) throws -> Data {
        let paths = normalized(conversation.sessionReadPaths)
        var copy = conversation
        // Empty Set encode is the safe path; inject the array after.
        copy.sessionReadPaths = []
        let encoded = try JSONEncoder.iso8601Pretty.encode(copy)
        return try inject(paths, into: encoded)
    }

    private struct Extracted {
        var paths: [String]
        var hadKey: Bool
    }

    private static func extract(from data: Data) -> Extracted {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Extracted(paths: [], hadKey: false)
        }
        guard obj[jsonKey] != nil else {
            return Extracted(paths: [], hadKey: false)
        }
        let raw: [String]
        if let arr = obj[jsonKey] as? [String] {
            raw = arr
        } else if let arr = obj[jsonKey] as? [Any] {
            raw = arr.compactMap { $0 as? String }
        } else {
            raw = []
        }
        return Extracted(paths: normalized(raw), hadKey: true)
    }

    private static func stripKey(from data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        obj.removeValue(forKey: jsonKey)
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private static func inject(_ paths: [String], into data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        obj[jsonKey] = paths
        return try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
    }
}

public actor ConversationStore: ConversationStoring {

    public static let shared = ConversationStore()

    private let directory: URL

    public init(directory: URL? = nil) {
        if let d = directory {
            self.directory = d
        } else {
            self.directory = AppSupport.directory("conversations")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func load(id: UUID) async throws -> Conversation? {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let convo = try ConversationSessionReadCodec.decode(data)
        return await hydrateSessionReads(convo)
    }

    public func save(_ conversation: Conversation) async throws {
        var updated = conversation
        updated.updatedAt = Date()
        let live = await SessionReadTracker.shared.paths(for: updated.id)
        // Copy to Array first — do not formUnion a Codable-decoded Set.
        let merged = ConversationSessionReadCodec.normalized(
            ConversationSessionReadCodec.normalized(updated.sessionReadPaths) + live.sorted())
        updated.sessionReadPaths = Set(merged)
        await SessionReadTracker.shared.seed(
            paths: merged, conversationID: updated.id)
        let data = try ConversationSessionReadCodec.encode(updated)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(updated.id.uuidString + ".json")
        try data.write(to: url, options: .atomic)
    }

    public func list() async throws -> [Conversation] {
        try await listDirectory().conversations
    }

    public func listDirectory() async throws -> ConversationDirectoryListing {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        var out: [Conversation] = []
        var unloadable: [ConversationLoadFailure] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let convo = try ConversationSessionReadCodec.decode(data)
                out.append(await hydrateSessionReads(convo))
            } catch {
                unloadable.append(ConversationLoadFailure(url: file, reason: error.localizedDescription))
                Diagnostics.warn(
                    "ConversationStore.list: skipped unloadable \(file.lastPathComponent)",
                    detail: error.localizedDescription)
            }
        }
        return ConversationDirectoryListing(
            conversations: out.sorted { $0.updatedAt > $1.updatedAt },
            unloadable: unloadable.sorted { $0.filename < $1.filename })
    }

    public func delete(id: UUID) async throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        await SessionReadTracker.shared.clear(conversationID: id)
        await SkillToolGate.shared.clear(conversationID: id)
    }

    /// Rehydrate the in-memory read-before-edit set after a process restart.
    /// Union-only: an empty persisted set must not wipe live tracker paths.
    private func hydrateSessionReads(_ convo: Conversation) async -> Conversation {
        var updated = convo
        let paths = ConversationSessionReadCodec.normalized(convo.sessionReadPaths)
        updated.sessionReadPaths = Set(paths)
        await SessionReadTracker.shared.seed(paths: paths, conversationID: updated.id)
        return updated
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso8601Pretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

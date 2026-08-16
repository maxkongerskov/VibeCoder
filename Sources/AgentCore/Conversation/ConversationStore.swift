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
        return try JSONDecoder.iso8601.decode(Conversation.self, from: data)
    }

    public func save(_ conversation: Conversation) async throws {
        var updated = conversation
        updated.updatedAt = Date()
        let data = try JSONEncoder.iso8601Pretty.encode(updated)
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
                out.append(try JSONDecoder.iso8601.decode(Conversation.self, from: data))
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

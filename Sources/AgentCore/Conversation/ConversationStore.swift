//
//  ConversationStore.swift
//
//  Atomic JSON-per-conversation persistence under Application Support:
//  ~/Library/Application Support/VibeCoder/conversations/
//

import Foundation

public protocol ConversationStoring: Sendable {
    func load(id: UUID) async throws -> Conversation?
    func save(_ conversation: Conversation) async throws
    func list() async throws -> [Conversation]
    func delete(id: UUID) async throws
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
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])
        var out: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let convo = try? JSONDecoder.iso8601.decode(Conversation.self, from: data) {
                out.append(convo)
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
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

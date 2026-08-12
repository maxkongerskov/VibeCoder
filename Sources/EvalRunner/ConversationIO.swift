//
//  ConversationIO.swift
//
//  Cheap conversation JSON load/save for eval-runner `--resume` /
//  `--save-conversation` (Phase B PB6). Uses the same ISO-8601
//  Conversation codec as ConversationStore.
//

import Foundation
import AgentCore

public enum ConversationIO {
    /// Load a Conversation from a JSON file path.
    public static func load(fromPath path: String) throws -> Conversation {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalRunnerLibError.resumeMissing(path)
        }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(Conversation.self, from: data)
        } catch let e as EvalRunnerLibError {
            throw e
        } catch {
            throw EvalRunnerLibError.resumeDecode(error.localizedDescription)
        }
    }

    /// Atomically write a Conversation as pretty JSON.
    public static func save(_ conversation: Conversation, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty, dir.path != "." {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        do {
            var updated = conversation
            updated.updatedAt = Date()
            let data = try Self.encoder.encode(updated)
            try data.write(to: url, options: Data.WritingOptions.atomic)
        } catch {
            throw EvalRunnerLibError.saveFailed(error.localizedDescription)
        }
    }

    // ConversationStore's ISO-8601 helpers are internal to AgentCore —
    // mirror them here so resume JSON stays compatible without API churn.
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// After resume, re-bind project root to the eval workdir (resume files
    /// may have been captured with a different path).
    public static func rebindProjectRoot(
        _ conversation: Conversation,
        projectRoot: URL
    ) -> Conversation {
        var c = conversation
        c.projectRoot = projectRoot
        return c
    }
}

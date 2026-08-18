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
            // Array codec — Conversation.sessionReadPaths Set Codable SIGSEGVs.
            return try ConversationSessionReadCodec.decode(data)
        } catch let e as EvalRunnerLibError {
            throw e
        } catch {
            throw EvalRunnerLibError.resumeDecode(error.localizedDescription)
        }
    }

    /// Seed SessionReadTracker after `--resume`. Sync `load` cannot await
    /// the actor; the eval CLI still needs to call this (remaining gap).
    public static func hydrateSessionReads(_ conversation: Conversation) async {
        await SessionReadTracker.shared.seed(
            paths: conversation.sessionReadPaths,
            conversationID: conversation.id)
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
            let data = try ConversationSessionReadCodec.encode(updated)
            try data.write(to: url, options: Data.WritingOptions.atomic)
        } catch {
            throw EvalRunnerLibError.saveFailed(error.localizedDescription)
        }
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

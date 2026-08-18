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

    /// Seed SessionReadTracker after `--resume`. Call from the eval CLI
    /// after `load` (sync decode cannot await the actor).
    public static func hydrateSessionReads(_ conversation: Conversation) async {
        let paths = ConversationSessionReadCodec.normalized(conversation.sessionReadPaths)
        await SessionReadTracker.shared.seed(
            paths: paths,
            conversationID: conversation.id)
    }

    /// Atomically write a Conversation as pretty JSON.
    /// Merges live tracker paths first — otherwise `--save-conversation`
    /// then `--resume` hydrates an empty set (tracker is process-local).
    @discardableResult
    public static func save(_ conversation: Conversation, toPath path: String) async throws -> Conversation {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty, dir.path != "." {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        do {
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
            try data.write(to: url, options: Data.WritingOptions.atomic)
            return updated
        } catch {
            throw EvalRunnerLibError.saveFailed(error.localizedDescription)
        }
    }

    /// After resume, re-bind project root to the eval workdir.
    /// Read-before-edit compares absolute paths, so reads under the old
    /// root move to the same relative path under `--project`.
    public static func rebindProjectRoot(
        _ conversation: Conversation,
        projectRoot: URL
    ) -> Conversation {
        var c = conversation
        if let oldURL = conversation.projectRoot {
            let oldRoot = SafeModeConfig.normalizePath(oldURL.path)
            let newRoot = SafeModeConfig.normalizePath(projectRoot.path)
            if !oldRoot.isEmpty, !newRoot.isEmpty, oldRoot != newRoot {
                let remapped = ConversationSessionReadCodec.normalized(
                    conversation.sessionReadPaths
                ).map { rebaseSessionRead($0, from: oldRoot, to: newRoot) }
                c.sessionReadPaths = Set(ConversationSessionReadCodec.normalized(remapped))
            }
        }
        c.projectRoot = projectRoot
        return c
    }

    private static func rebaseSessionRead(
        _ path: String, from oldRoot: String, to newRoot: String
    ) -> String {
        if path == oldRoot { return newRoot }
        let prefix = oldRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return SafeModeConfig.normalizePath(
            newRoot + "/" + String(path.dropFirst(prefix.count)))
    }
}

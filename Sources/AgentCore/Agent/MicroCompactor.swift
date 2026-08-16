//
//  MicroCompactor.swift
//
//  Wire-copy clear of old compactable tool-result bodies. Pairing
//  (`tool_call_id`) is never rewritten — only `content` of old `.tool`
//  rows is replaced. Operates on a copy; the caller is not mutated.
//

import Foundation

public enum MicroCompactor: Sendable {

    /// ZCode `pMt` — body written over cleared tool results.
    public static let clearedMarker = "[Old tool result content cleared]"

    /// Last N transcript messages left verbatim (ZCode keep-recent analogue).
    public static let defaultKeepRecent = 6

    /// VibeCoder names mapped from ZCode Read/Bash/Grep/Glob/WebFetch/
    /// WebSearch/Edit/Write/ApplyPatch (`Icn`).
    public static let defaultCompactableToolNames: Set<String> = [
        "read_file",
        "run_shell",
        "grep_code",
        "glob_files",
        "fetch_url",
        "web_search",
        "edit_file",
        "write_file",
        "apply_patch",
    ]

    /// ZCode catalog names → VibeCoder builtins (accepted in addition to defaults).
    public static let zcodeNameAliases: [String: String] = [
        "Read": "read_file",
        "Bash": "run_shell",
        "Grep": "grep_code",
        "Glob": "glob_files",
        "WebFetch": "fetch_url",
        "WebSearch": "web_search",
        "Edit": "edit_file",
        "Write": "write_file",
        "ApplyPatch": "apply_patch",
    ]

    public static func isClearedToolResult(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines) == clearedMarker
    }

    /// Copy of `conversation` with old compactable tool bodies cleared.
    public static func compact(
        _ conversation: Conversation,
        keepRecent: Int = defaultKeepRecent,
        compactableToolNames: Set<String> = defaultCompactableToolNames
    ) -> Conversation {
        var copy = conversation
        copy.messages = compact(
            messages: conversation.messages,
            keepRecent: keepRecent,
            compactableToolNames: compactableToolNames)
        return copy
    }

    /// Copy of `messages` with old compactable tool bodies cleared.
    public static func compact(
        messages: [ChatMessage],
        keepRecent: Int = defaultKeepRecent,
        compactableToolNames: Set<String> = defaultCompactableToolNames
    ) -> [ChatMessage] {
        let protect = max(0, keepRecent)
        guard messages.count > protect else { return messages }

        var invocationByID: [String: ToolCallInvocation] = [:]
        for m in messages where m.role == .assistant {
            for inv in m.toolCalls {
                invocationByID[inv.id] = inv
            }
        }

        let cut = messages.count - protect
        var out = messages
        for i in 0..<cut {
            let msg = out[i]
            guard msg.role == .tool else { continue }
            guard msg.images.isEmpty else { continue }
            guard !isClearedToolResult(msg.content) else { continue }
            guard let callID = msg.toolCallID, let inv = invocationByID[callID] else {
                continue
            }
            guard isCompactable(inv.name, allowed: compactableToolNames) else {
                continue
            }
            out[i].content = clearedMarker
        }
        return out
    }

    // MARK: - Name match

    public static func isCompactable(_ toolName: String, allowed: Set<String>) -> Bool {
        if allowed.contains(toolName) { return true }
        let folded = toolName.lowercased()
        if allowed.contains(where: { $0.lowercased() == folded }) { return true }
        if let mapped = zcodeNameAliases[toolName], allowed.contains(mapped) {
            return true
        }
        for (alias, mapped) in zcodeNameAliases {
            if alias.lowercased() == folded, allowed.contains(mapped) {
                return true
            }
        }
        return false
    }
}

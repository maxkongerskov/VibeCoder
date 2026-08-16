//
//  ToolResultCompressor.swift
//
//  Wire-copy compressor for tool results. The agent loop always persists
//  FULL tool results in `convo.messages` (so the model sees the real
//  content on the iteration immediately after the call). Before each
//  subsequent request is assembled, old large results are replaced with
//  compact summaries to reclaim context tokens.
//
//  Contract:
//    • The persisted `Conversation` is NEVER modified — this works on a
//      copy produced for the wire only, exactly like `ChatLoop.compactHistory`.
//    • The most-recent tool result for each tool call is NEVER compressed —
//      the model needs the full result for its next immediate decision.
//    • Only results older than `keepRecentTurns` assistant turns back are
//      eligible for compression.
//    • Pure and Sendable: no I/O, no state, safe to call from an actor.
//

import Foundation

public enum ToolResultCompressor {

    // MARK: - Configuration

    /// Tool results shorter than this (in characters) are left untouched.
    public static let threshold = 2_000

    /// How many complete assistant turns (tool-call + result pairs) to
    /// protect from compression. The current turn is always protected;
    /// this adds N more turns of protection behind it.
    public static let keepRecentTurns = 1

    // MARK: - Entry point

    /// Return a copy of `messages` where old, large tool results have been
    /// replaced with compact summaries, and duplicate reads of the same
    /// path replaced with stubs. Call this on the wire-only copy, never
    /// on the persisted conversation.
    public static func compress(_ messages: [ChatMessage]) -> [ChatMessage] {
        // Pass 1: deduplicate repeated reads of the same file path.
        var working = deduplicate(messages)

        // Pass 2: compress old large results.
        let eligibleIndices = eligibleToolMessageIndices(in: working)
        for idx in eligibleIndices {
            let msg = working[idx]
            // Already micro-cleared — do not re-summarize the marker.
            if MicroCompactor.isClearedToolResult(msg.content) { continue }
            guard msg.content.count > threshold else { continue }
            let tName = toolName(for: msg, in: working)
            working[idx].content = summarize(result: msg.content, toolName: tName)
        }
        return working
    }

    // MARK: - Deduplication

    /// Replace repeated `read_file` results for the same path with a stub
    /// when the content is identical (or nearly so) to a prior read.
    /// Only old results (not the most recent read of each path) are stubbed.
    static func deduplicate(_ messages: [ChatMessage]) -> [ChatMessage] {
        var working = messages

        // Build a map: path → [(messageIndex, contentHash)] for read_file results.
        // We need to find which tool call each tool message satisfies, then check
        // if the tool was read_file and extract the path argument.

        // Build a callID → invocation map for fast lookup.
        var invocationByID: [String: ToolCallInvocation] = [:]
        for m in messages where m.role == .assistant {
            for inv in m.toolCalls {
                invocationByID[inv.id] = inv
            }
        }

        // Collect read_file tool-message indices grouped by path.
        // path → [index in working] (ordered oldest → newest).
        var pathIndices: [String: [Int]] = [:]
        for (i, m) in working.enumerated() where m.role == .tool {
            guard let callID = m.toolCallID,
                  let inv = invocationByID[callID],
                  inv.name == "read_file",
                  let path = extractPath(from: inv.arguments) else { continue }
            pathIndices[path, default: []].append(i)
        }

        // For each path with multiple reads, stub out all but the LAST one
        // if its content matches the last read (hash comparison).
        for (path, indices) in pathIndices where indices.count > 1 {
            let lastIdx = indices.last!
            let lastContent = working[lastIdx].content
            for idx in indices.dropLast() {
                // Only stub if content is identical (exact match is cheapest
                // and catches the common "model re-reads unchanged file" case).
                if working[idx].content == lastContent {
                    // Find which iteration this read happened in.
                    let iterHint = indices.firstIndex(of: idx).map { $0 + 1 } ?? idx
                    working[idx].content =
                        "[Re-read of \(path) — content unchanged from read #\(iterHint). " +
                        "Full content available in the most recent read later in this transcript.]"
                }
            }
        }
        return working
    }

    /// Extract the `path` value from a JSON arguments string.
    private static func extractPath(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String else { return nil }
        return path
    }

    // MARK: - Eligibility

    /// Indices of `.tool` messages that are old enough to compress.
    /// We protect the most recent `keepRecentTurns + 1` complete
    /// assistant→tool round trips.
    private static func eligibleToolMessageIndices(in messages: [ChatMessage]) -> [Int] {
        // Collect the indices of all assistant messages (in order).
        let assistantIndices = messages.indices.filter { messages[$0].role == .assistant }

        // The protected assistant turns are the last (keepRecentTurns + 1).
        let protectFrom = assistantIndices.count > keepRecentTurns
            ? assistantIndices[assistantIndices.count - 1 - keepRecentTurns]
            : 0

        return messages.indices.filter { i in
            messages[i].role == .tool && i < protectFrom
        }
    }

    // MARK: - Tool name lookup

    /// Find the tool name for a `.tool` message by scanning backwards for
    /// the assistant message whose toolCall id matches the message's
    /// `toolCallID`.
    private static func toolName(for msg: ChatMessage, in messages: [ChatMessage]) -> String? {
        guard let callID = msg.toolCallID else { return nil }
        for m in messages.reversed() where m.role == .assistant {
            if let inv = m.toolCalls.first(where: { $0.id == callID }) {
                return inv.name
            }
        }
        return nil
    }

    // MARK: - Summarizers

    static func summarize(result: String, toolName: String?) -> String {
        switch toolName {
        case "read_file":
            return summarizeReadFile(result)
        case "run_shell", "xcode_build":
            return summarizeShell(result)
        case "list_directory", "glob_files", "grep_code": // registered search tools
            return summarizeListing(result)
        default:
            return summarizeGeneric(result)
        }
    }

    /// read_file: keep first 30 lines + last 10 lines + line count.
    /// Large single-line / few-line blobs (minified JSON, base64, long
    /// single-line source) fall through to char truncation — line count
    /// alone is not a size proxy (Wave C W15: SubAgent compress test +
    /// real wire bloat).
    static func summarizeReadFile(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let total = lines.count
        guard total > 40 else {
            // Few lines but still large by char count (threshold gate already
            // passed in `compress`) — must not leave multi-KB blobs intact.
            return summarizeGeneric(content)
        }

        let head = lines.prefix(30).joined(separator: "\n")
        let tail = lines.suffix(10).joined(separator: "\n")
        return """
        \(head)
        … [\(total - 40) lines elided — compressed from history to save context] …
        \(tail)
        """
    }

    /// shell/build: exit code line + first 20 + last 20 + error summary.
    static func summarizeShell(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let total = lines.count
        guard total > 40 else {
            return summarizeGeneric(content)
        }

        // Pull out any line that looks like an exit/error summary.
        let errorLines = lines.filter {
            let l = $0.lowercased()
            return l.contains("error:") || l.contains("exit code")
                || l.contains("fatal:") || l.contains("warning:")
        }.prefix(5).joined(separator: "\n")

        let head = lines.prefix(20).joined(separator: "\n")
        let tail = lines.suffix(20).joined(separator: "\n")

        var parts = [head]
        parts.append("… [\(total - 40) lines elided] …")
        if !errorLines.isEmpty {
            parts.append("── Key diagnostics ──\n\(errorLines)")
        }
        parts.append(tail)
        return parts.joined(separator: "\n")
    }

    /// directory listings / grep: keep first 50 entries + count.
    static func summarizeListing(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let total = lines.count
        guard total > 50 else {
            return content.count > threshold ? summarizeGeneric(content) : content
        }

        let head = lines.prefix(50).joined(separator: "\n")
        return "\(head)\n… [\(total - 50) more entries elided — \(total) total]"
    }

    /// Fallback: first 500 chars + total char count.
    static func summarizeGeneric(_ content: String) -> String {
        let limit = 500
        guard content.count > limit else { return content }
        let preview = String(content.prefix(limit))
        return "\(preview)\n… [result truncated — \(content.count) chars total, older iterations carry full content]"
    }
}

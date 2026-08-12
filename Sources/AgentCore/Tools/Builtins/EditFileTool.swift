//
//  EditFileTool.swift
//
//  v1.1 Tools-Week (#309): `edit_file` — SEARCH/REPLACE-block edits.
//
//  Replaces `apply_patch` as the recommended edit primitive. Wire format
//  is plain text, not JSON-escaped diff, so models can emit Swift
//  keypaths (`\.self`), Python f-strings, backslash-heavy regexes, and
//  Markdown without crashing the JSON parser on the way to disk.
//
//  Schema is intentionally minimal — two parameters, both strings, no
//  per-block array. The whole edit payload goes into `edits` as one
//  block of text containing one or more SEARCH/REPLACE blocks. Smaller
//  schemas help small models stay inside the lines.
//
//  Example call:
//
//  ```json
//  {
//    "path": "Sources/Foo.swift",
//    "edits": "Sources/Foo.swift\n<<<<<<< SEARCH\nlet x = 1\n=======\nlet x = 2\n>>>>>>> REPLACE\n"
//  }
//  ```
//
//  The `path` argument is also the default filename for any block in
//  `edits` that omits its own filename header. So for single-file edits,
//  the model can skip the filename line inside the block.
//
//  Wave B (S5): multi-block apply is **strict by default** — if any block
//  fails, nothing is written. Pass `partial_ok=true` for Aider-style
//  partial apply (successful blocks written, isError + diagnostics).
//  Per-block filenames that resolve to a different path than `path` fail
//  closed (use `apply_patch` for multi-file).
//

import Foundation

public struct EditFileTool: Tool {
    public static let name = "edit_file"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Edit a file by applying one or more SEARCH/REPLACE blocks. The wire format is plain text (no JSON escaping of code content):

            <<<<<<< SEARCH
            text to find (must match a contiguous region of the file)
            =======
            text that replaces it
            >>>>>>> REPLACE

        Multiple blocks per call are allowed; each must target the same file as `path` (use apply_patch for multi-file). The SEARCH section must match the file's current text — exactly, OR with uniform leading-whitespace tolerance, OR with `...` markers on their own lines to skip unchanged regions.

        For new file creation, leave SEARCH empty (just the marker, then divider, then content). For full-file rewrites, use `write_file` instead.

        By default all blocks must succeed or nothing is written (strict). Set partial_ok=true to apply successful blocks even when some fail (Aider-style). On failure the tool returns a per-block diagnostic showing the nearest matching chunk so you can retry with corrected SEARCH text.

        Existing files require a prior read_file in this conversation (read-before-edit).
        """,
        parameters: .init(
            properties: [
                "path": .init(type: "string", description: "File to edit (relative to project root, or absolute). Also used as the default filename for blocks in `edits` that omit a header."),
                "edits": .init(type: "string", description: "One or more SEARCH/REPLACE blocks in plain text. See description for format."),
                "replace_all": .init(type: "boolean", description: "If true, allow SEARCH text that matches multiple times and replace every occurrence. Default false (unique match required)."),
                "partial_ok": .init(type: "boolean", description: "If true, write successful blocks even when others fail (Aider partial apply). Default false: any failure aborts with no disk write.")
            ],
            required: ["path", "edits"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = try arguments.string("path")
        let editsText = try arguments.string("edits")
        let url = resolvePath(path, base: context.workingDirectory)
        // Async path hydrates process + durable grants (sync body check only
        // saw context.authorization.remembered and missed "Always allow folder").
        try await PathConfinement.requireInsideWorkspaceAsync(
            path: path, resolved: url, context: context)

        // Parse blocks. We accept "default filename = path argument" by
        // prefixing the path on its own line — that way single-file
        // edits can skip the filename header inside each block.
        let normalisedEdits = ensureDefaultFilename(editsText, defaultPath: path)
        let blocks: [EditBlock]
        do {
            blocks = try EditBlockParser.findBlocks(in: normalisedEdits)
        } catch {
            return ToolResult(
                content: "edit_file: couldn't parse the SEARCH/REPLACE blocks.\n\n\(error.localizedDescription)",
                isError: true
            )
        }

        if blocks.isEmpty {
            return ToolResult(
                content: "edit_file: no SEARCH/REPLACE blocks found in `edits`. Expected at least one `<<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE` block.",
                isError: true
            )
        }

        // Fail closed if any block targets a different file than `path`.
        if let mismatch = firstMismatchedFilename(in: blocks, toolPath: path, base: context.workingDirectory) {
            return ToolResult(
                content: "edit_file: block targets '\(mismatch)' but path is '\(path)'. "
                    + "All SEARCH/REPLACE blocks must target the same file as `path`. "
                    + "Use apply_patch for multi-file edits, or call edit_file once per file.",
                isError: true
            )
        }

        // Read current file contents. Missing files are OK if every
        // block's SEARCH is empty (= file-creation request).
        let existing: String
        let fileExisted: Bool
        if FileManager.default.fileExists(atPath: url.path) {
            // Read-before-edit: existing files must have been read this session
            // (or passed via context.sessionReadPaths for tests).
            let sessionOk = await SessionReadTracker.shared.hasSessionRead(
                path: url.path,
                conversationID: context.conversationID,
                sessionReadPaths: context.sessionReadPaths)
            if !sessionOk {
                return ToolResult(
                    content: "edit_file: read-before-edit required. Call `read_file` on \(path) before editing an existing file.",
                    isError: true
                )
            }
            do {
                existing = try String(contentsOf: url, encoding: .utf8)
                fileExisted = true
            } catch {
                return ToolResult(
                    content: "edit_file: failed to read \(path) — \(error.localizedDescription)",
                    isError: true
                )
            }
        } else {
            let allEmpty = blocks.allSatisfy { $0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !allEmpty {
                return ToolResult(
                    content: "edit_file: \(path) does not exist. To create a new file, every block's SEARCH section must be empty (just the markers).",
                    isError: true
                )
            }
            existing = ""
            fileExisted = false
        }

        let replaceAll = arguments.bool("replace_all", default: false)
        let partialOk = arguments.bool("partial_ok", default: false)

        // Unique-match enforcement for non-empty SEARCH sections unless
        // replace_all is set. Count uses the **same cascade as apply**
        // (exact lines → leading-whitespace flex) so we don't reject
        // indent-mismatched SEARCH that would uniquely apply, or allow
        // SEARCH that matches multiple windows under cascade.
        if !replaceAll {
            for block in blocks {
                let search = block.original
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let count = EditBlockApplier.countMatchWindows(
                    search: search, in: existing, filename: block.filename)
                if count > 1 {
                    return ToolResult(
                        content: "edit_file: ambiguous SEARCH match in \(path) — found \(count) regions "
                            + "(exact or whitespace-tolerant). "
                            + "Add surrounding lines so SEARCH matches exactly once, or set replace_all=true.",
                        isError: true
                    )
                }
            }
        }

        // Apply blocks in memory. Strict mode (default): any failure → no write.
        let (newContent, failures): (String, [(EditBlock, String)])
        if replaceAll {
            var working = existing
            var fails: [(EditBlock, String)] = []
            for block in blocks {
                let search = block.original
                if search.isEmpty {
                    let outcome = EditBlockApplier.apply(block, to: working)
                    switch outcome {
                    case .applied(let next): working = next
                    case .failed(let reason): fails.append((block, reason))
                    }
                    continue
                }
                // Apply the 3-tier cascade repeatedly until no more matches.
                var appliedAny = false
                while true {
                    let outcome = EditBlockApplier.apply(block, to: working)
                    switch outcome {
                    case .applied(let next):
                        // No-op: if apply produced identical content, stop.
                        guard next != working else { break }
                        working = next
                        appliedAny = true
                    case .failed:
                        break
                    }
                }
                if !appliedAny {
                    fails.append((block, "SEARCH not found for replace_all in \(path)"))
                }
            }
            newContent = working
            failures = fails
        } else {
            (newContent, failures) = EditBlockApplier.applyAll(blocks, to: existing)
        }

        if !failures.isEmpty {
            let report = buildFailureReport(failures: failures, total: blocks.count)
            // Strict (default): never write on partial or total failure.
            if !partialOk {
                return ToolResult(
                    content: "edit_file: strict multi-block apply — no files modified.\n\n\(report)\n\n"
                        + "All blocks must succeed, or set partial_ok=true to write successful blocks only.",
                    isError: true
                )
            }
            // partial_ok: if nothing changed, still no write.
            if newContent == existing {
                return ToolResult(content: report, isError: true)
            }
        }

        // Fail closed when SEARCH matched but produced no content change
        // (identical SEARCH/REPLACE or no-op replace_all) — matches Grok search_replace.
        if failures.isEmpty && newContent == existing {
            return ToolResult(
                content: "edit_file: no changes produced for \(path) — SEARCH and REPLACE are identical "
                    + "(or blocks did not alter the file). No files modified.",
                isError: true
            )
        }

        // Ask mode: review before writing the working copy.
        do {
            try await MutationReview.requireApproval(
                path: path, original: existing, updated: newContent, context: context)
        } catch {
            return ToolResult(content: error.localizedDescription, isError: true)
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(
                content: "edit_file: applied \(blocks.count - failures.count) block(s) but couldn't write \(path) — \(error.localizedDescription)",
                isError: true
            )
        }

        let hunk = TrackedHunk(
            conversationID: context.conversationID,
            path: url.path,
            originalContent: existing,
            updatedContent: newContent)
        await HunkTracker.shared.record(hunk)

        let appliedCount = blocks.count - failures.count
        let verb = fileExisted ? "Edited" : "Created"
        var summary = "\(verb) \(path) (\(appliedCount)/\(blocks.count) block\(blocks.count == 1 ? "" : "s") applied). hunk_id=\(hunk.id.uuidString)"
        if !failures.isEmpty {
            summary += "\n\n\(buildFailureReport(failures: failures, total: blocks.count))"
            return ToolResult(content: summary, isError: true, mutatedPaths: [path])
        }
        return ToolResult(content: summary, mutatedPaths: [path])
    }

    // MARK: - Helpers

    /// If `editsText` has any SEARCH marker without a preceding filename
    /// line, prepend the tool's `path` argument so the parser doesn't
    /// throw `missingFilename`. This is the QoL fix that makes single-
    /// file edits possible without forcing the model to repeat the path
    /// inside every block.
    private func ensureDefaultFilename(_ editsText: String, defaultPath: String) -> String {
        let trimmed = editsText.drop { $0.isWhitespace }
        if trimmed.hasPrefix("<<<<<<<") || trimmed.hasPrefix("<<<<<<") || trimmed.hasPrefix("<<<<<") {
            return defaultPath + "\n" + editsText
        }
        return editsText
    }

    /// Returns the first block filename that does not resolve to the same
    /// file as `toolPath`, or nil when all blocks match.
    private func firstMismatchedFilename(
        in blocks: [EditBlock],
        toolPath: String,
        base: URL
    ) -> String? {
        let toolNorm = SafeModeConfig.normalizePath(resolvePath(toolPath, base: base).path)
        for block in blocks {
            let blockNorm = SafeModeConfig.normalizePath(resolvePath(block.filename, base: base).path)
            if blockNorm != toolNorm {
                return block.filename
            }
        }
        return nil
    }

    private func buildFailureReport(failures: [(EditBlock, String)], total: Int) -> String {
        let header = "\(failures.count) of \(total) SEARCH/REPLACE block\(total == 1 ? "" : "s") failed to match.\n\n"
        let body = failures.map { $0.1 }.joined(separator: "\n")
        let footer = "\n\nRetry only the failed block(s) with corrected SEARCH text — the SEARCH section must match an existing region of the file."
        return header + body + footer
    }

    /// Non-overlapping exact substring count (left-to-right).
    static func nonOverlappingCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
        }
        return count
    }
}

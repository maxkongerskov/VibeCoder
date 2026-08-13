//
//  ToolCallView.swift
//
//  Ported from DEV PLAN (UI Iteration 2 Batch 8).
//  Expandable tool-call card with pulsing accent bar, status icon,
//  collapsed smart-subtitle line, expanded input/output blocks.
//
//  Aesthetic pass adds three things on top of the original:
//
//    1. ShellBlock — terminal-styled rendering of `run_shell` input.
//       Dim background, `$` prompt prefix, exit-code badge parsed
//       from the leading `[exit N]` line that the run-shell tool
//       always emits.
//
//    2. Smart subtitles — instead of the previous "first line of
//       raw JSON output" preview, each tool now exposes a one-line
//       human-readable summary derived from its arguments. e.g.,
//       `run_shell` shows the command, `read_file` shows the path,
//       `web_search` shows the query, `apply_patch` shows the hunk
//       count. Renders next to the tool name in the collapsed
//       header.
//
//    3. OutputBlock — output preview capped at 12 lines with a
//       "Show N more lines" toggle. Stops a single noisy run_shell
//       (binary PDF dumps, full curl bodies, npm-install logs) from
//       taking over the entire conversation surface.
//

import SwiftUI
import AppKit

// MARK: - DTO

struct ToolCallUIState: Identifiable, Hashable {
    let id: String
    let toolName: String
    let status: ToolCallStatus
    let input: String
    let output: String
}

enum ToolCallStatus: Hashable { case pending, running, success, failure }

// MARK: - View

struct ToolCallView: View {
    let state: ToolCallUIState
    @State private var expanded = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if state.status == .running {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.Palette.accent)
                            .frame(width: 2, height: 16)
                            .opacity(pulse ? 0.45 : 1.0)
                            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                       value: pulse)
                    }
                    statusIcon
                    Text(state.toolName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.Palette.secondary)
                    if !expanded, state.status != .running,
                       let subtitle = smartSubtitle, !subtitle.isEmpty {
                        Text("·  \(subtitle)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Palette.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(headerBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7).stroke(borderColor, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .onAppear { pulse.toggle() }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            ))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    inputBlock
                    if !state.output.isEmpty {
                        OutputBlock(text: state.output)
                    }
                }
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Per-tool input rendering. `run_shell` gets the full terminal
    /// treatment (prompt prefix, distinct background, exit badge);
    /// everything else falls back to the original label-plus-mono
    /// block, which already reads well for short JSON.
    @ViewBuilder private var inputBlock: some View {
        if state.toolName == "run_shell",
           let command = ToolSummary.shellCommand(fromJSON: state.input) {
            ShellBlock(command: command, exitCode: ShellOutput.exitCode(from: state.output))
        } else if !state.input.isEmpty {
            detailBlock(label: "Input", text: state.input)
        }
    }

    @ViewBuilder
    private func detailBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
                .tracking(0.5)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Palette.secondary)
                .lineLimit(20)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch state.status {
        case .pending:
            Circle()
                .stroke(Theme.Palette.tertiary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .running:
            ProgressView().scaleEffect(0.55).frame(width: 13, height: 13)
        case .success:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                .foregroundColor(Theme.Palette.success)
        case .failure:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                .foregroundColor(Theme.Palette.error)
        }
    }

    private var headerBackground: Color {
        switch state.status {
        case .pending: return Color(NSColor.textBackgroundColor)
        case .running: return Theme.Palette.accent.opacity(0.07)
        case .failure: return Theme.Palette.error.opacity(0.07)
        case .success: return Color(NSColor.textBackgroundColor)
        }
    }

    private var borderColor: Color {
        switch state.status {
        case .pending: return Theme.Palette.divider
        case .running: return Theme.Palette.accent.opacity(0.30)
        case .failure: return Theme.Palette.error.opacity(0.30)
        case .success: return Theme.Palette.divider
        }
    }

    /// Human-readable one-liner derived from the tool's input args.
    /// Returns the meaningful field for known tools, falls back to
    /// the (cleaned) first line of output for everything else.
    private var smartSubtitle: String? {
        if let s = ToolSummary.subtitle(toolName: state.toolName, input: state.input) {
            return s
        }
        // Fallback: first line of output, same as the pre-aesthetic
        // pass's behavior. Keeps unknown tools from going blank.
        let trimmed = state.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let cleaned = firstLine.trimmingCharacters(in: .whitespaces)
        return cleaned.count > 80 ? String(cleaned.prefix(77)) + "…" : cleaned
    }
}

// MARK: - Smart subtitles
//
// Per-tool extractor that pulls the meaningful field out of the tool's
// JSON arguments and returns a short, single-line summary. Keeps the
// collapsed header readable at a glance — "run_shell · pdftotext …"
// rather than "run_shell · {\"command\":\"pdftotext ...\"}".

enum ToolSummary {

    /// Top-level dispatch. Returns nil for tools without a registered
    /// extractor — the view falls back to its old first-line-of-output
    /// preview in that case.
    static func subtitle(toolName: String, input: String) -> String? {
        switch toolName {
        case "run_shell":
            return shellCommand(fromJSON: input).map { trim($0, max: 80) }
        case "fetch_url", "fetch_rss":
            return stringField("url", fromJSON: input)
        case "web_search":
            return stringField("query", fromJSON: input)
        case "apple_docs_search":
            return stringField("query", fromJSON: input)
        case "read_file", "read_file_range", "write_file",
             "delete_file", "list_directory", "create_directory",
             "edit_file":
            return stringField("path", fromJSON: input)
                ?? stringField("file_path", fromJSON: input)
        case "move_file":
            if let from = stringField("from", fromJSON: input),
               let to = stringField("to", fromJSON: input) {
                return "\(from) → \(to)"
            }
            return stringField("path", fromJSON: input)
        case "glob_files":
            return stringField("pattern", fromJSON: input)
        case "grep_code":
            return stringField("pattern", fromJSON: input)
                ?? stringField("query", fromJSON: input)
        case "apply_patch":
            return patchSummary(fromJSON: input)
        case "git_status", "git_diff", "git_log", "git_show", "git_blame":
            // git tools mostly take an optional `path` or empty args
            return stringField("path", fromJSON: input) ?? "working tree"
        case "git_commit":
            return stringField("message", fromJSON: input)
        case "build_xcode", "swift_check", "run_xcode_tests",
             "build_swift_package", "BuildProject":
            return stringField("scheme", fromJSON: input)
                ?? stringField("path", fromJSON: input)
        case "XcodeRead", "XcodeWrite", "XcodeUpdate", "XcodeGrep":
            return stringField("path", fromJSON: input)
                ?? stringField("pattern", fromJSON: input)
                ?? stringField("query", fromJSON: input)
        case "tool_search":
            return stringField("query", fromJSON: input)
        default:
            return nil
        }
    }

    /// Pulled out for ToolCallView.inputBlock so the terminal-style
    /// renderer can re-extract the command without re-parsing JSON.
    static func shellCommand(fromJSON json: String) -> String? {
        stringField("command", fromJSON: json)
    }

    private static func stringField(_ key: String, fromJSON json: String) -> String? {
        guard let dict = parse(json),
              let value = dict[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    /// `apply_patch` carries a diff body; summarize by hunk count.
    private static func patchSummary(fromJSON json: String) -> String? {
        guard let dict = parse(json),
              let patch = dict["patch"] as? String
        else { return nil }
        let hunks = (patch.components(separatedBy: "@@").count - 1) / 2
        return hunks > 0 ? "\(hunks) hunk\(hunks == 1 ? "" : "s")" : nil
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func trim(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }
}

// MARK: - ShellBlock — terminal-style run_shell input

private struct ShellBlock: View {
    let command: String
    let exitCode: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text("$")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Palette.success)
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.Palette.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let exitCode {
                    ExitBadge(code: exitCode)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Palette.divider.opacity(0.6), lineWidth: 0.5)
        )
    }
}

private struct ExitBadge: View {
    let code: Int

    var body: some View {
        Text("exit \(code)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(code == 0
                               ? Theme.Palette.success.opacity(0.18)
                               : Theme.Palette.error.opacity(0.18))
            )
            .foregroundColor(code == 0 ? Theme.Palette.success : Theme.Palette.error)
    }
}

// MARK: - ShellOutput parsing
//
// The run_shell tool emits `$ cmd\n[exit N]\nstdout`. Scan the first
// few lines for `[exit N]` so we can render a badge and strip that
// line from the body.

enum ShellOutput {
    /// RunShellTool emits `$ cmd\n[exit N]\nstdout` — scan the first few
    /// lines rather than only the first non-empty line.
    private static let scanLineLimit = 8
    private static let exitPattern = #"^\s*\[exit (-?\d+)\]\s*$"#

    /// Returns the exit code if any of the first few lines is `[exit N]`.
    static func exitCode(from output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: exitPattern) else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.prefix(scanLineLimit) {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if let match = regex.firstMatch(in: s, range: range),
               let codeRange = Range(match.range(at: 1), in: s) {
                return Int(s[codeRange])
            }
        }
        return nil
    }

    /// Remove the `[exit N]` line (not merely line 0) so OutputBlock
    /// doesn't show it — we've already promoted it to ExitBadge.
    static func stripExitLine(from output: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: exitPattern) else { return output }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Substring] = []
        var removed = false
        for (index, line) in lines.enumerated() {
            if !removed && index < scanLineLimit {
                let s = String(line)
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    removed = true
                    continue
                }
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - OutputBlock — truncated output with show-more toggle

private struct OutputBlock: View {
    let text: String

    @State private var expanded = false

    /// How many lines we surface before collapsing the rest.
    private let previewLines = 12

    /// Strip the `[exit 0]` prefix when present — the badge already
    /// shows it, so re-rendering it in the body is just noise.
    private var displayText: String {
        ShellOutput.stripExitLine(from: text)
    }

    private var lines: [Substring] {
        displayText.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var hiddenCount: Int {
        max(0, lines.count - previewLines)
    }

    private var visibleText: String {
        if expanded || hiddenCount == 0 { return displayText }
        return lines.prefix(previewLines).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
                .tracking(0.5)

            Text(visibleText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Palette.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(expanded
                             ? "Hide"
                             : "Show \(hiddenCount) more line\(hiddenCount == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - ToolUseLine — single minimal action row
//
// One clean line per tool action: small category icon, sentence-case
// verb describing what was done, subtle trailing chevron. Tapping the
// row expands ToolDetailsView inline beneath it (shell command in a
// terminal block, output truncated to 12 lines, etc.). No background
// card, no accent-tinted circles, no status pills. Matches Claude
// Cowork's resting treatment — structural without screaming.

struct ToolUseLine: View {
    let state: ToolCallUIState
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    statusIcon
                    Text(actionLabel)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Palette.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.Palette.tertiary)
                        .opacity(hovering || expanded ? 1 : 0.5)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.18), value: expanded)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                ToolDetailsView(state: state)
                    .padding(.leading, 25)   // align with text column
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Small leading icon — category symbol when complete, animated
    /// spinner while running, error glyph on failure. No tinted circle
    /// background; reads as inline iconography rather than a badge.
    @ViewBuilder private var statusIcon: some View {
        switch state.status {
        case .pending:
            Circle()
                .stroke(Theme.Palette.tertiary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .running:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
        case .success:
            Image(systemName: ToolCategoryStyle.from(toolName: state.toolName).symbol)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.tertiary)
                .frame(width: 16, height: 16)
        case .failure:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.error)
                .frame(width: 16, height: 16)
        }
    }

    /// Context-rich, sentence-case action label. Present progressive
    /// while running ("Reading Kundepakke.pdf…"), past tense when done
    /// ("Read Kundepakke.pdf"). Pulls filename / query / URL host out
    /// of input args where possible.
    private var actionLabel: String {
        ToolActionLabel.label(for: state.toolName, status: state.status, input: state.input)
    }
}

// MARK: - Action labels (context-rich, running / past tense)
//
// Produces human-readable labels with as much context as we can pull
// from the tool's input arguments. So `read_file({"path":"/x/y/a.pdf"})`
// becomes "Read a.pdf" instead of just "Read file". For run_shell we
// pattern-match the command to guess intent ("Extracted PDF text",
// "Searched code") with a generic fallback when the command is too
// novel to classify.

private enum ToolActionLabel {
    static func label(for toolName: String, status: ToolCallStatus, input: String) -> String {
        let running = status == .running || status == .pending
        switch toolName {
        case "run_shell":
            return shellLabel(input: input, running: running)
        case "read_file", "read_file_range":
            return withFilename(verb: running ? "Reading" : "Read", path: stringField("path", in: input))
        case "write_file":
            return withFilename(verb: running ? "Writing" : "Wrote", path: stringField("path", in: input))
        case "apply_patch":
            return withFilename(verb: running ? "Editing" : "Edited", path: stringField("path", in: input))
        case "delete_file":
            return withFilename(verb: running ? "Deleting" : "Deleted", path: stringField("path", in: input))
        case "move_file":
            return running ? "Moving file…" : "Moved file"
        case "create_directory":
            return withFilename(verb: running ? "Creating" : "Created", path: stringField("path", in: input))
        case "list_directory":
            return withFilename(verb: running ? "Listing" : "Listed", path: stringField("path", in: input))
        case "glob_files":
            if let p = stringField("pattern", in: input) {
                return running ? "Searching for \(p)…" : "Searched for \(p)"
            }
            return running ? "Searching files…" : "Searched files"
        case "grep_code":
            if let p = stringField("pattern", in: input) ?? stringField("query", in: input) {
                return running ? "Searching code for \(p)…" : "Searched code for \(p)"
            }
            return running ? "Searching code…" : "Searched code"
        case "web_search":
            if let q = stringField("query", in: input) {
                return running ? "Searching the web for \(q)…" : "Searched the web for \(q)"
            }
            return running ? "Searching the web…" : "Searched the web"
        case "fetch_url":
            if let url = stringField("url", in: input), let host = URL(string: url)?.host {
                return running ? "Fetching \(host)…" : "Fetched \(host)"
            }
            return running ? "Fetching URL…" : "Fetched URL"
        case "fetch_rss":
            return running ? "Fetching RSS feed…" : "Fetched RSS feed"
        case "apple_docs_search":
            if let q = stringField("query", in: input) {
                return running ? "Searching Apple docs for \(q)…" : "Searched Apple docs for \(q)"
            }
            return running ? "Searching Apple docs…" : "Searched Apple docs"
        case "git_status":   return running ? "Checking git status…"      : "Checked git status"
        case "git_diff":     return running ? "Reading git diff…"         : "Read git diff"
        case "git_log":      return running ? "Reading git log…"          : "Read git log"
        case "git_show":     return running ? "Reading commit…"           : "Read commit"
        case "git_blame":    return running ? "Reading blame…"            : "Read blame"
        case "git_commit":
            if let msg = stringField("message", in: input) {
                let preview = msg.count > 40 ? String(msg.prefix(37)) + "…" : msg
                return running ? "Committing: \(preview)…" : "Committed: \(preview)"
            }
            return running ? "Making commit…" : "Made a commit"
        case "build_xcode", "swift_check", "run_xcode_tests",
             "build_swift_package":
            return running ? "Building project…" : "Built project"
        case "build_cargo":  return running ? "Building Cargo…" : "Built Cargo project"
        case "build_npm":    return running ? "Running npm…"    : "Ran npm"
        case "create_plan":  return running ? "Planning…"       : "Created plan"
        case "update_todo":  return running ? "Updating plan…"  : "Updated plan"
        case "tool_search":  return running ? "Looking up tools…" : "Looked up tools"
        case "worktree_create": return running ? "Creating worktree…" : "Created worktree"
        case "worktree_status": return running ? "Checking worktree…" : "Checked worktree"
        case "worktree_merge":  return running ? "Merging worktree…"  : "Merged worktree"
        case "extract_pdf_text":
            return withFilename(verb: running ? "Extracting PDF text from" : "Extracted PDF text from",
                                path: stringField("path", in: input))
        case "ocr_image":
            return withFilename(verb: running ? "Running OCR on" : "OCR'd",
                                path: stringField("path", in: input))
        case "create_pdf":
            return withFilename(verb: running ? "Creating PDF" : "Created PDF",
                                path: stringField("output_path", in: input))
        case "manipulate_pdf":
            if let action = stringField("action", in: input) {
                return running ? "PDF \(action)…" : "PDF \(action) done"
            }
            return running ? "Manipulating PDF…" : "Manipulated PDF"
        case "fill_pdf_form":
            return withFilename(verb: running ? "Filling PDF form" : "Filled PDF form",
                                path: stringField("input", in: input))
        case "sign_pdf":
            return withFilename(verb: running ? "Signing PDF" : "Signed PDF",
                                path: stringField("input", in: input))
        default:
            return running ? "Using \(toolName)…" : "Used \(toolName)"
        }
    }

    /// Pattern-matches `run_shell` commands to friendlier action
    /// descriptions. Falls back to "Ran shell command" when the
    /// command doesn't match any known heuristic.
    private static func shellLabel(input: String, running: Bool) -> String {
        guard let cmd = stringField("command", in: input) else {
            return running ? "Running shell command…" : "Ran shell command"
        }
        let lower = cmd.trimmingCharacters(in: .whitespaces).lowercased()

        // Document extraction
        if lower.contains("pdftotext") || (lower.contains("pypdf") || lower.contains("pdfminer")) {
            return running ? "Extracting PDF text…" : "Extracted PDF text"
        }
        if lower.hasPrefix("textutil") || lower.contains("docx2txt") {
            return running ? "Converting document…" : "Converted document"
        }
        // Filesystem queries
        if lower.hasPrefix("ls ") || lower == "ls" {
            return running ? "Listing directory…" : "Listed directory"
        }
        if lower.hasPrefix("cat ") || lower.hasPrefix("head ") || lower.hasPrefix("tail ") {
            return running ? "Reading file…" : "Read file"
        }
        if lower.hasPrefix("find ") {
            return running ? "Searching files…" : "Searched files"
        }
        if lower.hasPrefix("grep ") || lower.contains(" grep ") || lower.contains(" rg ") || lower.hasPrefix("rg ") {
            return running ? "Searching code…" : "Searched code"
        }
        if lower.hasPrefix("file ") {
            return running ? "Inspecting file…" : "Inspected file"
        }
        // Package mgmt
        if lower.hasPrefix("pip") || lower.contains(" pip install") {
            return running ? "Installing package…" : "Installed package"
        }
        if lower.hasPrefix("brew ") {
            return running ? "Running brew…" : "Ran brew"
        }
        if lower.hasPrefix("npm ") || lower.hasPrefix("yarn ") || lower.hasPrefix("pnpm ") {
            return running ? "Running package manager…" : "Ran package manager"
        }
        // Build / test
        if lower.hasPrefix("xcodebuild") {
            return running ? "Building Xcode project…" : "Built Xcode project"
        }
        if lower.hasPrefix("swift build") || lower.hasPrefix("swift test") {
            return running ? "Building Swift package…" : "Built Swift package"
        }
        if lower.hasPrefix("cargo ") {
            return running ? "Running cargo…" : "Ran cargo"
        }
        // Scripting
        if lower.hasPrefix("python3 -c") || lower.hasPrefix("python -c") {
            return running ? "Running Python…" : "Ran Python"
        }
        if lower.hasPrefix("python3 ") || lower.hasPrefix("python ") {
            return running ? "Running Python script…" : "Ran Python script"
        }
        if lower.hasPrefix("which ") {
            return running ? "Locating tool…" : "Located tool"
        }
        return running ? "Running shell command…" : "Ran shell command"
    }

    // MARK: - Argument helpers

    private static func withFilename(verb: String, path: String?) -> String {
        guard let path else { return "\(verb) file" }
        let name = basename(path)
        return "\(verb) \(name)"
    }

    private static func basename(_ path: String) -> String {
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }

    private static func stringField(_ key: String, in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}

// Legacy aggregator removed; kept as no-op shell for any stragglers.
private struct ToolUseBanner: View {
    let states: [ToolCallUIState]
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                summaryRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                hovering
                                    ? Theme.Palette.divider
                                    : Theme.Palette.divider.opacity(0.5),
                                lineWidth: 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(states) { state in
                        ToolUseRow(state: state)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            // Leading status indicator — animated spinner while any
            // tool is still running, otherwise a colored wrench glyph
            // in a tinted circle (matches Claude Cowork's leading
            // indicator pattern: clear surface, distinct color).
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.12))
                    .frame(width: 28, height: 28)
                if anyRunning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "wrench.adjustable.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Palette.accent)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(summaryText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Palette.primary)

                // Inline category-icon strip — quick scan of which
                // kinds of work happened (web, shell, files, git).
                if !uniqueCategories.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(uniqueCategories.indices, id: \.self) { i in
                            let cat = uniqueCategories[i]
                            Image(systemName: cat.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(cat.color)
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .animation(.easeInOut(duration: 0.2), value: expanded)
        }
    }

    private var summaryText: String {
        // Smart-ish phrasing: 1 tool → "Used 1 tool", more → "Used N tools".
        // Could grow into Claude's "Used 2 tools, edited a file" — saving
        // that for a second pass since it requires per-tool semantic
        // categorization beyond what we have today.
        let n = states.count
        return n == 1 ? "Used 1 tool" : "Used \(n) tools"
    }

    private var anyRunning: Bool {
        states.contains { $0.status == .running }
    }

    /// Unique category styles in the order they first appear. Used to
    /// render the inline icon-dot strip — gives the eye a 1-glance
    /// answer to "what kinds of work happened this turn?"
    private var uniqueCategories: [ToolCategoryStyle] {
        var seen = Set<String>()
        var result: [ToolCategoryStyle] = []
        for state in states {
            let cat = ToolCategoryStyle.from(toolName: state.toolName)
            if seen.insert(cat.symbol).inserted {
                result.append(cat)
            }
        }
        return result
    }
}

// MARK: - ToolUseRow — one row inside the expanded banner

private struct ToolUseRow: View {
    let state: ToolCallUIState
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    statusIcon
                    Text(actionName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.Palette.primary)
                    Spacer()
                    statusChip
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.18), value: expanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovering
                              ? Theme.Palette.surface
                              : Theme.Palette.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.Palette.divider.opacity(0.4), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)

            if expanded {
                ToolDetailsView(state: state)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        let category = ToolCategoryStyle.from(toolName: state.toolName)
        ZStack {
            Circle()
                .fill(category.color.opacity(state.status == .failure ? 0.0 : 0.14))
                .frame(width: 26, height: 26)
            switch state.status {
            case .pending:
                Circle()
                    .stroke(Theme.Palette.tertiary, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
            case .running:
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
            case .success:
                Image(systemName: category.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(category.color)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Palette.error)
            }
        }
    }

    @ViewBuilder private var statusChip: some View {
        switch state.status {
        case .pending:
            Text("Queued")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.divider.opacity(0.35)))
        case .running:
            Text("Running")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.accent.opacity(0.12)))
        case .success:
            if !state.output.isEmpty {
                Text("Result")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.Palette.divider.opacity(0.5)))
            }
        case .failure:
            Text("Failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Palette.error)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.error.opacity(0.15)))
        }
    }

    /// Sentence-case, plain-English label for what the tool did.
    /// Matches the conversational tone of Claude Cowork's "Task create
    /// / Task update / Edited" labels — never the raw wire name.
    private var actionName: String {
        switch state.toolName {
        case "run_shell":            return "Ran shell command"
        case "read_file",
             "read_file_range":      return "Read file"
        case "write_file":           return "Wrote file"
        case "apply_patch":          return "Edited file"
        case "delete_file":          return "Deleted file"
        case "move_file":            return "Moved file"
        case "create_directory":    return "Created directory"
        case "list_directory":       return "Listed directory"
        case "glob_files":           return "Found files"
        case "grep_code":            return "Searched code"
        case "web_search":           return "Searched the web"
        case "fetch_url":            return "Fetched URL"
        case "fetch_rss":            return "Fetched RSS feed"
        case "apple_docs_search":    return "Searched Apple docs"
        case "git_status":           return "Checked git status"
        case "git_diff":             return "Read git diff"
        case "git_log":              return "Read git log"
        case "git_show":             return "Read git commit"
        case "git_blame":            return "Read git blame"
        case "git_commit":           return "Made a commit"
        case "build_xcode":          return "Built Xcode project"
        case "swift_check":          return "Checked Swift build"
        case "run_xcode_tests":      return "Ran Xcode tests"
        case "build_swift_package":  return "Built Swift package"
        case "build_cargo":          return "Built Cargo project"
        case "build_npm":            return "Ran npm build"
        case "create_plan":          return "Created plan"
        case "update_todo":          return "Updated plan"
        case "tool_search":          return "Looked up tools"
        case "worktree_create":      return "Created worktree"
        case "worktree_status":      return "Checked worktree"
        case "worktree_merge":       return "Merged worktree"
        default:                     return state.toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - ToolDetailsView — the expanded row's input+output

private struct ToolDetailsView: View {
    let state: ToolCallUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.toolName == "run_shell",
               let command = ToolSummary.shellCommand(fromJSON: state.input) {
                ShellBlock(command: command,
                           exitCode: ShellOutput.exitCode(from: state.output))
            } else if !state.input.isEmpty {
                inputBlock
            }
            if !state.output.isEmpty {
                OutputBlock(text: state.output)
            }
        }
    }

    @ViewBuilder private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Input")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Palette.tertiary)
                .tracking(0.5)
            Text(state.input)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Palette.secondary)
                .lineLimit(20)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Tool category styling
//
// Maps a tool wire-name to (SF Symbol, tint color). Used by the
// ToolUseBanner's inline category dot strip and by ToolUseRow's
// per-row icon. Categorization is purely by string match — keeps
// us independent of AgentCore's internal `category` enum and lets
// new tools opt in with one extra case.

struct ToolCategoryStyle {
    let symbol: String
    let color: Color

    static func from(toolName: String) -> ToolCategoryStyle {
        switch toolName {
        case "web_search", "fetch_url", "fetch_rss":
            return .init(symbol: "globe", color: .blue)
        case "apple_docs_search":
            return .init(symbol: "book", color: .blue)
        case "run_shell":
            return .init(symbol: "terminal.fill", color: .green)
        case "git_status", "git_diff", "git_log", "git_show",
             "git_blame", "git_commit",
             "worktree_create", "worktree_status", "worktree_merge":
            return .init(symbol: "arrow.triangle.branch", color: .purple)
        case "read_file", "read_file_range", "write_file", "apply_patch",
             "delete_file", "move_file", "create_directory",
             "list_directory", "glob_files":
            return .init(symbol: "doc.text", color: Theme.Palette.tertiary)
        case "grep_code":
            return .init(symbol: "text.magnifyingglass", color: Theme.Palette.tertiary)
        case "build_xcode", "swift_check", "run_xcode_tests",
             "build_swift_package", "build_cargo", "build_npm":
            return .init(symbol: "hammer.fill", color: .orange)
        case "create_plan", "update_todo":
            return .init(symbol: "checklist", color: .indigo)
        case "tool_search":
            return .init(symbol: "questionmark.diamond", color: .gray)
        default:
            return .init(symbol: "wrench.adjustable", color: Theme.Palette.tertiary)
        }
    }
}

// MARK: - ThoughtProcessBlock (unused — superseded by ZCodeActivityStack)
// Kept only if something still references the type; strip in Phase 1 dead-code pass.

struct ThoughtProcessBlock: View {
    let states: [ToolCallUIState]
    var isStreaming: Bool = false

    @State private var expanded: Bool = false

    private var doneCount: Int {
        states.filter { $0.status == .success }.count
    }

    private var runningCount: Int {
        states.filter { $0.status == .running }.count
    }

    private var pendingCount: Int {
        states.filter { $0.status == .pending }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                    if runningCount > 0 {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 14, height: 14)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.Palette.subtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                let spec = StepperRailSpec.standard
                let rowHeights = stepRowHeights(for: states, spec: spec)
                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if states.count > 1 {
                            Rectangle()
                                .fill(Theme.Palette.divider.opacity(0.6))
                                .frame(width: 1)
                                .frame(height: spec.connectorHeight(rowHeights: rowHeights))
                                .offset(
                                    x: spec.lineHorizontalOffset,
                                    y: spec.iconCenterY
                                )
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                                stepIcon(state.status)
                                    .frame(
                                        width: spec.iconColumnWidth,
                                        height: spec.iconSize
                                    )
                                    .frame(height: rowHeights[index], alignment: spec.iconFrameAlignment)
                            }
                        }
                    }
                    .frame(width: spec.iconColumnWidth)

                    VStack(spacing: 0) {
                        ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                            stepContentRow(state)
                                .frame(height: rowHeights[index], alignment: spec.iconFrameAlignment)
                        }
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            if isStreaming { expanded = true }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeOut(duration: 0.2)) { expanded = true }
            } else if doneCount == states.count {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { expanded = false }
            }
        }
    }

    @ViewBuilder
    private func stepContentRow(_ state: ToolCallUIState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stepLabel(state))
                    .font(.system(size: 12, weight: state.status == .running ? .medium : .regular))
                    .foregroundStyle(state.status == .running
                                     ? Theme.Palette.primary
                                     : Theme.Palette.secondary)
                if let sub = stepSubtitle(state), !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stepIcon(_ status: ToolCallStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .stroke(Theme.Palette.tertiary, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.success)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.error)
        case .running:
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 3)
                        .scaleEffect(1.6)
                        .opacity(0.8)
                )
        }
    }

    private func stepLabel(_ state: ToolCallUIState) -> String {
        ArtifactLabel.activityLabel(toolName: state.toolName, argsJSON: state.input)
    }

    private func stepSubtitle(_ state: ToolCallUIState) -> String? {
        let desc = ArtifactLabel.make(toolName: state.toolName, argsJSON: state.input, output: state.output)
        return desc.subtitle
    }

    private func stepRowHeights(for states: [ToolCallUIState], spec: StepperRailSpec) -> [CGFloat] {
        states.map { state in
            let hasSubtitle = !(stepSubtitle(state)?.isEmpty ?? true)
            return spec.rowHeight(hasSubtitle: hasSubtitle)
        }
    }

    private var summary: String {
        let n = states.count
        if runningCount > 0 {
            return "Thought process · \(n) steps · \(runningCount) running"
        }
        if pendingCount > 0 {
            return "Thought process · \(n) steps · \(pendingCount) queued"
        }
        return "Thought process · \(n) steps · \(doneCount) done"
    }
}

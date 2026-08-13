//
//  ChatLoop.swift
//
//  Pure, side-effect-free helpers used to drive a chat turn. NOT an
//  orchestrator — the orchestrator is `AgentLoop`. The two are
//  complementary, not parallel:
//
//    * `AgentLoop` is the runtime: it streams the model, dispatches
//      tools, owns iteration state, persists conversation rows.
//    * `ChatLoop` is a namespace of stateless helpers that the
//      orchestrator (or anything else that drives a turn) calls into
//      for the LOGIC bits that are easier to test in isolation:
//      context compaction, stall/loop detection, the verify-before-
//      finish gates, project-memory injection, malformed-args
//      detection, tool-name spell-correction, the current-date system
//      block.
//
//  In the DEV PLAN these helpers were extracted from `ChatViewModel`
//  for exactly the same reason — they're a function of inputs, not of
//  view state, so they belong in a place a unit test can reach without
//  a main-actor environment.
//
//  Adaptation notes vs. DEV PLAN:
//    * AgentCore's `ChatMessage.toolCalls` is `[ToolCallInvocation]`
//      (non-optional; `.name` / `.arguments` are top-level), where the
//      DEV PLAN used `[ToolCall]?` with `.function.name` /
//      `.function.arguments`. The helpers below operate on AgentCore's
//      shape directly.
//    * AgentCore's `ChatMessage` does NOT currently carry a `plan:`
//      field. Where the DEV PLAN scanned `messages.last { $0.plan != nil }`,
//      we substitute a tool-call signature heuristic: a message
//      "owns" a plan iff one of its tool calls is `create_plan` or
//      `update_todo`. Once a structured `plan` field lands on
//      `ChatMessage`, switch these helpers over to that.
//    * `ModelPreset` doesn't exist in AgentCore yet — `iterationCap`
//      takes a plain `Int` cap from the caller's preset / catalog.
//    * `loadProjectMemory` works against a `URL?` instead of a
//      `String?` path — that's what `Conversation.projectRoot` carries.
//
//  Everything in this file is `Sendable`-safe and free of any
//  AppKit / SwiftUI surface — just Foundation.
//

import Foundation

public enum ChatLoop {

    // MARK: - parseToolArgs

    /// Parse a tool-call arguments string into a dictionary. Malformed
    /// JSON returns an empty dict — callers should treat that as the
    /// model's error and respond accordingly (see `isMalformedToolArguments`).
    public static func parseToolArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    // MARK: - iterationCap

    /// Effective max iterations per turn = MIN of the user's global
    /// setting and the preset's recommended cap. Never override a preset
    /// upward — the preset is the model class's recommendation, not the
    /// floor.
    ///
    /// In AgentCore the cap is passed as a plain `Int` rather than a
    /// `ModelPreset` (which doesn't exist in AgentCore yet); the caller
    /// resolves the preset and hands the number in.
    public static func iterationCap(settingsCap: Int, presetCap: Int) -> Int {
        max(1, min(settingsCap, presetCap))
    }

    // MARK: - tool-call accounting

    /// Total tool calls made by the assistant across the conversation so
    /// far. Used in headless-mode summaries.
    public static func recentToolCallCount(messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.toolCalls.count }
    }

    // MARK: - Plan-bearing messages (heuristic)

    /// Names of tool calls that signal a message "owns" plan state.
    /// `create_plan` introduces a plan; `update_todo` mutates one. Used
    /// as the stand-in for the DEV PLAN's `message.plan != nil` check.
    /// `internal` (not `private`) so `AgentLoop`'s inline stall-signature
    /// path can exclude these too — a model re-issuing the same plan
    /// update across iterations is progress, not a stall.
    public static let planAuthoringTools: Set<String> = [
        "create_plan", "update_todo", "revise_plan"
    ]

    /// Index of the most recent message whose tool calls authored or
    /// updated a plan. Returns nil when no plan has been emitted yet.
    public static func mostRecentPlanIndex(messages: [ChatMessage]) -> Int? {
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if messages[i].toolCalls.contains(where: { planAuthoringTools.contains($0.name) }) {
                return i
            }
        }
        return nil
    }

    // MARK: - summariseCompletion

    /// Short summary string for the completion notification. Falls back
    /// from a plan summary to the last assistant reply snippet to "".
    ///
    /// NOTE: until `ChatMessage` carries a parsed `Plan`, the plan-summary
    /// branch can't render goal/progress — the message only tells us a
    /// plan was emitted, not its contents. So we currently use the
    /// assistant-reply fallback as the primary path.
    public static func summariseCompletion(messages: [ChatMessage]) -> String {
        if let last = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) {
            let oneLine = last.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
        }
        return ""
    }

    // MARK: - headlessPrologue

    /// System-prompt block injected for the whole turn when the
    /// conversation runs in Headless (unattended) mode. The user isn't
    /// watching, so there's no one to answer `ask_user` or to catch a
    /// risky action mid-flight — the model must self-govern. Paired with
    /// `buildHeadlessSummary`, which is appended when the turn ends.
    public static let headlessPrologue = """
    # Headless mode — you are running UNATTENDED

    No human is watching this run. There is no one to confirm a risky action or answer a question mid-task. Govern yourself accordingly:
    1. Be conservative with destructive or irreversible actions. Prefer additive edits; never delete files, force-push, or run destructive shell commands unless the task explicitly and unambiguously requires it.
    2. Do not wait for confirmation you will never receive. If you genuinely need a decision only the user can make, stop and explain what you need rather than guessing on something irreversible.
    3. Verify as you go — read files back, run the build — because no one will catch a mistake before it compounds.
    4. Work toward a clean stopping point. When you finish (or hit a wall), end with a clear status the user can read in the morning.
    """

    // MARK: - buildHeadlessSummary

    /// Markdown final-summary message appended at the end of a headless
    /// agent turn. Without `Plan` attached to `ChatMessage` we can't
    /// surface goal/progress — falls back to a tool-call stats line.
    public static func buildHeadlessSummary(messages: [ChatMessage],
                                            worktreePath: String?,
                                            iterations: Int,
                                            hitCap: Bool) -> String {
        var out = "## Headless run — summary\n\n"
        let toolCount = recentToolCallCount(messages: messages)
        out += "**Stats:** \(iterations) iteration\(iterations == 1 ? "" : "s"), \(toolCount) tool call\(toolCount == 1 ? "" : "s")."
        if hitCap { out += " Halted at iteration cap." }
        if let wt = worktreePath {
            out += "\n\n**Worktree:** changes are isolated in `\(wt)`. Use the Worktree button in the header to review and merge or discard."
        }
        return out
    }

    // MARK: - loadProjectMemory

    /// Default per-file character cap. Caps each of `MEMORY.md`,
    /// `DECISIONS.md`, and `SESSION_HANDOFF.md` so the system prompt
    /// doesn't balloon when projects accumulate long histories.
    public static let projectMemoryFileCap = 8_000

    /// Reads `MEMORY.md`, `DECISIONS.md`, and `SESSION_HANDOFF.md` from
    /// `projectRoot` and returns a formatted system-prompt block.
    /// Returns `nil` when `projectRoot` is nil or no files are present.
    ///
    /// Cross-session continuity: prior sessions write these via the
    /// `memory` tool (`log_decision`, `write_handoff`, `remember`) and
    /// the next turn injects them when `injectProjectMemory` is on.
    ///
    /// `cap` defaults to `projectMemoryFileCap`. Hard floor is 500 chars.
    public static func loadProjectMemory(projectRoot: URL?,
                                         cap: Int = projectMemoryFileCap,
                                         fileManager: FileManager = .default) -> String? {
        guard let dir = projectRoot else { return nil }
        let effectiveCap = max(500, cap)

        func readCapped(_ filename: String) -> String? {
            let path = dir.appendingPathComponent(filename).path
            guard fileManager.fileExists(atPath: path),
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.count <= effectiveCap { return trimmed }
            // Keep the tail — decisions accumulate at the bottom of the log.
            let tail = String(trimmed.suffix(effectiveCap))
            return "…(truncated, showing last \(effectiveCap) chars)…\n\n" + tail
        }

        let memory = readCapped("MEMORY.md")
        let decisions = readCapped("DECISIONS.md")
        // Handoff: dedicated smaller cap (avoid double-truncate via readCapped then re-slice).
        let handoffCap = min(effectiveCap, 4_000)
        let handoff: String? = {
            let path = dir.appendingPathComponent("SESSION_HANDOFF.md").path
            guard fileManager.fileExists(atPath: path),
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.count <= handoffCap { return trimmed }
            return "…(truncated, showing last \(handoffCap) chars)…\n\n" + String(trimmed.suffix(handoffCap))
        }()
        if memory == nil && decisions == nil && handoff == nil { return nil }

        var out = "# Project memory (auto-loaded)\n\nThe following notes were carried forward from prior sessions in this project. Treat them as load-bearing context — they encode decisions, constraints, and lessons that aren't otherwise visible in the code. Don't re-derive what's already here; if something is stale, update the file rather than ignoring it."
        if let h = handoff {
            out += "\n\n## SESSION_HANDOFF.md\n\n" + h
        }
        if let m = memory {
            out += "\n\n## MEMORY.md\n\n" + m
        }
        if let d = decisions {
            let entries = parseDecisionEntries(d)
            let recentCap = 3
            if entries.count > recentCap, let recent = extractRecentDecisions(from: d, limit: recentCap) {
                out += "\n\n## DECISIONS.md (recent entries)\n\n" + recent
            } else {
                out += "\n\n## DECISIONS.md\n\n" + d
            }
        }
        return out
    }

    // MARK: - loadProjectInstructions

    /// Relative path, inside a project folder, of the user's standing
    /// instructions for that project. Written by the "New Project" sheet's
    /// Instructions field; editable by hand. Namespaced under `.agentos/`
    /// so it never collides with the user's own files.
    public static let projectInstructionsRelativePath = ".agentos/instructions.md"

    /// Per-project standing instructions, formatted for the system prompt.
    ///
    /// Always injected when present (non-raw mode). Separate from hybrid
    /// memory (`injectProjectMemory` / AppSupport MEMORY.md), which is
    /// also on by default but flag-gated. Returns nil when `projectRoot`
    /// is nil or the file is missing/empty.
    public static func loadProjectInstructions(projectRoot: URL?,
                                               cap: Int = 4_000,
                                               fileManager: FileManager = .default) -> String? {
        guard let root = projectRoot else { return nil }
        let path = root.appendingPathComponent(projectInstructionsRelativePath).path
        guard fileManager.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let effectiveCap = max(200, cap)
        let body = trimmed.count > effectiveCap
            ? String(trimmed.prefix(effectiveCap)) + "\n…(truncated)"
            : trimmed
        return """
        # Project instructions

        The user set these standing instructions for this project. Treat them as binding — follow them in everything you do here, and prefer them over your defaults when they conflict.

        \(body)
        """
    }

    // MARK: - loadAgentsMd

    /// Hierarchical project-rules discovery (Wave B S8).
    ///
    /// Loads AGENTS.md / CLAUDE.md / Cursor aliases and `.claude/rules` /
    /// `.cursor/rules` from `projectRoot` down to `cwd` (defaults to root).
    /// Prefer this over a single root file so nested monorepo rules apply.
    ///
    /// Returns nil when `projectRoot` is nil or no rule files exist.
    public static func loadAgentsMd(projectRoot: URL?,
                                    cwd: URL? = nil,
                                    cap: Int = ProjectRules.defaultMaxChars,
                                    fileManager: FileManager = .default) -> String? {
        guard let root = projectRoot else { return nil }
        let effectiveCwd = cwd ?? root
        let snap = ProjectRules.load(
            projectRoot: root,
            cwd: effectiveCwd,
            includeHomeRules: true,
            maxChars: max(500, cap),
            fileManager: fileManager)
        return snap.injectedText.isEmpty ? nil : snap.injectedText
    }

    // MARK: - currentDateNotice

    /// Cached DateFormatter — allocation is expensive (ICU init), so we
    /// create it once and reuse. A `static let` is immutable shared state
    /// (Sendable-safe under StrictConcurrency), and `DateFormatter`'s
    /// `string(from:)` is itself thread-safe, so concurrent agent turns
    /// can format against it without coordination. We deliberately do NOT
    /// cache the formatted string in a mutable static — that was a data
    /// race (two turns formatting at once tore the day/string pair) for a
    /// saving of one `.string(from:)` call per turn, which is negligible.
    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    /// System-prompt header that pins the model's notion of "now" to the
    /// actual current date and enforces sourcing discipline against
    /// stale attributions from training-cutoff memory.
    public static func currentDateNotice(now: Date = Date()) -> String {
        let today = _dateFormatter.string(from: now)
        return """
        # Current date

        Today is \(today). Interpret "today", "now", "this year", "latest", and "recent" relative to this date — not your training cutoff.

        # Sourcing

        Your training data is out of date. NEVER name a person, leader, or office-holder unless the tool result explicitly names them. When uncertain, say so — "the results don't specify who" beats guessing. Prefer `fetch_url` over snippets for any factual claim.
        """
    }

    // MARK: - compactHistory

    /// Rough per-message token estimate (content + any tool-call
    /// arguments).
    public static func estimateMessageTokens(_ m: ChatMessage) -> Int {
        // Wire-oriented estimate: do NOT count reasoningContent — OpenAI-compat
        // wire encoding omits it (see WireMessage.from), so counting it caused
        // premature FullReplace/Semantic compaction on thinking models.
        var t = TokenEstimator.estimate(m.content)
        // Vision: coarse base64→token proxy (real vision tokens are resolution-based).
        for img in m.images {
            t += max(85, img.base64Data.utf8.count / 16)
        }
        for c in m.toolCalls {
            t += TokenEstimator.estimate(c.name)
            t += TokenEstimator.estimate(c.arguments)
        }
        // Fixed per-message role/framing overhead (OpenAI-style chat).
        t += 4
        return t
    }

    /// Total prompt tokens for a system-prompt size plus a message list.
    public static func estimateTotalTokens(systemPromptTokens: Int, messages: [ChatMessage]) -> Int {
        systemPromptTokens + messages.reduce(0) { $0 + estimateMessageTokens($1) }
    }

    /// Returns a context-fitted copy of `messages` for sending to the
    /// model. Context-window management is what lets a long agentic
    /// run survive on a local model with a small context window:
    /// without it, every iteration resends the entire growing transcript
    /// until the model overflows.
    ///
    /// Strategy — ELISION ONLY, never structural removal, so the
    /// assistant↔tool `tool_call_id` pairing strict OpenAI-compatible
    /// servers require is never broken:
    ///   1. If the estimate already fits `budgetTokens`, return
    ///      unchanged.
    ///   2. Otherwise walk the OLDER region (everything before the last
    ///      `keepRecent` messages) and replace large `.tool` bodies with
    ///      a short head + elision marker, stopping as soon as we're
    ///      under budget.
    ///   3. If still over, do the same to old `.assistant` prose
    ///      (tool-call structure stays intact — only `content` is
    ///      trimmed).
    ///
    /// NEVER touched: user messages, the most recent `keepRecent`
    /// messages, plan-authoring messages, and every message's structural
    /// fields. The caller keeps the full, un-compacted history for the
    /// UI and persistence — this copy is for the wire only.
    public static func compactHistory(_ messages: [ChatMessage],
                                      systemPromptTokens: Int,
                                      budgetTokens: Int,
                                      keepRecent: Int = 6,
                                      elideCap: Int = 240) -> [ChatMessage] {
        guard budgetTokens > 0,
              estimateTotalTokens(systemPromptTokens: systemPromptTokens, messages: messages) > budgetTokens
        else { return messages }

        var working = messages
        let protectedFrom = max(0, working.count - keepRecent)

        // Bucket the size hint to 1000-char granularity so the marker
        // doesn't change byte-for-byte every time the transcript grows
        // by a few chars (preserves KV-cache hits on the elided content).
        func elide(_ s: String, kind: String) -> String {
            let bucket = (s.count / 1000) * 1000
            return String(s.prefix(elideCap))
                + "\n\n[…\(kind) elided to fit the context window — ~\(bucket) chars in the saved transcript]"
        }

        // Maintain a running token total instead of re-scanning the full
        // message array on every elision check (O(N²) → O(N)).
        var runningTokens = estimateTotalTokens(
            systemPromptTokens: systemPromptTokens, messages: working)

        func underBudget() -> Bool { runningTokens <= budgetTokens }

        // Phase 1: elide old, large tool outputs (the dominant token cost).
        for i in 0..<protectedFrom where working[i].role == .tool {
            if underBudget() { return working }
            let old = working[i].content
            if old.count > elideCap {
                let replacement = elide(old, kind: "tool output")
                let delta = TokenEstimator.estimate(old) - TokenEstimator.estimate(replacement)
                working[i].content = replacement
                runningTokens -= delta
            }
        }

        // Phase 2: still over → trim old assistant prose. Tool-call
        // structure stays intact; user messages and plan-authoring
        // messages are never touched.
        for i in 0..<protectedFrom where working[i].role == .assistant
            && !working[i].toolCalls.contains(where: { planAuthoringTools.contains($0.name) }) {
            if underBudget() { return working }
            let old = working[i].content
            if old.count > elideCap {
                let replacement = elide(old, kind: "assistant message")
                let delta = TokenEstimator.estimate(old) - TokenEstimator.estimate(replacement)
                working[i].content = replacement
                runningTokens -= delta
            }
        }

        return working
    }

    // MARK: - Stall detection & self-correction

    /// Signature of ALL non-plan tool calls in the most recent assistant
    /// turn, order-independent (sorted) so "read A, read B" and
    /// "read B, read A" hash the same. nil when the last assistant turn
    /// made no tool calls (or only plan calls — repeated plan updates
    /// are normal progress, not a stall).
    public static func turnToolSignature(messages: [ChatMessage]) -> String? {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }),
              !lastAssistant.toolCalls.isEmpty else { return nil }
        let sigs = lastAssistant.toolCalls
            .filter { !planAuthoringTools.contains($0.name) }
            .map { "\($0.name)(\(canonicalJSONArguments($0.arguments)))" }
            .sorted()
        guard !sigs.isEmpty else { return nil }
        return sigs.joined(separator: " + ")
    }

    /// Normalize tool-call argument JSON for stall / governor comparison.
    /// Stable key order so `{"b":1,"a":2}` and `{"a":2,"b":1}` match.
    public static func canonicalJSONArguments(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let normalized = try? JSONSerialization.data(
                withJSONObject: obj, options: [.sortedKeys])
        else {
            return trimmed
        }
        return String(data: normalized, encoding: .utf8) ?? trimmed
    }

    /// Detect a stalled agent from a rolling window of recent
    /// turn-signatures (oldest → newest). Returns a human-readable
    /// reason when stuck, else nil.
    ///   • repetition — the last 3 turns issued identical tool call(s);
    ///   • ping-pong — the last 4 alternate between exactly two
    ///     call-sets (A B A B).
    /// The caller maintains the window (append each non-nil
    /// `turnToolSignature`, trim to ~6) so this stays pure.
    public static func detectStuckPattern(_ window: [String],
                                          repetitionThreshold: Int = 3) -> String? {
        guard repetitionThreshold >= 2 else { return nil }
        if window.count >= repetitionThreshold,
           Set(window.suffix(repetitionThreshold)).count == 1 {
            return "repeated the same tool call \(repetitionThreshold) times in a row (`\(window.last!)`)"
        }
        if window.count >= 4 {
            let w = Array(window.suffix(4))
            if w[0] == w[2], w[1] == w[3], w[0] != w[1] {
                return "alternated between two tool calls without progress (`\(w[0])` ↔ `\(w[1])`)"
            }
        }
        return nil
    }

    /// True when recent tool results show the agent failing repeatedly —
    /// the trigger for a self-correction nudge. `flags` is the trailing
    /// window of tool-result `isError` values (true = errored).
    public static func shouldNudgeReflection(recentToolErrorFlags flags: [Bool], threshold: Int = 3) -> Bool {
        guard threshold > 0, flags.count >= threshold else { return false }
        return flags.suffix(threshold).allSatisfy { $0 }
    }

    /// System-prompt block injected for one iteration when
    /// `shouldNudgeReflection` fires. Pushes the model to break the
    /// failure loop by re-grounding rather than retrying blindly.
    public static let reflectionNudge = """
    # Course-correction (your recent tool calls kept failing)

    Several recent tool calls failed in a row. Do NOT repeat the same approach. Before your next action:
    1. Re-read the relevant file(s) from scratch with `read_file` — your assumption about the current state is likely wrong.
    2. Read the error message literally — what does it actually say is wrong?
    3. Change strategy. A call that failed twice will fail a third time unchanged.
    If you cannot make progress after rethinking, say so honestly and stop — do not keep looping.
    """

    // MARK: - Anti-confabulation (verify-before-finish)

    /// True when the agent is finalizing right after a failed tool call
    /// AND its answer reads like an unverified success claim — the actual
    /// confabulation case this gate exists to catch.
    ///
    /// The trailing-failure check alone over-fired: a read-only command
    /// that legitimately returns non-zero (`ls` of an empty dir, `grep`
    /// with no match) flags `isError`, and an HONEST final answer ("I
    /// can't … the directory is empty") doesn't need re-grounding. Forcing
    /// a pass there just makes the model repeat itself — a visible
    /// duplicate, observed 2026-06-10. So we additionally require that the
    /// answer claims success without hedging.
    public static func shouldVerifyBeforeFinish(recentToolErrorFlags flags: [Bool],
                                                finalAssistantContent: String) -> Bool {
        guard flags.last == true else { return false }
        return claimsUnverifiedSuccess(finalAssistantContent)
    }

    /// Heuristic: does `text` assert something was accomplished WITHOUT
    /// hedging that it failed/couldn't/was empty? Conservative on purpose
    /// — when in doubt it returns false (don't force a redundant pass),
    /// because a false "done!" is the only thing worth catching here and
    /// an honest answer never is.
    public static func claimsUnverifiedSuccess(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Candor markers — the model is owning a failure/limitation.
        let honest = ["can't", "can’t", "cannot", "couldn't", "couldn’t",
                      "could not", "unable", "not able", "no such", "not found",
                      "doesn't", "does not", "is empty", "was empty", "failed",
                      "error", "no match", "wasn't able", "was not able"]
        if honest.contains(where: { lower.contains($0) }) { return false }
        // Success-claim markers. Skip a hit preceded by "not " / "n't "
        // so "I have not completed the task" is not a success claim.
        let claims = ["done", "all set", "successfully", "completed", "created",
                      " passed", "fixed", "works now", "is working",
                      "tests pass", "build succeeded", "all good"]
        return claims.contains(where: { containsUnnegatedClaim($0, in: lower) })
    }

    /// True when `needle` appears in `lower` without a "not " / "n't " prefix.
    private static func containsUnnegatedClaim(_ needle: String, in lower: String) -> Bool {
        var search = lower.startIndex
        while let range = lower.range(of: needle, range: search..<lower.endIndex) {
            let prefix = lower[..<range.lowerBound]
            if !prefix.hasSuffix("not ") && !prefix.hasSuffix("n't ") {
                return true
            }
            search = range.upperBound
        }
        return false
    }

    /// System-prompt block injected for ONE extra iteration when the
    /// model tries to finalize right after a failed tool call.
    public static let groundingNudge = """
    # Verify before you finish — do NOT fabricate an outcome

    Your last tool call FAILED, yet you are about to end your turn. Stop. Before you give a final answer:
    1. Re-check the ACTUAL state with a tool. If you claimed to create a file, call `read_file` / `list_directory` to confirm it exists. If you claimed a build or tests passed, run the command and read its real output.
    2. Report only what the tool results actually show. If the file isn't there or the command failed, say so plainly — "I was not able to create the file; here is the error" — rather than declaring success.
    3. NEVER report success you have not confirmed with a tool. "All tests passed", "done", "created successfully" are forbidden unless a tool result in this conversation proves it. A truthful failure is correct; a fabricated success is a critical error.
    """

    // MARK: - Edit-verification gate

    /// Tools that mutate filesystem or project state. When the agent
    /// uses any of these and then tries to finalize without further
    /// verification, the edit-verification gate forces one extra
    /// grounding pass.
    ///
    /// Builtin tools hidden when Xcode MCP is live — MCP provides equivalents.
    public static let xcodeMCPSupersededBuiltins: Set<String> = [
        "xcode_build",
    ]

    /// True if any assistant turn from `turnStartIndex` onward used at
    /// least one mutating tool from the registry-derived classification.
    public static func didEditFilesThisTurn(messages: [ChatMessage],
                                            turnStartIndex: Int,
                                            mutatingToolNames: Set<String>) -> Bool {
        guard turnStartIndex >= 0, turnStartIndex < messages.count else { return false }
        for i in turnStartIndex..<messages.count where messages[i].role == .assistant {
            for call in messages[i].toolCalls {
                if mutatingToolNames.contains(call.name) { return true }
            }
        }
        return false
    }

    /// Marker substring for BuildGuard success (user-role system reminder or legacy tool row).
    public static let buildGuardSucceededMarker = "BuildGuard: build succeeded"

    /// True when message content is a BuildGuard success notice (any role).
    public static func isBuildGuardSuccessMessage(_ m: ChatMessage) -> Bool {
        if m.content.contains(buildGuardSucceededMarker) { return true }
        // Legacy orphan tool rows used toolCallID "buildguard" with success body.
        if m.role == .tool, m.toolCallID == "buildguard",
           m.content.lowercased().contains("succeeded") || m.content.lowercased().contains("success") {
            return true
        }
        return false
    }

    public static func editAlreadyVerifiedThisTurn(messages: [ChatMessage],
                                                   turnStartIndex: Int,
                                                   mutatingToolNames: Set<String>,
                                                   verificationToolNames: Set<String>) -> Bool {
        guard turnStartIndex >= 0, turnStartIndex < messages.count else { return false }
        var lastEditIdx = -1
        for i in turnStartIndex..<messages.count where messages[i].role == .assistant {
            if messages[i].toolCalls.contains(where: { mutatingToolNames.contains($0.name) }) {
                lastEditIdx = i
            }
        }
        guard lastEditIdx >= 0 else { return false }
        for i in lastEditIdx..<messages.count {
            let m = messages[i]
            if m.role == .assistant,
               m.toolCalls.contains(where: { verificationToolNames.contains($0.name) }) {
                return true
            }
            // BuildGuard success as user-role system reminder (preferred) or legacy tool row.
            if i > lastEditIdx, isBuildGuardSuccessMessage(m) {
                return true
            }
        }
        return false
    }

    /// Tool result `toolCallID`s that never appear in any assistant `tool_calls`.
    /// Strict OpenAI-compatible servers reject histories with these orphans.
    public static func unpairedToolResultIDs(in messages: [ChatMessage]) -> [String] {
        var declared = Set<String>()
        for m in messages where m.role == .assistant {
            for tc in m.toolCalls where !tc.id.isEmpty {
                declared.insert(tc.id)
            }
        }
        var unpaired: [String] = []
        for m in messages where m.role == .tool {
            guard let id = m.toolCallID, !id.isEmpty else {
                unpaired.append("(missing toolCallID)")
                continue
            }
            if !declared.contains(id) {
                unpaired.append(id)
            }
        }
        return unpaired
    }

    /// Assistant `tool_calls` IDs that still lack a matching tool-result
    /// message. The inverse of `unpairedToolResultIDs` — strict servers also
    /// reject dangling tool_calls without results.
    public static func unclosedToolCallIDs(in messages: [ChatMessage]) -> [String] {
        var resultIDs = Set<String>()
        for m in messages where m.role == .tool {
            if let id = m.toolCallID, !id.isEmpty {
                resultIDs.insert(id)
            }
        }
        var unclosed: [String] = []
        for m in messages where m.role == .assistant {
            for tc in m.toolCalls where !tc.id.isEmpty {
                if !resultIDs.contains(tc.id) {
                    unclosed.append(tc.id)
                }
            }
        }
        return unclosed
    }

    /// True when every tool_call has a result and no result is orphaned.
    public static func toolCallPairingIsValid(in messages: [ChatMessage]) -> Bool {
        unpairedToolResultIDs(in: messages).isEmpty
            && unclosedToolCallIDs(in: messages).isEmpty
    }

    public static func shouldVerifyEdits(messages: [ChatMessage],
                                         turnStartIndex: Int,
                                         mutatingToolNames: Set<String>,
                                         verificationToolNames: Set<String>,
                                         alreadyVerified: Bool) -> Bool {
        guard !alreadyVerified else { return false }
        guard let last = messages.last,
              last.role == .assistant,
              last.toolCalls.isEmpty else { return false }
        guard didEditFilesThisTurn(messages: messages,
                                   turnStartIndex: turnStartIndex,
                                   mutatingToolNames: mutatingToolNames) else { return false }
        return !editAlreadyVerifiedThisTurn(messages: messages,
                                            turnStartIndex: turnStartIndex,
                                            mutatingToolNames: mutatingToolNames,
                                            verificationToolNames: verificationToolNames)
    }

    /// System-prompt block injected for ONE extra iteration when the
    /// model tries to finalize after editing files without verifying
    /// the result.
    public static let verifyEditsNudge = """
    # Verify your edits — do NOT finalize without checking

    You edited files this turn and are about to finish. Before your final answer:

    1. If a `BuildGuard: build succeeded` tool message already appears above, the project COMPILES — that is sufficient build verification. Do not re-run xcodebuild/swift build unless you changed code after that message.
    2. If you see `BuildGuard: build failed`, fix the errors (edit + wait for BuildGuard, or `run_shell` / `xcode_build`) before finishing.
    3. If there is no BuildGuard row yet and you created a buildable project, run a quick build (`xcode_build` or `run_shell` with xcodebuild/swift build) OR make one more small edit so automatic BuildGuard runs.
    4. Optionally `read_file` or `git_diff` only if you need to confirm a specific change — not a full re-audit of every file when BuildGuard already passed.

    Report only what tools show. Truthful "build still fails" beats fabricated "all done."
    """

    /// Stronger second-strike version for repeated verify-edit skips.
    public static let verifyEditsNudgeEscalated = """
    # CRITICAL: You skipped edit verification AGAIN

    You have now tried to finalize multiple times without verifying your edits. This is a critical harness violation. You MUST:

    1. Call `read_file` on every file you changed this turn.
    2. Call `git_diff` to audit total changeset.
    3. If a build failure appeared above: call `run_shell` with the build command and read the output.

    Do NOT write a final answer until you have done all three. Fabricated success is categorically unacceptable.
    """

    /// Stronger second-strike version for repeated grounding failures.
    public static let groundingNudgeEscalated = """
    # CRITICAL: You are fabricating an outcome — second warning

    You have now claimed success after a failed tool call more than once in this turn. This is a critical error. STOP.

    1. Your tool call FAILED. The task may not be complete.
    2. Run the relevant verification tool (read_file, run_shell, git_status) RIGHT NOW.
    3. Report EXACTLY what the tool shows — success or failure.

    Writing a final answer before reading an actual tool result is FORBIDDEN at this point.
    """

    // MARK: - Decision-logging soft-nudge

    /// True when the conversation has run long enough AND involved
    /// substantial tool use AND no `log_design_decision` has been called
    /// yet.
    public static func shouldNudgeDecisionLogging(iterations: Int,
                                                  messages: [ChatMessage],
                                                  iterationsThreshold: Int = 6,
                                                  toolUseThreshold: Int = 5) -> Bool {
        guard iterations >= iterationsThreshold else { return false }
        var toolCount = 0
        var loggedDecision = false
        let bookkeeping: Set<String> = ["create_plan", "update_todo", "revise_plan", "ask_user"]
        for m in messages where m.role == .assistant {
            for c in m.toolCalls {
                if c.name == "log_design_decision" || c.name == "memory" || c.name == "memory_search" { loggedDecision = true }
                if !bookkeeping.contains(c.name) { toolCount += 1 }
            }
        }
        return !loggedDecision && toolCount >= toolUseThreshold
    }

    /// System-prompt block injected ONCE per turn after the conversation
    /// crosses the heuristic threshold without logging a decision.
    public static let decisionLoggingNudge = """
    # Soft nudge — consider logging a design decision

    You've been working on this task for a while and made meaningful changes. If you made any NON-OBVIOUS architectural or design choice — something a future session couldn't easily re-derive from the code — call `memory` with action `log_decision` (or `remember`) to record it. This keeps DECISIONS.md and the memory index as the project's living memory.

    Skip this if your work was straightforward (no real choice was made). Don't log obvious things like "added a unit test" or "fixed a typo". Quality over quantity.
    """

    // MARK: - Recent decisions extraction

    /// One parsed entry from DECISIONS.md. The full Markdown body is
    /// preserved (including the `## <timestamp>` header) so the caller
    /// can re-emit recent entries verbatim without re-rendering.
    public struct DecisionEntry: Equatable, Sendable {
        public let timestamp: String   // ISO-ish, as written in the file
        public let body: String        // full markdown for the entry, header included
        public init(timestamp: String, body: String) {
            self.timestamp = timestamp
            self.body = body
        }
    }

    /// Parse DECISIONS.md content into entries split on `## <timestamp>`
    /// headers. Returns entries in FILE ORDER (oldest first); callers
    /// typically `.suffix(N)` to get the most recent.
    public static func parseDecisionEntries(_ markdown: String) -> [DecisionEntry] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [DecisionEntry] = []
        var currentHeader: String? = nil
        var currentBody: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let header = currentHeader {
                    let body = ([header] + currentBody).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        let ts = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        entries.append(DecisionEntry(timestamp: ts, body: body))
                    }
                }
                currentHeader = line
                currentBody = []
            } else if currentHeader != nil {
                currentBody.append(line)
            }
        }
        if let header = currentHeader {
            let body = ([header] + currentBody).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let ts = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                entries.append(DecisionEntry(timestamp: ts, body: body))
            }
        }
        return entries
    }

    /// Returns the last `limit` decision entries, formatted as a single
    /// Markdown block ready to inject in the system prompt. Returns
    /// `nil` when there are no entries.
    public static func extractRecentDecisions(from markdown: String, limit: Int = 5) -> String? {
        guard limit > 0 else { return nil }
        let all = parseDecisionEntries(markdown)
        guard !all.isEmpty else { return nil }
        let recent = Array(all.suffix(limit))
        let bodies = recent.map { $0.body }.joined(separator: "\n\n")
        if all.count > recent.count {
            let header = "_Recent decisions (last \(recent.count) of \(all.count) — read DECISIONS.md for the full log)_"
            return header + "\n\n" + bodies
        }
        return bodies
    }

    // MARK: - Tool-call error recovery

    /// True when a tool-call arguments string is present but NOT
    /// parseable as a JSON object — the most common local-model failure
    /// mode (truncated JSON, `key=value` instead of JSON, an array
    /// instead of an object). Empty or `"{}"` is a legitimate
    /// no-argument call, not malformed.
    public static func isMalformedToolArguments(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "{}" else { return false }
        guard let data = t.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return true
        }
        return false
    }

    /// Closest known tool name to `name` by Levenshtein distance, if
    /// within `maxDistance`. Used to suggest a fix when the model calls
    /// a tool that doesn't exist (typo or hallucinated name).
    public static func closestToolName(to name: String, in known: [String], maxDistance: Int = 3) -> String? {
        var best: String? = nil
        var bestDist = maxDistance + 1
        for candidate in known {
            let d = levenshtein(name, candidate)
            if d < bestDist { bestDist = d; best = candidate }
        }
        return bestDist <= maxDistance ? best : nil
    }

    /// Standard Levenshtein edit distance (two-row DP).
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

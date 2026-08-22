//
//  AgentDefinition.swift
//
//  Lightweight, Sendable struct that holds the agent's configuration —
//  backend, model, tools, system prompt, and loop config. Mirrors
//  BuildCode's `Agent` / `AgentBuilder` pattern: you configure the agent
//  once, then create sessions from it.
//
//  This separates "what the agent IS" (definition) from "what it DOES
//  this turn" (session), making the code easier to test and reason about.
//
//  Phase B PB5: `AgentToolAllowlist` resolves custom markdown frontmatter
//  tool lists (tools / allowed-tools) against the known registry set.
//  Profile overrides (`AgentProfileSettings`) come from markdown frontmatter.
//

import Foundation

// MARK: - Custom agent tool allowlist (PB5)

/// Pure helpers for custom agent markdown tool lists + registry scrubbing.
/// Built-in explore/plan/general-purpose presets use `SubagentType.allowedTools`
/// and are unchanged by this type.
public enum AgentToolAllowlist: Sendable {

    /// Always forbidden on subagents (no recursive spawn).
    public static let bannedTools: Set<String> = ["task"]

    /// Result of scrubbing a declared tool list against the live registry.
    /// Used for spawn diagnostics when unknown/banned names are stripped (PC8).
    public struct ScrubReport: Sendable, Equatable {
        public let allowed: Set<String>
        /// Names that were not in `known` (typos / stale frontmatter).
        public let strippedUnknown: [String]
        /// Names removed because they are banned on subagents (e.g. `task`).
        public let strippedBanned: [String]

        public init(allowed: Set<String>, strippedUnknown: [String], strippedBanned: [String]) {
            self.allowed = allowed
            self.strippedUnknown = strippedUnknown
            self.strippedBanned = strippedBanned
        }

        public var stripped: [String] {
            (strippedUnknown + strippedBanned).sorted()
        }

        public var didStrip: Bool { !strippedUnknown.isEmpty || !strippedBanned.isEmpty }

        /// Compact one-line summary for logs / status.
        public var diagnosticMessage: String {
            var parts: [String] = []
            if !strippedUnknown.isEmpty {
                parts.append("unknown: \(strippedUnknown.sorted().joined(separator: ", "))")
            }
            if !strippedBanned.isEmpty {
                parts.append("banned: \(strippedBanned.sorted().joined(separator: ", "))")
            }
            if parts.isEmpty { return "no tools stripped" }
            return "stripped tools (\(parts.joined(separator: "; ")))"
        }

        /// Parent-visible status line (P8). Empty when nothing was stripped.
        public func parentStatusMessage(context: String = "subagent") -> String {
            guard didStrip else { return "" }
            return "Tool strip (\(context)): \(diagnosticMessage)"
        }

        /// Map into a parent-visible AgentEvent (does not end the turn).
        public func agentEvent(context: String = "subagent") -> AgentEvent? {
            guard didStrip else { return nil }
            return .toolAllowlistStripped(
                context: context,
                summary: parentStatusMessage(context: context),
                strippedUnknown: strippedUnknown,
                strippedBanned: strippedBanned
            )
        }
    }

    // MARK: - Parent surface (P8)

    /// Pending strip notices for the parent host (status line / tests).
    /// Thread-safe via actor; drained by ChatViewModel or unit tests.
    public actor StripSurface {
        public static let shared = StripSurface()
        private var pending: [ToolStripNotice] = []
        private static let maxPending = 32

        public func publish(_ notice: ToolStripNotice) {
            pending.append(notice)
            while pending.count > Self.maxPending { pending.removeFirst() }
        }

        public func takePending() -> [ToolStripNotice] {
            let out = pending
            pending.removeAll()
            return out
        }

        public func peekPending() -> [ToolStripNotice] { pending }

        public func clear() { pending.removeAll() }
    }

    /// One parent-visible tool-strip observation.
    public struct ToolStripNotice: Sendable, Equatable {
        public let context: String
        public let report: ScrubReport
        public let agentLabel: String?
        public let timestamp: Date

        public init(context: String, report: ScrubReport, agentLabel: String? = nil,
                    timestamp: Date = Date()) {
            self.context = context
            self.report = report
            self.agentLabel = agentLabel
            self.timestamp = timestamp
        }

        public var statusMessage: String {
            let label = agentLabel.map { " [\($0)]" } ?? ""
            return report.parentStatusMessage(context: context + label)
        }

        public var agentEvent: AgentEvent? {
            report.agentEvent(context: agentLabel.map { "\(context):\($0)" } ?? context)
        }
    }

    /// Strip unknown tool names and banned tools. Order not preserved (Set).
    ///
    /// - Parameters:
    ///   - declared: Names from frontmatter or caller.
    ///   - known: Registered tool names (e.g. `ToolRegistry.registeredNames()`).
    /// - Returns: `declared ∩ known − banned`. May be empty.
    public static func scrub(declared: Set<String>, known: Set<String>) -> Set<String> {
        scrubReport(declared: declared, known: known).allowed
    }

    /// Like `scrub`, but also returns which names were dropped (for diagnostics).
    public static func scrubReport(declared: Set<String>, known: Set<String>) -> ScrubReport {
        let banned = declared.intersection(bannedTools)
        let unknown = declared.subtracting(known).subtracting(bannedTools)
        let allowed = declared.intersection(known).subtracting(bannedTools)
        return ScrubReport(
            allowed: allowed,
            strippedUnknown: unknown.sorted(),
            strippedBanned: banned.sorted()
        )
    }

    /// Resolve a custom agent frontmatter tool list for spawn.
    ///
    /// Rules:
    /// 1. Empty `declaredTools` → fail closed to read-only core ∩ known
    ///    (never inherit general-purpose write/shell).
    /// 2. Non-empty → scrub unknowns against `known`, then optional
    ///    `capability` intersection; if that empties the set, fall back
    ///    to read-only ∩ known.
    /// 3. Never includes `task`.
    public static func resolveCustom(
        declaredTools: [String],
        known: Set<String>,
        capability: SubagentCapabilityMode? = nil
    ) -> Set<String> {
        let declared = Set(
            declaredTools
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let roFallback = scrub(declared: SubagentCatalog.readOnlyTools, known: known)
        let fallback = roFallback.isEmpty ? SubagentCatalog.readOnlyTools.subtracting(bannedTools) : roFallback

        if declared.isEmpty {
            let mode = capability ?? .readOnly
            var allowed = scrub(declared: mode.toolNames.intersection(SubagentCatalog.readOnlyTools), known: known)
            if allowed.isEmpty { allowed = fallback }
            return allowed
        }

        var allowed = scrub(declared: declared, known: known)
        if let mode = capability {
            let narrowed = allowed.intersection(mode.toolNames)
            allowed = narrowed.isEmpty ? fallback : narrowed
        }
        if allowed.isEmpty { allowed = fallback }
        return allowed
    }

    /// Apply registry scrub to a pre-resolved preset/custom allowlist.
    /// Empty after scrub → `fallback` scrubbed (default: read-only core).
    public static func apply(
        requested: Set<String>,
        known: Set<String>,
        fallback: Set<String> = SubagentCatalog.readOnlyTools
    ) -> Set<String> {
        applyReport(requested: requested, known: known, fallback: fallback).allowed
    }

    /// Like `apply`, with a scrub report for the **requested** set (not the
    /// fallback). When request scrub is empty we still fall back, but the
    /// report reflects what was stripped from `requested`.
    public static func applyReport(
        requested: Set<String>,
        known: Set<String>,
        fallback: Set<String> = SubagentCatalog.readOnlyTools
    ) -> ScrubReport {
        let report = scrubReport(declared: requested, known: known)
        var allowed = report.allowed
        if allowed.isEmpty {
            allowed = scrub(declared: fallback, known: known)
        }
        if allowed.isEmpty {
            // Last resort when registry is empty in unit tests before registerBuiltins.
            allowed = fallback.subtracting(bannedTools)
        }
        return ScrubReport(
            allowed: allowed,
            strippedUnknown: report.strippedUnknown,
            strippedBanned: report.strippedBanned
        )
    }

    /// Log a warning when tools were stripped (PC8 diagnostics). No-op when
    /// nothing was stripped. Safe to call from any spawn path.
    public static func logStripDiagnostics(
        _ report: ScrubReport,
        context: String = "agent allowlist"
    ) {
        guard report.didStrip else { return }
        Diagnostics.warn(
            "Tool allowlist scrub (\(context))",
            detail: report.diagnosticMessage
        )
    }

    /// P8: log + queue a parent-visible strip notice (status / AgentEvent).
    /// Call from SubAgentRunner (and any custom-agent spawn path) after scrub.
    public static func surfaceStrip(
        _ report: ScrubReport,
        context: String = "agent allowlist",
        agentLabel: String? = nil
    ) async {
        logStripDiagnostics(report, context: context)
        guard report.didStrip else { return }
        let notice = ToolStripNotice(
            context: context, report: report, agentLabel: agentLabel)
        await StripSurface.shared.publish(notice)
    }
}

/// Configuration for an agent turn — backend, model, tools, and loop
/// parameters. Created once per conversation by `ChatViewModel.send()`
/// then passed to `AgentSession` for execution.
///
/// Mirrors BuildCode's Agent / AgentBuilder pattern: you configure the agent
/// once, then create sessions from it. Separates "what the agent IS"
/// (definition) from "what it DOES this turn" (session).
public struct AgentDefinition: Sendable {

    /// The inference backend to use (llama.cpp, oMLX, Exo, LM Studio, etc.).
    public let backend: InferenceBackend

    /// The model to run (id, name, capabilities).
    public let model: ModelDescriptor

    /// Human-readable display name for this agent configuration.
    public let displayName: String

    /// Loop configuration (max iterations, stall detection, safe mode, etc.).
    public let loopConfig: AgentLoop.Configuration

    /// Sampling parameters for model inference.
    public let sampling: SamplingParams?

    /// Tool names the user disabled in Settings — excluded from schemas AND
    /// rejected at dispatch (defense in depth).
    public var disabledToolNames: Set<String> {
        loopConfig.disabledToolNames
    }

    /// Whether the run is headless (unattended).
    public var headlessMode: Bool {
        loopConfig.headlessMode
    }

    /// Whether chat mode is on (no harness; tools limited to web + read).
    public var rawMode: Bool {
        loopConfig.rawMode
    }

    /// Alias: chat mode = pure conversation (see `rawMode`).
    public var isChatMode: Bool { rawMode }

    /// Optional orchestrator brief injected into the worker's system prompt.
    public var orchestratorBrief: String? {
        loopConfig.orchestratorBrief
    }

    /// Safe mode configuration (path + shell allow-lists).
    public var safeMode: SafeModeConfig? {
        loopConfig.safeMode
    }

    /// Optional patch reviewer for Safe Mode's apply_patch gate.
    public var patchReviewer: PatchReviewer? {
        loopConfig.patchReviewer
    }

    /// Optional user question reviewer for ask_user suspension.
    public var userQuestionReviewer: UserQuestionReviewer? {
        loopConfig.userQuestionReviewer
    }

    /// Optional host gate for `exit_plan_mode`. Reads from loopConfig (same as ask_user).
    public var planApprovalReviewer: PlanApprovalReviewer? { loopConfig.planApprovalReviewer }

    /// Approximate token budget for one request. nil = no compaction.
    public var contextBudgetTokens: Int? {
        loopConfig.contextBudgetTokens
    }

    /// Whether this agent has any tools configured.
    public var hasTools: Bool {
        // Quick check: if disabledToolNames doesn't cover the common tools,
        // the agent still has tool capability. We avoid calling into the
        // actor-isolated ToolRegistry from a synchronous computed property.
        let commonTools: Set<String> = [
            "read_file", "write_file", "edit_file", "run_shell",
            "list_directory", "grep_code", "glob_files", "apply_patch",
        ]
        return !loopConfig.disabledToolNames.isSuperset(of: commonTools)
    }

    /// Whether this agent runs in two-model mode.
    public var isTwoModel: Bool {
        orchestratorBrief != nil
    }

    /// Whether this agent is in chat mode (no harness). Legacy alias.
    public var isRaw: Bool { rawMode }

    /// Whether this agent has safe mode enabled.
    public var isSafe: Bool { safeMode != nil }

    /// Markdown-profile spawn overrides (empty for parent / built-in agents).
    /// Wave-2 `SubAgentRunner` reads these after custom-agent discovery.
    public let profileSettings: AgentProfileSettings

    public init(
        backend: InferenceBackend,
        model: ModelDescriptor,
        loopConfig: AgentLoop.Configuration,
        sampling: SamplingParams? = nil,
        displayName: String? = nil,
        profileSettings: AgentProfileSettings = .empty
    ) {
        self.backend = backend
        self.model = model
        self.loopConfig = loopConfig
        self.sampling = sampling
        self.displayName = displayName ?? model.displayName
        self.profileSettings = profileSettings
    }
}

// MARK: - Markdown agent profile (ZCode frontmatter)

/// Optional per-agent spawn fields from markdown frontmatter.
/// Stored on `DiscoveredAgentDefinition` and `AgentDefinition.profileSettings`
/// so `SubAgentRunner` can apply model / effort / mode / turn-cap / background.
public struct AgentProfileSettings: Sendable, Equatable {
    /// Preferred model id (string; host maps to a `ModelDescriptor` at spawn).
    public var model: String?
    /// Reasoning effort (`thoughtLevel` or `effort` in frontmatter).
    public var thoughtLevel: String?
    /// Mapped permission mode (`acceptEdits` → `.edit`, `bypassPermissions` → `.yolo`).
    public var permissionMode: ExecutionMode?
    /// Child loop iteration cap.
    public var maxTurns: Int?
    /// When true, spawn as a background job by default.
    public var background: Bool?

    public static let empty = AgentProfileSettings()

    public init(
        model: String? = nil,
        thoughtLevel: String? = nil,
        permissionMode: ExecutionMode? = nil,
        maxTurns: Int? = nil,
        background: Bool? = nil
    ) {
        self.model = Self.nonEmpty(model)
        self.thoughtLevel = Self.nonEmpty(thoughtLevel)
        self.permissionMode = permissionMode
        self.maxTurns = maxTurns.flatMap { $0 > 0 ? $0 : nil }
        self.background = background
    }

    public var isEmpty: Bool {
        model == nil && thoughtLevel == nil && permissionMode == nil
            && maxTurns == nil && background == nil
    }

    /// ZCode / Claude `permissionMode` → VibeCoder `ExecutionMode`.
    /// Accepts `plan|build|edit|yolo|acceptEdits|bypassPermissions`
    /// (kebab/snake/camel, case-insensitive).
    public static func parsePermissionMode(_ raw: String?) -> ExecutionMode? {
        guard let token = normalizedToken(raw), !token.isEmpty else { return nil }
        switch token {
        case "plan":
            return .plan
        case "build":
            return .build
        case "edit", "acceptedits":
            return .edit
        case "yolo", "bypasspermissions":
            return .yolo
        default:
            return nil
        }
    }

    /// Prefer `thoughtLevel`, then `effort`. Empty → nil.
    public static func parseThoughtLevel(thoughtLevel: String?, effort: String?) -> String? {
        nonEmpty(thoughtLevel) ?? nonEmpty(effort)
    }

    public static func parseMaxTurns(_ raw: String?) -> Int? {
        guard let text = nonEmpty(raw) else { return nil }
        if let i = Int(text), i > 0 { return i }
        if let d = Double(text), d.isFinite, d == d.rounded(),
           d > 0, d < Double(Int.max) {
            return Int(d)
        }
        return nil
    }

    public static func parseBackground(_ raw: String?) -> Bool? {
        parseBool(raw)
    }

    public static func parseBool(_ raw: String?) -> Bool? {
        guard let token = normalizedToken(raw) else { return nil }
        switch token {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    public static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lowercased alphanumeric-only token so `acceptEdits` / `accept_edits` match.
    static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

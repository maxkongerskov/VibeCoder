//
//  SettingsDiscoverabilityCopy.swift
//  Polish P2 — pure strings for Settings help (defaults stay honest).
//

import Foundation
import Network
import AgentCore

/// View-layer discoverability copy. Does not change persisted defaults.
enum SettingsDiscoverabilityCopy {
    static let localAPIIntro =
        "Loopback-only OpenAI-compatible server for Xcode Intelligence and other clients on this Mac. Default: completions proxy (tools: []). Optional multi-step agent loop is opt-in below — not Cursor-style Xcode agents by default. No auth token; bind is localhost."

    static let agentToolsToggleTitle = "Agent loop on Local API (opt-in)"

    static let agentToolsHelpDefaultOff =
        "Default: Off (recommended for Xcode). When On, chat completions run a bounded multi-step tool loop (model → tools → model) with a hard iteration cap. Leave Off for Xcode Intelligence. Tools use the same permissions as in-app chat (unsandboxed app)."

    static func agentToolsStatus(enabled: Bool) -> String {
        enabled
            ? "Status: agent loop On — tools execute server-side (capped iterations; not unbounded)."
            : "Status: agent loop off (default) — completions proxy only, tools: []."
    }

    static let seatbeltIntro =
        "Optional write fence for run_shell (sandbox-exec). Default is Auto: on only when Permission mode is Auto. This is not macOS App Sandbox — the app entitlements file is empty (full-trust agent)."

    static func seatbeltCurrent(_ pref: ShellSeatbeltPreference) -> String {
        switch pref {
        case .auto: return "Auto (default) — fence when Permission mode is Auto"
        case .always: return "Always on"
        case .never: return "Off"
        }
    }

    static let grantsIntro =
        "Settings → Tools. Durable Always allow / Never allow from shell and path prompts. Not Permission mode, Safe Mode allow-lists, or shell seatbelt."

    static let grantsEmpty =
        "No Always/Never grants yet. When the agent asks for shell or path approval, choose Always or Never to pin a grant here."

    /// Save-panel default. Must not use the old AgentOS product name.
    static let conversationsExportFilename = "\(AppBranding.displayName)-conversations.json"

    /// Keywords beyond tab title/subtitle so Settings search finds Connection panes.
    static func searchKeywords(tabRaw: String) -> [String] {
        switch tabRaw {
        case "connection":
            return [
                "local api", "localapi", "ollama", "lm studio", "lmstudio",
                "omlx", "unsloth", "xcode", "exo", "endpoint", "port",
                "server", "custom",
            ]
        case "mcp":
            return ["oauth", "sse", "stdio"]
        case "model":
            return ["two-model", "orchestrator", "worker", "sampling"]
        case "privacy":
            return ["cloudbot", "cloud bots", "cloud", "screenshot", "computer use", "accessibility", "screen recording"]
        default:
            return []
        }
    }

    static func tabMatchesSearch(
        label: String,
        subtitle: String,
        rawValue: String,
        query: String
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if label.lowercased().contains(q) { return true }
        if subtitle.lowercased().contains(q) { return true }
        if rawValue.lowercased().contains(q) { return true }
        return searchKeywords(tabRaw: rawValue).contains { keyword in
            keyword.contains(q) || q.contains(keyword)
        }
    }
}

/// Empty-chat hero copy. Live HTTP backends only — no llama.cpp / MLX download.
enum EmptyChatCopy {
    static func title(availableModelsEmpty: Bool, hasSelectedModel: Bool) -> String {
        if availableModelsEmpty { return "Connect a model server" }
        if !hasSelectedModel { return "Pick a model to start" }
        return "What are we working on?"
    }

    static func subtitle(availableModelsEmpty: Bool, hasSelectedModel: Bool) -> String {
        if availableModelsEmpty {
            return "Start LM Studio, Ollama, oMLX, Unsloth Studio, or EXO on this Mac, then open Settings → Connection and Test."
        }
        if !hasSelectedModel {
            return "Use the model chip in the composer (bottom-right) to select a tool-capable coding model."
        }
        return "Bind a project folder, describe a task, and the agent will plan, edit, and verify on your machine."
    }

    /// Composer field. VibeCoder wording — never "Ask ZCode".
    static let composerEmpty = "Ask the agent…"
    static let composerFollowUp = "Ask for follow-up changes"
    /// While a turn is live, Send enqueues. Steer on a queued row injects now.
    static let composerQueue = "Keep typing to queue follow-up changes"
    static let sendLabel = "Send"
    static let queueLabel = "Queue message"
    static let sendHelp = "Send message"
    static let queueHelp = "Queue after the current response"
    static let stopLabel = "Stop"
    static let stopHelp = "Stop this response. Queued messages stay."

    static func composerPlaceholder(isEmptyChat: Bool, isRunning: Bool) -> String {
        if isRunning { return composerQueue }
        if isEmptyChat { return composerEmpty }
        return composerFollowUp
    }

    static func sendButtonLabel(isRunning: Bool) -> String {
        isRunning ? queueLabel : sendLabel
    }

    static func sendButtonHelp(isRunning: Bool) -> String {
        isRunning ? queueHelp : sendHelp
    }
}

/// Chat Explore card (ZCode grouping, VibeCoder wording).
enum ExploreCardCopy {
    static let verb = "Explore"

    static func status(counts: ExploreBucketCounts) -> String {
        var parts: [String] = []
        if counts.searches > 0 {
            parts.append("\(counts.searches) search\(counts.searches == 1 ? "" : "es")")
        }
        if counts.lists > 0 {
            parts.append("\(counts.lists) list\(counts.lists == 1 ? "" : "s")")
        }
        if counts.files > 0 {
            parts.append("\(counts.files) file\(counts.files == 1 ? "" : "s")")
        }
        if parts.isEmpty { return "0 files" }
        return parts.joined(separator: ", ")
    }
}

/// Review card unified-diff preview (Atlas `UnifiedDiff.reviewPreview`).
enum ReviewCardCopy {
    static let verb = "Review"
    static let hide = "Hide"
    static let empty = "No diff preview"
    static let language = "diff"

    static func unified(path: String, lines: [CodeDiffLine]) -> String {
        let body = lines.map { "\($0.kindPrefix)\($0.text)" }
        var out = ["--- a/\(path)", "+++ b/\(path)"]
        if !body.isEmpty {
            let oldLen = lines.reduce(0) { n, line in
                switch line {
                case .removed, .context: return n + 1
                case .added: return n
                }
            }
            let newLen = lines.reduce(0) { n, line in
                switch line {
                case .added, .context: return n + 1
                case .removed: return n
                }
            }
            out.append("@@ -1,\(max(oldLen, 0)) +1,\(max(newLen, 0)) @@")
            out.append(contentsOf: body)
        }
        return truncate(out)
    }

    static func truncate(_ lines: [String], maxLines: Int = UnifiedDiff.reviewPreviewMaxLines) -> String {
        if lines.count <= maxLines {
            return lines.joined(separator: "\n")
        }
        let omitted = lines.count - maxLines
        var kept = Array(lines.prefix(maxLines))
        kept.append("Diff preview truncated: \(omitted) lines omitted…")
        return kept.joined(separator: "\n")
    }
}

/// Skill load card. VibeCoder wording (Running skill / Ran skill).
enum SkillCardCopy {
    static func verb(_ card: SkillCard) -> String { card.kindLabel }
    static func status(_ card: SkillCard) -> String {
        let name = card.skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = card.args.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && args.isEmpty { return "Skill" }
        if args.isEmpty { return name }
        if name.isEmpty { return args }
        return "\(name) · \(args)"
    }
}

/// SubAgent / task card. Title is always SubAgent.
enum SubAgentCardCopy {
    static let title = "SubAgent"
    static func verb(_ card: AgentCard) -> String { card.kindLabel }
    static func status(_ card: AgentCard) -> String {
        let prompt = card.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return card.agentType.isEmpty ? card.title : card.agentType }
        return prompt
    }
}

/// Todo write/read card. VibeCoder wording.
enum TodoCardCopy {
    static func verb(_ card: TodoCard) -> String { card.kindLabel }
    static func status(_ card: TodoCard) -> String {
        let s = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Todo" : s
    }
}

/// MCP `server__tool` card.
enum MCPCardCopy {
    static func title(_ card: MCPCard) -> String { card.toolName }
    static var viewCallDetails: String { ToolCallGrouping.mcpViewCallDetailsLabel }
    static var parameters: String { ToolCallGrouping.mcpParametersLabel }
    static var result: String { ToolCallGrouping.mcpResultLabel }
    static var copyResult: String { ToolCallGrouping.mcpCopyResultLabel }
}

/// Enter plan mode. VibeCoder wording.
enum PlanGuidanceCardCopy {
    static func verb(_ card: PlanGuidanceCard) -> String { card.kindLabel }
    static func status(_ card: PlanGuidanceCard) -> String {
        let s = card.planText.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Plan" : s
    }
}

/// Exit plan mode / approval. VibeCoder wording.
/// `approve` is a painted label only on the activity card (not a wired action).
enum SwitchModeCardCopy {
    static func verb(_ card: SwitchModeCard) -> String { card.kindLabel }
    static func status(_ card: SwitchModeCard) -> String {
        let s = card.planText.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? card.placeholderTitle : s
    }
    static var approve: String { ToolCallGrouping.switchModeApproveLabel }
    static var approveDescription: String { ToolCallGrouping.switchModeApproveDescription }
    static var stayInPlan: String { "Stay in Plan" }
}

/// Ask-user question. VibeCoder wording.
/// Continue / Submit are painted labels only on the activity card (not wired).
enum AskUserQuestionCardCopy {
    static func verb(_ card: AskUserQuestionCard) -> String { card.kindLabel }
    static func status(_ card: AskUserQuestionCard) -> String {
        let s = card.question.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Question" : s
    }
    static var continueLabel: String { ToolCallGrouping.askUserContinueLabel }
    static var submit: String { ToolCallGrouping.askUserSubmitLabel }
    static var customAnswer: String { ToolCallGrouping.askUserCustomAnswerLabel }
}

/// Truncated tool args/result notice. VibeCoder wording from Atlas helper.
/// Notice is as-is: "N tool field(s) were truncated. Showing preview X / Y. Load full tool data".
/// `loadFullToolData` on activity expand and MCP cards is a local show-full-preview
/// control that uncaps the in-memory snapshot; not a network fetch.
enum ToolSnapshotCardCopy {
    static func notice(_ snapshot: ToolSnapshotTruncation.Snapshot) -> String? {
        snapshot.notice
    }
    static var loadFullToolData: String { "Load full tool data" }
}

/// Chat shell card (command title + Running/Ran). VibeCoder wording.
enum ShellCardCopy {
    static func title(_ card: ShellCard) -> String {
        let cmd = card.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? "Shell" : cmd
    }

    static func status(_ card: ShellCard, now: Date = Date()) -> String {
        if card.status == .running, let chip = card.longRunningChipLabel(now: now) {
            return chip
        }
        if let overlay = card.statusLabel {
            return "\(card.kindLabel) · \(overlay)"
        }
        return card.kindLabel
    }
}

/// Chat file-change group card (ZCode grouping, VibeCoder wording).
enum FileChangeCardCopy {
    static func verb(events: [ToolCallEvent], memberIndices: [Int]) -> String {
        ToolCallGrouping.fileChangeGroupLabel(events: events, memberIndices: memberIndices)
    }

    static func status(counts: FileChangeGroupCounts) -> String {
        var parts: [String] = []
        if counts.writes > 0 {
            parts.append("\(counts.writes) write\(counts.writes == 1 ? "" : "s")")
        }
        if counts.updates > 0 {
            parts.append("\(counts.updates) update\(counts.updates == 1 ? "" : "s")")
        }
        if counts.deletes > 0 {
            parts.append("\(counts.deletes) delete\(counts.deletes == 1 ? "" : "s")")
        }
        if parts.isEmpty {
            let n = counts.fileCount
            return n == 1 ? "1 file" : "\(n) files"
        }
        return parts.joined(separator: ", ")
    }
}

/// Bind outcomes that need a modest visible reason (not a wizard).
enum WorktreeBindCopy {
    static func notice(for result: WorktreeBindResult) -> String? {
        result.userVisibleReason
    }

    /// Alert chrome: skippedNotGit is informational, merge/discard failures are errors.
    static func alertTitle(forMessage message: String?) -> String {
        let msg = message ?? ""
        if msg.localizedCaseInsensitiveContains("not a git repository") {
            return "Worktree"
        }
        return "Worktree error"
    }
}

/// Composer send affordance: draft required; model required unless a turn is live (queue).
enum ComposerSendGate {
    static func sendEnabled(hasDraft: Bool, hasModel: Bool, isRunning: Bool) -> Bool {
        guard hasDraft else { return false }
        if isRunning { return true }
        return hasModel
    }
}

/// Composer Tab / ⇧Tab. Slash-accept keeps plain Tab; ⇧Tab cycles execution mode.
enum ComposerTabKey {
    enum Action: Equatable {
        case acceptSlash
        case cycleMode
        case ignore
    }

    static func action(shift: Bool, slashMenuVisible: Bool) -> Action {
        if shift { return .cycleMode }
        if slashMenuVisible { return .acceptSlash }
        return .ignore
    }
}

struct LoopbackDetectTarget: Equatable, Identifiable, Sendable {
    var id: BackendIdentifier { backend }
    let backend: BackendIdentifier
    let label: String
    let host: String
    let port: Int

    static let defaults: [LoopbackDetectTarget] = [
        .init(backend: .lmStudio, label: "LM Studio", host: "127.0.0.1", port: 1234),
        .init(backend: .ollama, label: "Ollama", host: "127.0.0.1", port: 11434),
        .init(backend: .omlx, label: "oMLX", host: "127.0.0.1", port: 8080),
        .init(backend: .unslothStudio, label: "Unsloth Studio", host: "127.0.0.1", port: 8888),
        .init(backend: .exo, label: "EXO", host: "127.0.0.1", port: 52415),
    ]

    func resolved(from settings: AppSettings) -> LoopbackDetectTarget {
        let host: String
        let port: Int
        switch backend {
        case .lmStudio: host = settings.lmStudioHost; port = settings.lmStudioPort
        case .ollama: host = settings.ollamaHost; port = settings.ollamaPort
        case .omlx: host = settings.omlxHost; port = settings.omlxPort
        case .unslothStudio: host = settings.unslothHost; port = settings.unslothPort
        case .exo: host = settings.exoHost; port = settings.exoPort
        default: return self
        }
        return LoopbackDetectTarget(
            backend: backend,
            label: label,
            host: host.isEmpty ? self.host : host,
            port: port > 0 ? port : self.port
        )
    }
}

enum LoopbackProbeVerdict: Equatable, Sendable {
    /// GET /v1/models returned 200 + a models list, or 401/403 (compat + auth).
    case modelsReady
    /// Something answered HTTP that is not an OpenAI-compat models list.
    case busyNotCompat
    /// Nothing useful (connection refused / timeout).
    case unreachable
}

struct LoopbackDetectHit: Equatable, Identifiable, Sendable {
    var id: BackendIdentifier { target.backend }
    let target: LoopbackDetectTarget
    let verdict: LoopbackProbeVerdict
}

enum LoopbackServerProbe {
    /// Classify an HTTP /v1/models response. TCP-open is never a verdict.
    static func classify(status: Int, body: Data?) -> LoopbackProbeVerdict {
        if status == 401 || status == 403 { return .modelsReady }
        guard status == 200, let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .busyNotCompat }
        if obj["object"] as? String == "list" { return .modelsReady }
        if obj["data"] is [Any] { return .modelsReady }
        return .busyNotCompat
    }

    static func modelsURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host):\(port)/v1/models")
    }

    static func probe(url: URL, timeout: TimeInterval = 0.8) -> LoopbackProbeVerdict {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let box = VerdictBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if error != nil {
                box.value = .unreachable
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 0 {
                box.value = .unreachable
                return
            }
            box.value = classify(status: code, body: data)
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 0.25) == .timedOut {
            task.cancel()
            return .unreachable
        }
        return box.value
    }

    static func scan(
        targets: [LoopbackDetectTarget] = LoopbackDetectTarget.defaults,
        settings: AppSettings
    ) -> [LoopbackDetectHit] {
        targets.map { raw in
            let t = raw.resolved(from: settings)
            let url = modelsURL(host: t.host, port: t.port)
            let verdict = url.map { probe(url: $0) } ?? .unreachable
            return LoopbackDetectHit(target: t, verdict: verdict)
        }
    }

    private final class VerdictBox: @unchecked Sendable {
        var value: LoopbackProbeVerdict = .unreachable
    }
}

/// Context meter / Settings readout: Unsloth 1M native + 32k loaded is not "32k".
enum ContextWindowHonestyCopy {
    static func label(nativeMax: Int?, loaded: Int?) -> String {
        ModelContextLengthResolver.honestyLabel(nativeMax: nativeMax, loaded: loaded)
    }

    static func meterHelp(nativeMax: Int?, loaded: Int?, used: Int) -> String {
        let windows = label(nativeMax: nativeMax, loaded: loaded)
        return "\(ContextUsageBreakdown.formatTokenCount(used)) used · \(windows)"
    }

    /// Settings auto-cap example is a generic 32k illustration, not Unsloth native.
    static func settingsExampleBudgetLine(percent: Double, maxContextWindowTokens: Int) -> String {
        let pct = min(100, max(10, percent))
        let window = maxContextWindowTokens > 0 ? maxContextWindowTokens : 32_768
        let budget = Int((Double(window) * pct / 100.0).rounded())
        if maxContextWindowTokens == 0 {
            return "Example: at \(Int(pct))% of an example 32.8k cap (not Unsloth native/max), the wire budget is ~\(budget) tokens. Unsloth 1M native + 32k loaded is 32.8k loaded / 1.0M native — not 32k."
        }
        return "Example: at \(Int(pct))% of \(window) tokens, the wire budget is ~\(budget) tokens (FullReplace fires at that budget; elision always applies if still over)."
    }
}

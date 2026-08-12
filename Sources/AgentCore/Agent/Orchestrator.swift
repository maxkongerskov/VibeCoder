//
//  Orchestrator.swift
//
//  Two-model "orchestrator-first" planning pass. A (usually stronger,
//  reasoning-tilted) orchestrator model investigates the task READ-ONLY
//  and produces a short execution plan — a "brief" — that the worker
//  model then executes against with the full mutating tool surface.
//
//  Why a separate planning pass:
//    • A strong model spends its budget on the hard part (deciding WHAT
//      to do) once, up front, instead of re-deriving it every iteration.
//    • The worker can be a fast, cheap coding model: it follows the plan
//      rather than reasoning from scratch, which small local models do
//      poorly.
//
//  Implementation: this is a thin, deterministic wrapper over
//  `SubAgentRunner` — the orchestrator IS a read-only sub-agent whose
//  final answer is the plan. We don't drive a second `AgentLoop`; the
//  worker `AgentLoop` is the only mutating loop in a turn. Keeping the
//  planner read-only is load-bearing: the orchestrator must never edit
//  files (that's the worker's job and would double-apply changes).
//
//  Foundation only, no `@MainActor` — callable from the app layer or the
//  CLI identically.
//

import Foundation

public enum Orchestrator {

    /// Outcome of a planning pass.
    public struct PlanResult: Sendable {
        /// The execution plan to hand the worker. Empty when planning
        /// failed or produced nothing usable — callers should fall back
        /// to a plain single-model run in that case.
        public let brief: String
        /// True when the orchestrator produced a non-empty plan.
        public var succeeded: Bool { !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        /// How many iterations the planner used (diagnostics).
        public let iterations: Int

        public init(brief: String, iterations: Int) {
            self.brief = brief
            self.iterations = iterations
        }

        static let empty = PlanResult(brief: "", iterations: 0)
    }

    /// System prompt for the planning pass. Forces a concise, actionable
    /// plan the worker can execute directly — not prose, not a tutorial.
    static let planningSystemPrompt = """
    You are the ORCHESTRATOR in a two-model coding system. A separate WORKER model will execute your plan with full file-editing and shell tools. You DO NOT write code or edit files — your only job is to investigate the task and produce a tight execution plan the worker follows.

    You have a READ-ONLY tool surface: read files, list directories, grep/glob, git status/diff/log, fetch URLs, search docs. Use them to ground your plan in what the code ACTUALLY looks like — never guess at file names, APIs, or structure you can verify in a few reads.

    Output rules:
    - Produce a NUMBERED, ordered plan of concrete steps. Each step names the specific file(s) and the change to make.
    - Call out the key constraints, gotchas, and existing conventions the worker must respect (verified from the code, with `path:line` references where useful).
    - State how the worker should verify success (which build/test command, what "done" looks like).
    - Be CONCISE: the plan is a single hand-off message, not documentation. No greeting, no sign-off, no restating the task. Aim for under ~400 words.
    - If the task is trivial (a one-line answer or a single obvious edit), say so in one or two steps — do not pad.
    - Do NOT attempt to edit anything. If you find yourself wanting to write a file, that's a step for the plan instead.
    """

    /// Run the orchestrator planning pass.
    ///
    /// - Parameters:
    ///   - task: the user's prompt for this turn.
    ///   - backend: the orchestrator's inference backend.
    ///   - model: the orchestrator's model (resolved on `backend`).
    ///   - registry: tool registry (read-only subset is enforced here).
    ///   - projectRoot / worktreeRoot: forwarded so the planner reads the
    ///     same tree the worker will edit.
    ///   - maxIterations: planning cap. Default 12 — enough reads to
    ///     ground a plan, bounded so a confused planner can't burn the
    ///     whole turn.
    ///   - sampling: defaults to a low-temp reasoning preset.
    ///   - parentConversationID / trace: optional tracing into the parent
    ///     conversation's JSONL (tagged `[subagent]`).
    ///
    /// Never throws — on any failure it returns an empty `PlanResult` so
    /// the caller falls back to a single-model run instead of breaking
    /// the chat.
    public static func plan(
        task: String,
        backend: InferenceBackend,
        model: ModelDescriptor,
        registry: ToolRegistry = .shared,
        projectRoot: URL? = nil,
        worktreeRoot: URL? = nil,
        maxIterations: Int = 12,
        sampling: SamplingParams = SamplingParams(temperature: 0.3,
                                                  topP: 0.95,
                                                  topK: 40,
                                                  repeatPenalty: 1.05,
                                                  maxTokens: 2048),
        parentConversationID: UUID? = nil,
        trace: AgentTraceService? = nil,
        /// Thinking effort for models that support reasoning channels.
        thinking: ThinkingRequestConfig? = nil,
        /// Live stream for chat UI (thinking / answer parity with single-model).
        onStream: (@Sendable (SubAgentRunner.StreamEvent) async -> Void)? = nil
    ) async -> PlanResult {

        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.id.isEmpty else { return .empty }

        let prompt = """
        Produce an execution plan for the WORKER to carry out this task:

        \(trimmed)
        """

        let result = await SubAgentRunner.run(
            prompt: prompt,
            systemPromptOverride: planningSystemPrompt,
            // Read-only planning surface. SubAgentRunner.safeDefault is
            // already read-only; pass nil to use it (and it strips `task`
            // so the planner can't spawn sub-agents).
            allowedTools: Optional<Set<String>>.none,
            backend: backend,
            model: model,
            registry: registry,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            maxIterations: maxIterations,
            sampling: sampling,
            parentConversationID: parentConversationID,
            trace: trace,
            thinking: thinking,
            onStream: onStream
        )

        // A planner that hit its cap without a final answer, or errored,
        // yields a non-actionable string — treat as no plan so the worker
        // runs solo rather than against garbage.
        if result.hitCap || result.iterations == 0 {
            return .empty
        }
        return PlanResult(brief: result.finalText, iterations: result.iterations)
    }
}

//
//  AgentSystemPromptComposer.swift
//
//  Pure system-prompt assembly for AgentLoop — split into raw vs harnessed
//  composers so the loop body doesn't carry two parallel strategies.
//

import Foundation

struct AgentSystemPromptComposer {

    struct Input: Sendable {
        var conversation: Conversation
        var config: AgentLoop.Configuration
        var model: ModelDescriptor
        var nudges: [String]
        var messages: [ChatMessage]
        var cachedInstructions: String?
        var cachedMemory: String?

        /// Hierarchical project rules (AGENTS.md / CLAUDE.md / rules dirs)
        /// preloaded at turn start via `ProjectRules.load`. Injected before
        /// `.agentos/instructions.md`. When nil, composer falls back to a
        /// live `ProjectRules.load` for the conversation root/cwd.
        var cachedAgentsMd: String?
        /// Skills index (name + short description). Full bodies via `load_skill`.
        var cachedSkillsIndex: String?
    }

    static func orchestratorBriefBlock(_ brief: String?) -> String? {
        guard let brief,
              !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return """
        Execution plan (prepared by the orchestrator model — a guide, not a script). Carry it out by ACTUALLY USING YOUR TOOLS to inspect, edit, and run code — never just describe the steps in prose to the user. If the plan conflicts with what you find in the real codebase, trust the codebase.
        \(brief.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    static func compose(_ input: Input) -> (prompt: String, tokens: Int) {
        if input.config.rawMode {
            return composeRaw(input)
        }
        return composeHarnessed(input)
    }

    /// Chat mode: no host instructions, no harness, no project rules, no
    /// orchestrator brief. The model sees only the user/assistant transcript
    /// (plus optional `web_search` tool). An empty prompt is intentional —
    /// callers omit the system wire message when this is blank.
    private static func composeRaw(_ input: Input) -> (prompt: String, tokens: Int) {
        _ = input
        return ("", 0)
    }

    private static func composeHarnessed(_ input: Input) -> (prompt: String, tokens: Int) {
        var parts: [String] = []
        parts.append("""
        You are \(AppBranding.displayName), a local-first coding agent running fully on the user's Mac.
        You drive iterative tool calls to inspect, edit, and verify code in the project.

        Editing rules:
          • Prefer `edit_file` (SEARCH/REPLACE blocks) for changes to existing files. It uses plain text, so code with backslashes, keypaths, or special characters won't break the wire format. All blocks in one call must succeed or nothing is written (strict); set partial_ok=true only if you intentionally want partial apply.
          • Use `apply_patch` for multi-file unified diffs. Plan apply is all-or-nothing; mid-write I/O failures restore already-written files. Call `read_file` on existing targets first.
          • Use `write_file` only for new files or full rewrites (overwrite of existing files also requires a prior `read_file`).
          • After mutating files, BuildGuard may compile the project and inject a system reminder (`BuildGuard: build succeeded` or `build failed`). Fix failures before declaring done. A successful BuildGuard notice is proof the project compiles — do not re-run a full build unless you change code again.

        Greenfield apps (new macOS/iOS app, calculator, utility on Desktop, etc.):
          1. Create a buildable project structure first (Xcode project or Package.swift + sources).
          2. Implement core behavior next — prefer working over perfect.
          3. Get to a green build ASAP. When you see `BuildGuard: build succeeded`, treat compile as done.
          4. Polish UI only after green (colors, spacing, window chrome). Do not spend many turns on design prose before a compiling app exists.
          5. When the app builds and core features work, finish: state the project path and how to Run/open the .app. Avoid open-ended polish loops.

        Efficient tool use:
          • Batch related writes in one turn when you can (multiple tool calls) instead of one file per turn.
          • Read files with `offset` + `limit` when you only need a specific section — avoid reading entire large files.
          • Use `glob_files` or `grep_code` to locate a symbol before reading the file that contains it.
          • Never read the same file twice in one turn unless you just edited it and need to verify.
          • Prefer targeted reads (one function, one struct) over whole-file reads.

        Style (UI-critical — users read this transcript):
          • Do NOT narrate plans ("Let me search…", "I will now…", "Checking…"). Call tools silently.
          • Prefer tool calls over process prose. One short status line is OK; multi-paragraph plans are not.
          • After tools finish, write a structured final answer — not a second copy of your plan.
          • Use markdown with blank lines before lists: ## headings, - bullets, numbered steps.
          • Match the user's language for the whole turn (Danish in → Danish out). Never restate the same answer in two languages.
          • For verification / research tasks end with: short conclusion, checklist (✓/✗), sources.
          • Tool calls > explanation. Concise.
        """)
        parts.append(ChatLoop.currentDateNotice())
        if input.config.headlessMode {
            parts.append(ChatLoop.headlessPrologue)
        }
        if let host = input.config.hostSystemPrompt,
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(host)
        }
        if let briefBlock = orchestratorBriefBlock(input.config.orchestratorBrief) {
            parts.append(briefBlock)
        }
        // Hierarchical project rules (root → cwd). Live path preloads via
        // ProjectRules in AgentLoop; fallback loads here if cache is nil.
        if let agentsMd = input.cachedAgentsMd, !agentsMd.isEmpty {
            parts.append(agentsMd)
        } else if let root = input.conversation.projectRoot {
            let cwd = input.conversation.worktreeRootURL ?? root
            let rules = ProjectRules.load(
                projectRoot: root, cwd: cwd, includeHomeRules: true)
            if !rules.injectedText.isEmpty {
                parts.append(rules.injectedText)
            }
        }
        if let instructions = input.cachedInstructions, !instructions.isEmpty {
            parts.append(instructions)
        }
        // Skip empty override (blank string used to inject a useless block).
        if let override = input.conversation.systemPromptOverride,
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(override)
        }
        if input.config.xcodeMCPEnabled {
            parts.append(XcodeMCPBridge.systemPromptBlock)
        }
        if let root = input.conversation.projectRoot {
            if let worktree = input.conversation.worktreeRootURL {
                parts.append("Working directory: \(worktree.path)\n(Worktree mode: all file mutations land in this isolated git worktree on branch \(input.conversation.worktreeBranch ?? "agentos"), not in \(root.path). The user reviews and merges from the UI.)")
            } else {
                parts.append("Working directory: \(root.path)")
            }
        }
        if let mode = input.config.executionMode {
            parts.append(mode.systemPromptSummary)
        }
        if let safe = input.config.safeMode {
            parts.append(safe.systemPromptSummary())
        }
        if let memory = input.cachedMemory,
           !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(memory)
        }
        // Skills catalog (Wave B S2). Full SKILL.md bodies load on demand.
        if let skills = input.cachedSkillsIndex, !skills.isEmpty {
            parts.append(skills)
        }

        var systemPromptTokens: Int
        if let budget = input.config.contextBudgetTokens,
           let contextLength = input.model.contextLength,
           !input.messages.isEmpty {
            let baseTokens = parts.reduce(0) { $0 + TokenEstimator.estimate($1) }
            let usedTokens = ChatLoop.estimateTotalTokens(
                systemPromptTokens: baseTokens,
                messages: input.messages)
            let pct = min(100, Int(Double(usedTokens) / Double(budget) * 100))
            let notice = """
            Context usage: ~\(usedTokens) / \(contextLength) tokens (~\(pct)% used). \
            Prefer targeted reads (offset/limit) over whole-file reads to conserve context.
            """
            parts.append(notice)
            systemPromptTokens = baseTokens + TokenEstimator.estimate(notice)
        } else {
            systemPromptTokens = parts.reduce(0) { $0 + TokenEstimator.estimate($1) }
        }
        parts.append(contentsOf: input.nudges)
        systemPromptTokens += input.nudges.reduce(0) { $0 + TokenEstimator.estimate($1) }
        let prompt = parts.joined(separator: "\n\n")
        return (prompt, systemPromptTokens)
    }
}
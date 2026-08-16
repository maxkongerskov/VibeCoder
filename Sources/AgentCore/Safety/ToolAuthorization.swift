//
//  ToolAuthorization.swift
//
//  Ordered tool-call authorization pipeline (Grok Build–class):
//    1. PreTool hooks (stub / optional denials)
//    2. Explicit deny rules (incl. project/user PermissionRules files)
//    3. Explicit ask rules
//    3b. Explicit allow rules (command-prefix / host; still plan+confine)
//    4. Remembered grants + file alwaysAllow / alwaysDeny (never for dangerous shell)
//    5. Built-in read-only auto-approve
//    6. Execution-mode policy (Plan / Ask / Auto / Full)
//       — Auto (.edit): file mutates free; shell/executes/MCP require approval
//       — Full (.yolo): mutates + non-dangerous executes auto-allow
//    7. Project/worktree path confinement (always — even when Safe Mode is off)
//    8. Legacy SafeMode path/shell allow-lists (stricter opt-in)
//
//  Full mode does NOT skip deny rules, path confinement, or dangerous-command checks.
//  Rules files: see PermissionRules.swift (.vibecoder/permissions.json).
//

import Foundation

public enum AuthorizationOutcome: Sendable, Equatable {
    case allow
    case deny(String)
    /// Needs interactive approval (patch reviewer / ask). Callers without
    /// a reviewer must treat this as deny.
    case ask(String)
}

public struct AuthorizationRule: Sendable, Equatable {
    public enum Kind: String, Sendable { case deny, ask, allow }
    public let kind: Kind
    public let toolName: String?
    /// Substring match on shell command (case-insensitive) when tool is run_shell.
    public let commandContains: String?
    /// ZCode-style optional subject: command prefix (`git status` / `git status:*`),
    /// host glob (`*.example.com`), or exact subject. On-disk field `ruleContent`
    /// (also accepted as `commandPrefix` / `host` / `domain`).
    public let ruleContent: String?

    public init(
        kind: Kind,
        toolName: String? = nil,
        commandContains: String? = nil,
        ruleContent: String? = nil
    ) {
        self.kind = kind
        self.toolName = toolName
        self.commandContains = commandContains
        self.ruleContent = ruleContent
    }

    public func matches(tool: String, command: String?) -> Bool {
        matches(tool: tool, command: command, url: nil, query: nil)
    }

    public func matches(
        tool: String,
        command: String?,
        url: String?,
        query: String? = nil
    ) -> Bool {
        if let toolName, !PermissionRuleMatch.toolNamesMatch(toolName, tool) {
            return false
        }
        if let content = ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return PermissionRuleMatch.matches(
                tool: tool,
                ruleContent: content,
                command: command,
                url: url,
                query: query
            )
        }
        if let needle = commandContains {
            guard let command else { return false }
            return command.lowercased().contains(needle.lowercased())
        }
        return toolName != nil || commandContains != nil
    }

    public func matches(tool: String, arguments: ToolArguments) -> Bool {
        matches(
            tool: tool,
            command: arguments.stringOptional("command"),
            url: arguments.stringOptional("url"),
            query: arguments.stringOptional("query")
        )
    }
}

/// Wave-2 approval-sheet payload. Persist as an allow/deny/ask
/// `AuthorizationRule` (`toolName` + optional `ruleContent`) — same JSON
/// model as `.vibecoder/permissions.json`. Do not invent a new on-disk format.
public struct SuggestedPermissionUpdate: Sendable, Equatable {
    public var toolName: String
    public var ruleContent: String?
    public var behavior: AuthorizationRule.Kind

    public init(
        toolName: String,
        ruleContent: String? = nil,
        behavior: AuthorizationRule.Kind = .allow
    ) {
        self.toolName = toolName
        self.ruleContent = ruleContent
        self.behavior = behavior
    }

    /// Approval-sheet label. Example: `Always allow git status`.
    public var approvalLabel: String {
        let subject: String
        if let ruleContent, !ruleContent.isEmpty {
            subject = ruleContent
        } else {
            subject = toolName
        }
        switch behavior {
        case .allow: return "Always allow \(subject)"
        case .deny: return "Always deny \(subject)"
        case .ask: return "Always ask for \(subject)"
        }
    }

    public var asRule: AuthorizationRule {
        AuthorizationRule(kind: behavior, toolName: toolName, ruleContent: ruleContent)
    }
}

public struct AuthorizationConfig: Sendable {
    public var rules: [AuthorizationRule]
    public var remembered: [GrantKey: GrantDecision]
    /// When true (tests), skip needing live RememberedGrants actor.
    public var useInlineRememberedOnly: Bool

    public init(rules: [AuthorizationRule] = [],
                remembered: [GrantKey: GrantDecision] = [:],
                useInlineRememberedOnly: Bool = false) {
        self.rules = rules
        self.remembered = remembered
        self.useInlineRememberedOnly = useInlineRememberedOnly
    }

    public static let empty = AuthorizationConfig()
}

public enum ToolAuthorization {

    /// Tools that are always auto-approved when not denied by a rule.
    /// Note: `task` and `kill_task` are intentionally NOT listed — they
    /// carry `.executes` permission and go through mode/deny gates.
    public static let builtInReadOnlyTools: Set<String> = [
        "read_file", "list_directory", "grep_code", "glob_files",
        "web_search", "fetch_url", "fetch_rss", "apple_docs",
        "git_status", "git_diff",
        "create_plan", "update_todo", "revise_plan",
        "ask_user", "tool_search",
        "get_task_output", "wait_tasks",
        "list_background_jobs", "monitor_jobs",
        "memory_search", "memory_get", "find_symbol",
        "load_skill",
        // App-hosted offline PDF tools (registered from App target).
        "extract_pdf_text", "ocr_image",
    ]

    /// Default permission for user-configured MCP tools (`server__tool`).
    /// Conservative: treated like shell execution so Plan mode blocks them
    /// and Ask mode requires approval (deny without a reviewer).
    public static let mcpDefaultPermission: ToolPermission = .executes

    /// True when `name` is a namespaced user-MCP tool (`server__tool`).
    /// Requires a non-empty server prefix and tool suffix around the first
    /// `__` delimiter (avoids matching bare `__` or trailing-only forms).
    public static func isMCPToolName(_ name: String) -> Bool {
        guard let sep = name.range(of: MCPToolNaming.delimiter) else { return false }
        return sep.lowerBound > name.startIndex && sep.upperBound < name.endIndex
    }

    /// Prefix rules the approval sheet can persist (wave-2 UI binds this).
    /// Example: `git status -sb` → Always allow `git status`.
    public static func suggestions(forShellCommand command: String) -> [SuggestedPermissionUpdate] {
        PermissionRules.suggestions(forShellCommand: command)
    }

    /// Authorize an MCP tool call with the same ordered pipeline as
    /// builtins. Call this **before** `MCPServerPool.invokeTool`.
    public static func authorizeMCP(
        toolName: String,
        arguments: ToolArguments,
        context: ToolContext,
        config: AuthorizationConfig? = nil,
        remembered: [GrantKey: GrantDecision] = [:]
    ) -> AuthorizationOutcome {
        evaluate(
            toolName: toolName,
            permission: mcpDefaultPermission,
            arguments: arguments,
            context: context,
            config: config ?? context.authorization,
            remembered: remembered
        )
    }

    /// Canonical session plan path under the working directory.
    public static func sessionPlanURL(workingDirectory: URL, conversationID: UUID) -> URL {
        workingDirectory
            .appendingPathComponent(".agentos", isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("plan.md")
    }

    public static func isSessionPlanPath(_ url: URL, context: ToolContext) -> Bool {
        guard let planURL = context.sessionPlanFileURL else { return false }
        let plan = planURL.resolvingSymlinksInPath().path
        let target = url.resolvingSymlinksInPath().path
        return SafeModeConfig.normalizePath(target) == SafeModeConfig.normalizePath(plan)
    }

    /// Pure evaluation with optional remembered map (tests + actor-fed).
    public static func evaluate(
        toolName: String,
        permission: ToolPermission,
        arguments: ToolArguments,
        context: ToolContext,
        config: AuthorizationConfig = .empty,
        remembered: [GrantKey: GrantDecision] = [:]
    ) -> AuthorizationOutcome {
        let command = arguments.stringOptional("command")
        let url = arguments.stringOptional("url")
        let query = arguments.stringOptional("query")

        // 1. PreTool hooks (stub denials on context)
        if let hookDeny = context.preToolHookDenials?.first(where: {
            $0.toolName == nil || $0.toolName == toolName
        }), hookDeny.kind == .deny {
            return .deny(hookDeny.reason ?? "Denied by PreToolUse hook")
        }

        // 2–3. Explicit rules: deny wins over earlier ask, then ask, then allow.
        // Scan every matching rule so an ask listed first cannot mask alwaysDeny.
        var matchedAsk = false
        var matchedAllow = false
        for rule in config.rules where rule.matches(
            tool: toolName, command: command, url: url, query: query
        ) {
            switch rule.kind {
            case .deny:
                return .deny("Denied by rule for tool '\(toolName)'")
            case .ask:
                matchedAsk = true
            case .allow:
                // still must pass dangerous + plan + safe mode below for safety
                matchedAllow = true
            }
        }
        if matchedAsk {
            return .ask("Approval required by rule for tool '\(toolName)'")
        }

        // Dangerous shell: never remembered; interactive shell approver or deny.
        // Plan always hard-blocks. Full/Auto never silent-auto dangerous.
        let isShellTool = toolName == "run_shell" || toolName == "run_shell_command"
        if isShellTool, let command, SafeBash.isDangerous(command) {
            if context.executionMode == .plan {
                return .deny("Plan mode: dangerous shell commands are blocked.")
            }
            // Prefer interactive shell approver; Ask mode chip still returns
            // `.ask` so tests without a coordinator can assert deny-at-gate.
            if context.shellApprovalCoordinator != nil
                || context.executionMode == .build {
                return .ask("Dangerous shell command requires approval: \(command.prefix(120))")
            }
            return .deny(
                "Dangerous shell command blocked ('\(command.prefix(80))'). "
                + "Dangerous commands never use remembered grants. Rephrase or run manually.")
        }

        // 4. Remembered grants
        let projectKey = RememberedGrants.projectKey(from: context)
        var grantKey = GrantKey(projectKey: projectKey, toolName: toolName)
        if isShellTool, let command {
            grantKey = GrantKey(
                projectKey: projectKey,
                toolName: "run_shell",
                commandFingerprint: RememberedGrants.fingerprint(command: command)
            )
        }
        let rem = remembered[grantKey] ?? config.remembered[grantKey]
        if let rem {
            switch rem {
            case .never:
                return .deny("Previously denied for this project: \(toolName)")
            case .allow:
                if isShellTool, let command, SafeBash.isDangerous(command) {
                    // unreachable if we already returned above, but belt
                    return .deny("Dangerous commands cannot use remembered grants")
                }
                // Remembered allow skips mode ask, still subject to plan + confinement + safe mode.
                return applyPlanAndSafeMode(
                    toolName: toolName, permission: permission,
                    arguments: arguments, context: context, base: .allow,
                    remembered: mergeRemembered(remembered, config.remembered))
            }
        }

        let remMap = mergeRemembered(remembered, config.remembered)

        // 3b. Project/user allow rules (prefix / host). Dangerous already
        // returned above. Plan + confinement still apply.
        if matchedAllow, allowRulesCover(
            toolName: toolName,
            command: command,
            url: url,
            query: query,
            rules: config.rules
        ) {
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        }

        // 5. Built-in read-only auto-approve
        if permission == .readOnly || builtInReadOnlyTools.contains(toolName) {
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        }

        // Safe-bash auto-approve for run_shell
        if isShellTool, let command, SafeBash.isReadOnlyCommand(command) {
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        }

        // task is `.executes` but plan mode may still spawn explore/plan
        // subagents (read-only). Gate general-purpose / write-capable custom
        // agents here before mode switch.
        if toolName == "task", context.executionMode == .plan {
            if let planTaskOutcome = planModeTaskGate(
                arguments: arguments, context: context) {
                switch planTaskOutcome {
                case .allow:
                    return applyPlanAndSafeMode(
                        toolName: toolName, permission: permission,
                        arguments: arguments, context: context, base: .allow,
                        remembered: remMap)
                case .deny(let reason):
                    return .deny(reason)
                case .ask(let reason):
                    return .ask(reason)
                }
            }
        }

        // 6. Execution-mode policy
        switch context.executionMode {
        case .plan:
            return evaluatePlanMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context)
        case .build:
            // Ask before mutations / non-RO shell
            if permission == .mutates || permission == .executes {
                if context.patchReviewer != nil,
                   permission == .mutates,
                   ToolRegistry.mutationReviewAwareTools.contains(toolName) {
                    // Only mutators whose body calls MutationReview may pass
                    // through (write/edit/delete/move/apply_patch). Others
                    // (e.g. create_directory) must still Ask — a reviewer
                    // present is not a silent-allow for every mutate.
                    return applyPlanAndSafeMode(
                        toolName: toolName, permission: permission,
                        arguments: arguments, context: context, base: .allow,
                        remembered: remMap)
                }
                // executes (run_shell, task, kill_task, MCP) and non-review
                // mutators always need an explicit ask when no silent auto
                // path matched.
                return .ask("Ask mode requires approval for '\(toolName)'")
            }
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        case .edit:
            // Auto: edit files freely; shell / executes / MCP need approval
            // (SafeBash RO shell already auto-approved above).
            if permission == .mutates {
                return applyPlanAndSafeMode(
                    toolName: toolName, permission: permission,
                    arguments: arguments, context: context, base: .allow,
                    remembered: remMap)
            }
            if permission == .executes || isMCPToolName(toolName) {
                return .ask(
                    "Auto mode requires approval for '\(toolName)' "
                    + "(switch to Full access to run commands with fewer confirmations)")
            }
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        case .yolo, .none:
            // Full: allow mutates + non-dangerous executes (deny rules / confinement still apply)
            return applyPlanAndSafeMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context, base: .allow,
                remembered: remMap)
        }
    }

    private static func mergeRemembered(
        _ a: [GrantKey: GrantDecision],
        _ b: [GrantKey: GrantDecision]
    ) -> [GrantKey: GrantDecision] {
        var out = b
        for (k, v) in a { out[k] = v }
        return out
    }

    /// Allow rules must cover every shell segment so `git status && rm`
    /// cannot ride a `git status` prefix.
    private static func allowRulesCover(
        toolName: String,
        command: String?,
        url: String?,
        query: String?,
        rules: [AuthorizationRule]
    ) -> Bool {
        let allow = rules.filter { $0.kind == .allow }
        guard !allow.isEmpty else { return false }
        let isShell = toolName == "run_shell" || toolName == "run_shell_command"
        if isShell, let command {
            let segs = SafeBash.segments(of: command)
            let subjects = segs.isEmpty ? [command] : segs
            return subjects.allSatisfy { seg in
                allow.contains {
                    $0.matches(tool: toolName, command: seg, url: nil, query: nil)
                }
            }
        }
        return allow.contains {
            $0.matches(tool: toolName, command: command, url: url, query: query)
        }
    }

    /// Plan-mode gate for `task`: allow explore/plan and read-only custom
    /// agents; deny general-purpose and write/execute custom agents.
    /// Returns nil when the tool is not a plan-mode task decision (unused).
    private static func planModeTaskGate(
        arguments: ToolArguments,
        context: ToolContext
    ) -> AuthorizationOutcome? {
        let typeRaw = arguments.stringOptional("subagent_type")
        // Custom markdown agent: classify by declared tools (empty = RO).
        if let name = typeRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           let custom = AgentDefinitionDiscovery.byName(name, projectRoot: context.projectRoot) {
            let tools: Set<String>
            if custom.tools.isEmpty {
                tools = SubagentCatalog.readOnlyTools
            } else {
                tools = Set(custom.tools)
            }
            let mutating = SubagentCatalog.writeTools.union(SubagentCatalog.executeTools)
            if tools.contains(where: { mutating.contains($0) }) {
                return .deny(
                    "Plan mode: custom agent '\(name)' exposes write/execute tools. "
                    + "Use explore/plan or a read-only custom agent.")
            }
            return .allow
        }

        let t = SubagentType.parse(typeRaw)
        if t == .generalPurpose {
            // Wave C2: omitted/unknown types default to general-purpose — fail closed.
            let raw = typeRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let explicitGP: Set<String> = [
                "general-purpose", "general_purpose", "generalpurpose", "general",
            ]
            if raw.isEmpty {
                return .deny(
                    "Plan mode: task without subagent_type defaults to general-purpose (write-capable) "
                    + "and is blocked. Use explore or plan.")
            }
            if !explicitGP.contains(raw.lowercased()) {
                return .deny(
                    "Plan mode: unknown subagent_type '\(raw)' maps to general-purpose "
                    + "and is blocked. Use explore or plan.")
            }
            return .deny(
                "Plan mode: general-purpose subagents that can write are blocked. Use explore or plan.")
        }
        // explore / plan
        return .allow
    }

    private static func evaluatePlanMode(
        toolName: String,
        permission: ToolPermission,
        arguments: ToolArguments,
        context: ToolContext
    ) -> AuthorizationOutcome {
        // Planning tools + ask_user always OK
        if builtInReadOnlyTools.contains(toolName) || permission == .readOnly {
            return .allow
        }

        // task: reuse the same gate as the early plan-mode branch.
        if toolName == "task" {
            if let outcome = planModeTaskGate(arguments: arguments, context: context) {
                return outcome
            }
            return .deny("Plan mode: only explore/plan or read-only custom subagents are allowed.")
        }

        // Shell: only safe read-only segments
        if toolName == "run_shell" || toolName == "run_shell_command" {
            if let command = arguments.stringOptional("command"),
               SafeBash.isReadOnlyCommand(command) {
                return .allow
            }
            return .deny(
                "Plan mode is read-only for shell. Only inspect commands (ls, cat, git status/diff, rg, …) are allowed. "
                + "Switch to Auto or Full access to run mutating commands.")
        }

        // Mutating tools: only session plan file (write_file/edit path args).
        // apply_patch embeds paths in the patch body — no top-level path arg,
        // so it must not fall through to allow (Wave C fail-closed).
        // move_file: source=plan is not a license to overwrite any destination.
        if permission == .mutates {
            if toolName == "apply_patch" {
                return .deny(
                    "Plan mode: apply_patch is blocked. Only the session plan file may be written. "
                    + "Switch to Auto or Full access after the plan is approved.")
            }
            let pathValues = pathArgumentKeys.compactMap { arguments.stringOptional($0) }
                .filter { !$0.isEmpty }
            if !pathValues.isEmpty {
                let allArePlan = pathValues.allSatisfy { raw in
                    let resolved = resolvePath(raw, base: context.workingDirectory)
                    return isSessionPlanPath(resolved, context: context)
                }
                if allArePlan {
                    return .allow
                }
            }
            // create_plan etc already RO; write_file/edit to plan.md allowed above
            let planHint = context.sessionPlanFileURL?.path
                ?? "bind a project first — no session plan path without a workspace"
            return .deny(
                "Plan mode: mutations are limited to the session plan file "
                + "(\(planHint)). "
                + "Switch to Auto or Full access after the plan is approved.")
        }

        if permission == .executes {
            // MCP tools use .executes — block in plan mode.
            if isMCPToolName(toolName) {
                return .deny(
                    "Plan mode: MCP tools are blocked ('\(toolName)'). "
                    + "Switch to Auto or Full access to use external MCP servers.")
            }
            if toolName == "kill_task" {
                return .deny("Plan mode: kill_task is blocked.")
            }
            return .deny("Plan mode: shell execution beyond read-only inspect is blocked.")
        }

        // Network (and any other non-RO permission) — fail-closed in plan.
        // Tools listed in builtInReadOnlyTools already returned .allow above.
        if permission == .network {
            return .deny(
                "Plan mode: network tools are blocked unless listed as read-only inspect. "
                + "Switch to Auto or Full access for unrestricted network use.")
        }

        return .deny(
            "Plan mode: tool '\(toolName)' is not permitted. "
            + "Switch to Auto or Full access after the plan is approved.")
    }

    private static func applyPlanAndSafeMode(
        toolName: String,
        permission: ToolPermission,
        arguments: ToolArguments,
        context: ToolContext,
        base: AuthorizationOutcome,
        remembered: [GrantKey: GrantDecision] = [:]
    ) -> AuthorizationOutcome {
        if case .deny = base { return base }
        if case .ask = base { return base }

        // Plan mode re-check for mutates that slipped through RO list
        if context.executionMode == .plan {
            let planOutcome = evaluatePlanMode(
                toolName: toolName, permission: permission,
                arguments: arguments, context: context)
            if case .deny = planOutcome { return planOutcome }
        }

        // 7. Project/worktree path confinement — always for mutates, even when
        // safeMode == nil. Blocks absolute/~ paths that resolve outside the
        // open project/worktree (Wave A #5 / W2 C4).
        let isMutatingPathTool = permission == .mutates
            || toolName == "apply_patch"
            || toolName == "edit_file"
            || toolName == "write_file"
            || toolName == "delete_file"
            || toolName == "move_file"
            || toolName == "create_directory"
        if isMutatingPathTool {
            // Session plan writes in plan mode are already allowed above;
            // still confine them to workspace (plan file lives under cwd).
            if let confined = PathConfinement.evaluateMutatingPaths(
                toolName: toolName,
                arguments: arguments,
                context: context,
                remembered: remembered
            ) {
                return confined
            }
        }

        // 8. Safe Mode allow-lists (opt-in, stricter)
        guard let safe = context.safeMode else { return .allow }
        switch permission {
        case .readOnly, .network:
            return .allow
        case .mutates:
            for key in pathArgumentKeys {
                guard let raw = arguments.stringOptional(key) else { continue }
                let resolved = resolvePath(raw, base: context.workingDirectory)
                if !safe.isPathAllowed(resolved) {
                    return .deny(
                        "\(key) '\(raw)' resolves to '\(resolved.path)', which is outside the Safe Mode allow-list")
                }
            }
            // apply_patch paths live in the patch body — PathConfinement already
            // checked them; Safe Mode must too when active.
            if toolName == "apply_patch", let patch = arguments.stringOptional("patch") {
                for filePatch in UnifiedDiff.parse(patch) {
                    let resolved = resolvePath(filePatch.path, base: context.workingDirectory)
                    if !safe.isPathAllowed(resolved) {
                        return .deny(
                            "Patch target '\(filePatch.path)' resolves to '\(resolved.path)', "
                            + "which is outside the Safe Mode allow-list")
                    }
                }
            }
            return .allow
        case .executes:
            // Wave B S10a: SafeBash-recognized read-only inspect commands are
            // already validated as RO (Plan prompt + RO auto-approve). Do not
            // re-filter them against the user's narrow Safe Mode shell *prefix*
            // list (defaults: `swift build`/`git`/`ls`) — that list is for
            // intentional non-RO allow-listing.
            //
            // Do NOT re-run shellMetacharacterDenialReason here: it treats `&&`
            // as forbidden, which false-denies legitimate multi-segment RO
            // chains like `git status && git diff` that SafeBash already
            // validated segment-by-segment (each segment rejects `$()`/`>`).
            if (toolName == "run_shell" || toolName == "run_shell_command"),
               let command = arguments.stringOptional("command"),
               SafeBash.isReadOnlyCommand(command) {
                return .allow
            }
            if let command = arguments.stringOptional("command"),
               let reason = safe.commandDenialReason(command) {
                return .deny("Shell command '\(command.prefix(60))' rejected by Safe Mode: \(reason)")
            }
            return .allow
        }
    }

    public static let pathArgumentKeys = ["path", "source", "destination", "file_path", "project_path"]

    public static func firstPathArgument(_ arguments: ToolArguments) -> String? {
        for key in pathArgumentKeys {
            if let v = arguments.stringOptional(key) { return v }
        }
        return nil
    }
}

/// Optional PreToolUse hook denial (stub surface for hooks later).
public struct PreToolHookDenial: Sendable, Equatable {
    public let toolName: String?
    public let kind: AuthorizationRule.Kind
    public let reason: String?
    public init(toolName: String? = nil, kind: AuthorizationRule.Kind = .deny, reason: String? = nil) {
        self.toolName = toolName
        self.kind = kind
        self.reason = reason
    }
}

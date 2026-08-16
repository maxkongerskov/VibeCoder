//
//  PlanModeTools.swift
//
//  Model-facing plan-mode enter/exit. Mode switches are extras for the
//  loop integrator — these tools do not mutate ExecutionMode themselves.
//
//  Wave-2 ToolRegistry.registerBuiltins() (owned by `registry`):
//    register(EnterPlanModeTool.self)
//    register(ExitPlanModeTool.self)
//

import Foundation

/// Shared extras keys (see `docs/parity-wip/COORDINATION.md`).
enum PlanModeToolExtras {
    static let requestExecutionMode = "request_execution_mode"
    static let planApproved = "plan_approved"
}

public struct EnterPlanModeTool: Tool {
    public static let name = "enter_plan_mode"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Use this tool proactively when you're about to start a non-trivial \
        implementation task. Getting user sign-off on your approach before \
        writing code prevents wasted effort and ensures alignment. This tool \
        transitions you into plan mode where you can explore the codebase and \
        design an implementation approach for user approval.

        Prefer enter_plan_mode for implementation tasks unless they're simple. \
        Use it when any of these apply: new feature work, multiple valid \
        approaches, changes that affect existing behavior, architectural \
        choices, multi-file edits, or unclear requirements. Skip it for \
        single-line fixes, a single function with clear requirements, tasks \
        the user has specified in detail, or pure research.

        In plan mode you thoroughly explore with read_file, glob_files, and \
        grep_code; design an approach; use ask_user only to clarify \
        requirements (not to ask if the plan is ready); then call \
        exit_plan_mode with the complete plan. This tool requires the host \
        to switch into plan mode. If unsure, err on the side of planning.
        """,
        parameters: .init(properties: [:], required: [])
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        _ = arguments
        _ = context
        return ToolResult(
            content: Self.enteredPlanModeContent,
            extras: [PlanModeToolExtras.requestExecutionMode: ExecutionMode.plan.rawValue]
        )
    }

    /// Model-facing text after a successful enter. Mentions the read-only gate.
    static let enteredPlanModeContent = """
        Entered plan mode. You should now focus on exploring the codebase and designing an implementation approach.

        In plan mode, you should:
        1. Thoroughly explore the codebase to understand existing patterns
        2. Identify similar features and architectural approaches
        3. Consider multiple approaches and their trade-offs
        4. Use ask_user if you need to clarify the approach
        5. Design a concrete implementation strategy
        6. When ready, use exit_plan_mode to present your plan for approval

        Remember: DO NOT write or edit any files yet. This is a read-only exploration and planning phase. Do not run mutating shell commands.
        """
}

public struct ExitPlanModeTool: Tool {
    public static let name = "exit_plan_mode"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Use this tool when you are in plan mode and have finished writing \
        your plan and are ready for user approval.

        You should have already explored the codebase and finalized the plan. \
        Pass the complete plan in the required `plan` field; the user will \
        review that content before approving implementation. Do not use \
        ask_user to ask "Is this plan okay?" — this tool is the approval gate.

        Only use this when the task requires planning implementation steps \
        that will write code. For research-only work (searching, reading, \
        understanding the codebase) do not call this tool.
        """,
        parameters: .init(
            properties: [
                "plan": .init(
                    type: "string",
                    description: "The implementation plan to present to the user for approval."
                )
            ],
            required: ["plan"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let plan: String
        do {
            plan = try arguments.string("plan")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ToolResult(
                content: "Error: `plan` is required — pass the complete implementation plan for approval.",
                isError: true
            )
        }
        guard !plan.isEmpty else {
            return ToolResult(
                content: "Error: `plan` is required — pass the complete implementation plan for approval.",
                isError: true
            )
        }

        await persistApprovedPlan(plan, context: context)

        return ToolResult(
            content: "The plan was recorded. Start implementing.\n\n\(plan)",
            extras: [
                PlanModeToolExtras.requestExecutionMode: ExecutionMode.build.rawValue,
                PlanModeToolExtras.planApproved: "true"
            ]
        )
    }

    /// Best-effort persist. Failure must not hide the plan from the model.
    private func persistApprovedPlan(_ text: String, context: ToolContext) async {
        let structured = Plan.make(goal: text, todoTexts: ["Implement approved plan"])
        await PlanStore.shared.setPlan(
            structured,
            for: context.conversationID,
            workingDirectory: context.usableWorkspaceRoot
        )
        guard let url = context.sessionPlanFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Diagnostics.warn(
                "exit_plan_mode persist failed",
                detail: "\(url.path): \(error.localizedDescription)")
        }
    }
}

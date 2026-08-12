//
//  LoadSkillTool.swift
//
//  load_skill — inject a discovered SKILL.md body into the tool result
//  (Grok Build `skill` / Claude Code progressive skill load).
//

import Foundation

public struct LoadSkillTool: Tool {
    public static let name = "load_skill"
    public static let category: ToolCategory = .agent
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Load a reusable skill (SKILL.md) by name into this turn. Skills are listed \
        in the system prompt under "Available skills". Call this when a listed skill \
        matches the user's task to get full step-by-step instructions. Skills marked \
        disable-model-invocation (user/slash-only) are not listed and cannot be loaded \
        with this tool.
        """,
        parameters: .init(
            properties: [
                "skill": .init(
                    type: "string",
                    description: "Skill name (e.g. verify). Must match a discovered skill."
                ),
                "args": .init(
                    type: "string",
                    description: "Optional free-form arguments for the skill (e.g. a path or focus area)."
                ),
            ],
            required: ["skill"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        // Coerce common model mistakes (number / non-string skill name).
        let name: String = {
            if let s = arguments.stringOptional("skill") {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let n = arguments.raw["skill"] as? Int {
                return String(n)
            }
            if let n = arguments.raw["skill"] as? Double {
                return String(Int(n))
            }
            if let s = arguments.raw["skill"] as? NSNumber {
                return s.stringValue
            }
            return ""
        }()
        guard !name.isEmpty else {
            return ToolResult(content: "load_skill: skill name is required.", isError: true)
        }
        let args = arguments.stringOptional("args")

        // Scan worktree + project (same roots as AgentLoop skill index).
        guard let skill = SkillDiscovery.byName(
            name,
            projectRoot: context.projectRoot,
            worktreeRoot: context.worktreeRoot
        ) else {
            // Only advertise model-invocable names so disabled skills stay hidden.
            let available = SkillDiscovery.modelInvocableSkills(
                SkillDiscovery.discover(
                    projectRoot: context.projectRoot,
                    worktreeRoot: context.worktreeRoot
                )
            )
            .map(\.name)
            .sorted()
            let list = available.isEmpty
                ? "(none discovered — add .vibecoder/skills/<name>/SKILL.md)"
                : available.joined(separator: ", ")
            return ToolResult(
                content: "load_skill: unknown skill '\(name)'. Available: \(list)",
                isError: true
            )
        }

        // Control plane: disable-model-invocation skills are user/slash-only.
        // Callers that need the body outside the model tool path should use
        // SkillDiscovery.byName + formatSkillMessage (e.g. future /skill).
        if skill.disableModelInvocation {
            return ToolResult(
                content: "load_skill: skill '\(skill.name)' has disable-model-invocation and is not available to the model. It can only be invoked by the user (e.g. slash /skill when available), not via load_skill.",
                isError: true
            )
        }

        let message = SkillDiscovery.formatSkillMessage(skill, args: args)
        return ToolResult(content: message, isError: false)
    }
}

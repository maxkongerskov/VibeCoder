//
//  ToolClassification.swift
//
//  Registry-derived tool sets — single source of truth for loop dispatch,
//  edit verification, pruning, and stall exemptions.
//

import Foundation

public struct ToolClassification: Sendable {
    public let mutating: Set<String>
    public let readOnly: Set<String>
    public let executes: Set<String>
    /// Tools that count as intentional post-edit verification (re-read,
    /// diff, build) — NOT exploratory reads like list_directory/grep.
    public let verification: Set<String>
    public let alwaysRelevant: Set<String>

    /// Builtin + MCP names that satisfy the edit-verify gate when invoked
    /// after a mutating tool. Intersected with registered tools at load.
    public static let postEditVerificationCore: Set<String> = [
        "read_file", "read_file_range",
        "git_diff",
        "xcode_build", "swift_check",
        "build_swift_package", "build_cargo", "build_npm",
        "build_xcode", "run_xcode_tests", "get_build_log",
        "run_shell",
    ]

    public static func load(
        registry: ToolRegistry,
        xcodeMCPEnabled: Bool
    ) async -> ToolClassification {
        let registered = await registry.registeredNames()
        let mutating = await registry.toolNames(withPermission: .mutates)
        let readOnly = await registry.toolNames(withPermission: .readOnly)
        let executes = await registry.toolNames(withPermission: .executes)
        var verification = postEditVerificationCore.intersection(registered)
        if xcodeMCPEnabled {
            verification.formUnion(
                XcodeMCPBridge.buildVerificationToolNames.intersection(registered))
        }
        let alwaysRelevant = pruningCore(registered: registered, xcodeMCPEnabled: xcodeMCPEnabled)
        return ToolClassification(
            mutating: mutating,
            readOnly: readOnly,
            executes: executes,
            verification: verification,
            alwaysRelevant: alwaysRelevant)
    }

    /// Core tools kept in the dynamic pruning set (iteration 2+).
    private static func pruningCore(
        registered: Set<String>,
        xcodeMCPEnabled: Bool
    ) -> Set<String> {
        var core: Set<String> = [
            "read_file", "write_file", "edit_file", "apply_patch",
            "list_directory", "glob_files", "grep_code",
            "run_shell", "create_directory", "delete_file", "move_file",
            "git_diff", "git_status",
            "xcode_build", "xcode_project_editor",
            "load_skill",
            "list_background_jobs", "monitor_jobs",
            // Keep memory tools available after iter 1 so the model can
            // log decisions / handoff without re-discovering them.
            "memory", "memory_search", "memory_get",
        ]
        core = core.intersection(registered)
        if xcodeMCPEnabled {
            // Keep every registered Xcode MCP tool in the always-relevant set
            // (live tools/list names, not only the static knownToolNames list).
            let mcpish = registered.filter {
                $0.hasPrefix("Xcode")
                    || XcodeMCPBridge.knownToolNames.contains($0)
                    || XcodeMCPBridge.buildVerificationToolNames.contains($0)
            }
            core.formUnion(mcpish)
            core.formUnion(XcodeMCPBridge.knownToolNames.intersection(registered))
            core.subtract(ChatLoop.xcodeMCPSupersededBuiltins)
        }
        return core
    }
}
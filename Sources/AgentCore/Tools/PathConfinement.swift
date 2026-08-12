//
//  PathConfinement.swift
//
//  Default project/worktree path confinement for mutating tools.
//  Even when Safe Mode is off (`safeMode == nil`), absolute and `~`
//  paths that resolve outside the project/worktree roots are denied
//  (or require Ask / remembered grant) so agents cannot write to
//  arbitrary filesystem locations.
//

import Foundation

/// Workspace-rooted path policy shared by ToolAuthorization and mutating builtins.
public enum PathConfinement {

    /// Roots that may receive mutations.
    ///
    /// When a worktree is active, mutations are confined to the **worktree
    /// only** so absolute paths into the main project cannot bypass isolation.
    /// Without a worktree, the project root (or `workingDirectory`) is used.
    public static func workspaceRoots(for context: ToolContext) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL?) {
            guard let url else { return }
            let key = SafeModeConfig.normalizePath(url.path)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            roots.append(url)
        }
        if context.worktreeRoot != nil {
            append(context.worktreeRoot)
        } else {
            append(context.projectRoot)
        }
        if roots.isEmpty {
            append(context.workingDirectory)
        }
        return roots
    }

    /// True when `url` is the workspace root or a descendant (boundary-safe prefix).
    public static func isInsideWorkspace(_ url: URL, context: ToolContext) -> Bool {
        let target = SafeModeConfig.normalizePath(url.path)
        guard !target.isEmpty else { return false }
        for root in workspaceRoots(for: context) {
            let allowed = SafeModeConfig.normalizePath(root.path)
            if allowed.isEmpty { continue }
            if target == allowed { return true }
            if target.hasPrefix(allowed + "/") { return true }
        }
        return false
    }

    /// Human-readable denial for a path that escapes the workspace.
    public static func outsideWorkspaceMessage(
        rawPath: String,
        resolved: URL,
        context: ToolContext
    ) -> String {
        let roots = workspaceRoots(for: context)
            .map { SafeModeConfig.normalizePath($0.path) }
            .joined(separator: ", ")
        return "Path '\(rawPath)' resolves to '\(resolved.path)', which is outside the project/worktree "
            + "root(s) [\(roots)]. Mutations are confined to the open project (and its worktree when active). "
            + "Use a path under the project, or switch to Ask mode and approve a one-off write outside the root."
    }

    /// Evaluate path keys on a mutating tool call.
    /// - Returns `nil` when all present paths are inside the workspace (or no path args).
    /// - Returns `.deny` by default for escapes.
    /// - Returns `.ask` when Ask mode / a patch reviewer is available so the host can approve.
    /// - Honors remembered grants fingerprinted as `path:<normalized>`.
    public static func evaluateMutatingPaths(
        toolName: String,
        arguments: ToolArguments,
        context: ToolContext,
        remembered: [GrantKey: GrantDecision] = [:]
    ) -> AuthorizationOutcome? {
        let pairs = pathArguments(toolName: toolName, arguments: arguments, context: context)
        guard !pairs.isEmpty else { return nil }

        let projectKey = RememberedGrants.projectKey(from: context)
        for (raw, resolved) in pairs {
            if isInsideWorkspace(resolved, context: context) { continue }

            if RememberedGrants.allowsPath(
                resolved,
                toolName: toolName,
                projectKey: projectKey,
                grants: remembered
            ) {
                continue
            }
            // Explicit never for this exact path.
            let pathKey = GrantKey(
                projectKey: projectKey,
                toolName: RememberedGrants.pathGrantToolName,
                commandFingerprint: pathGrantFingerprint(resolved)
            )
            if remembered[pathKey] == .never {
                return .deny("Previously denied outside-project path for \(toolName): \(raw)")
            }

            let msg = outsideWorkspaceMessage(rawPath: raw, resolved: resolved, context: context)
            // Ask mode or a live reviewer can surface approval; otherwise hard deny.
            if context.executionMode == .build || context.patchReviewer != nil {
                return .ask(msg)
            }
            return .deny(msg)
        }
        return nil
    }

    /// Defense-in-depth for tool bodies (especially apply_patch paths not seen by simple arg checks).
    /// Honors durable directory/path grants so "Always allow this folder" is not ignored.
    public static func requireInsideWorkspace(
        path raw: String,
        resolved: URL,
        context: ToolContext
    ) throws {
        if isInsideWorkspace(resolved, context: context) { return }
        let projectKey = RememberedGrants.projectKey(from: context)
        if RememberedGrants.allowsPath(
            resolved,
            toolName: RememberedGrants.pathGrantToolName,
            projectKey: projectKey,
            grants: context.authorization.remembered
        ) {
            return
        }
        throw ToolError.permissionDenied(
            outsideWorkspaceMessage(rawPath: raw, resolved: resolved, context: context)
        )
    }

    /// Async variant that also checks process + durable grant stores.
    public static func requireInsideWorkspaceAsync(
        path raw: String,
        resolved: URL,
        context: ToolContext
    ) async throws {
        if isInsideWorkspace(resolved, context: context) { return }
        let projectKey = RememberedGrants.projectKey(from: context)
        var grants = context.authorization.remembered
        let snap = await RememberedGrants.shared.snapshot(projectKey: projectKey)
        for (k, v) in snap { grants[k] = v }
        let durable = await DurableGrantStore.shared.snapshot(projectKey: projectKey)
        for (k, v) in durable { grants[k] = v }
        if RememberedGrants.allowsPath(
            resolved,
            toolName: RememberedGrants.pathGrantToolName,
            projectKey: projectKey,
            grants: grants
        ) {
            return
        }
        throw ToolError.permissionDenied(
            outsideWorkspaceMessage(rawPath: raw, resolved: resolved, context: context)
        )
    }

    public static func pathGrantFingerprint(_ url: URL) -> String {
        "path:" + SafeModeConfig.normalizePath(url.path)
    }

    /// Directory grant covering `url` and all descendants.
    public static func directoryGrantFingerprint(_ url: URL) -> String {
        var isDir: ObjCBool = false
        let path = url.path
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return "dir:" + SafeModeConfig.normalizePath(path)
        }
        // File path → grant parent directory.
        return "dir:" + SafeModeConfig.normalizePath(url.deletingLastPathComponent().path)
    }

    /// Deepest common ancestor directory for a set of paths (for "Always allow folder").
    public static func commonDirectory(for paths: [URL]) -> URL? {
        let normalized = paths
            .map { SafeModeConfig.normalizePath($0.path) }
            .filter { !$0.isEmpty }
        guard let first = normalized.first else { return nil }
        var components = first.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Prefer directory of first path if it's a file.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: first, isDirectory: &isDir), !isDir.boolValue {
            components = Array(components.dropLast())
        }
        for path in normalized.dropFirst() {
            var other = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                other = Array(other.dropLast())
            }
            var i = 0
            while i < components.count, i < other.count, components[i] == other[i] {
                i += 1
            }
            components = Array(components.prefix(i))
        }
        guard !components.isEmpty else { return nil }
        let joined = components.joined(separator: "/")
        let path = joined.isEmpty ? "/" : (joined.hasPrefix("/") ? joined : "/" + joined)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Collect path args

    private static func pathArguments(
        toolName: String,
        arguments: ToolArguments,
        context: ToolContext
    ) -> [(raw: String, resolved: URL)] {
        var out: [(String, URL)] = []
        let base = context.workingDirectory

        if toolName == "apply_patch", let patch = arguments.stringOptional("patch") {
            for filePatch in UnifiedDiff.parse(patch) {
                let raw = filePatch.path
                out.append((raw, resolvePath(raw, base: base)))
            }
            return out
        }

        for key in ToolAuthorization.pathArgumentKeys {
            guard let raw = arguments.stringOptional(key), !raw.isEmpty else { continue }
            out.append((raw, resolvePath(raw, base: base)))
        }
        return out
    }
}

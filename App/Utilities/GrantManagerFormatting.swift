//
//  GrantManagerFormatting.swift
//
//  Phase C PC1 — pure presentation helpers for durable/session grants.
//  No UI / MainActor; unit-tested from App tests.
//

import Foundation
import AgentCore

/// One row in the grant manager list.
struct GrantListItem: Identifiable, Equatable, Sendable {
    /// Stable id for SwiftUI (encoded project/tool/fingerprint).
    let id: String
    let projectKey: String
    let toolName: String
    let commandFingerprint: String?
    let decision: GrantDecision

    var grantKey: GrantKey {
        GrantKey(
            projectKey: projectKey,
            toolName: toolName,
            commandFingerprint: commandFingerprint
        )
    }

    /// Short label: Always allow / Never allow.
    var decisionLabel: String {
        switch decision {
        case .allow: return "Always allow"
        case .never: return "Never allow"
        }
    }

    /// Primary line for the row.
    var title: String {
        GrantManagerFormatting.displayTool(toolName)
    }

    /// Secondary line: fingerprint + project.
    var subtitle: String {
        GrantManagerFormatting.subtitle(
            fingerprint: commandFingerprint,
            projectKey: projectKey
        )
    }
}

enum GrantManagerFormatting {

    /// Build sorted list rows from a grant map.
    static func items(from entries: [GrantKey: GrantDecision]) -> [GrantListItem] {
        entries.map { key, decision in
            GrantListItem(
                id: DurableGrantStore.encodeKey(key),
                projectKey: key.projectKey,
                toolName: key.toolName,
                commandFingerprint: key.commandFingerprint,
                decision: decision
            )
        }
        .sorted { a, b in
            if a.projectKey != b.projectKey { return a.projectKey < b.projectKey }
            if a.toolName != b.toolName { return a.toolName < b.toolName }
            return (a.commandFingerprint ?? "") < (b.commandFingerprint ?? "")
        }
    }

    static func displayTool(_ toolName: String) -> String {
        if toolName == RememberedGrants.pathGrantToolName {
            return "Path / folder access"
        }
        return toolName
    }

    static func subtitle(fingerprint: String?, projectKey: String) -> String {
        var parts: [String] = []
        if let fp = fingerprint, !fp.isEmpty {
            if fp.hasPrefix("dir:") {
                parts.append("folder: \(String(fp.dropFirst(4)))")
            } else if fp.hasPrefix("path:") {
                parts.append("path: \(String(fp.dropFirst(5)))")
            } else {
                parts.append("cmd: \(fp)")
            }
        } else {
            parts.append("entire tool")
        }
        let project = shortProject(projectKey)
        if !project.isEmpty {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }

    static func shortProject(_ projectKey: String) -> String {
        let p = projectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "" }
        return (p as NSString).lastPathComponent
    }

    /// Human summary of loaded permission rule files.
    static func rulesSummary(snapshot: PermissionRulesSnapshot) -> String {
        if snapshot.sourcePaths.isEmpty && snapshot.isEmpty {
            return "No permission rule files loaded for this project."
        }
        let files = snapshot.sourcePaths.count
        let rules = snapshot.rules.count
        let grants = snapshot.grants.count
        return "\(files) file(s) · \(rules) rule(s) · \(grants) file-seeded grant(s)"
    }

    /// Rebuild map after removing one key (for tests / pure revoke logic).
    static func removing(
        _ key: GrantKey,
        from entries: [GrantKey: GrantDecision]
    ) -> [GrantKey: GrantDecision] {
        var out = entries
        out.removeValue(forKey: key)
        return out
    }
}

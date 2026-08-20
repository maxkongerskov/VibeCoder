//
//  TTYApprovals.swift
//  Ask mode: stdin y / n / always. Empty / n / unknown → deny (fail closed).
//  `always` uses the same grant semantics as in-app Always
//  (`ShellApprovalDecision.always` → RememberedGrants; patch Always →
//  directory grant).
//

import Foundation
import AgentCore

public enum TTYApprovals {

    /// Fail closed. `y`/`yes` → once. `always` → durable Always. Empty/`n`/`no`/unknown → deny.
    public static func parseShellDecision(_ raw: String?) -> ShellApprovalDecision {
        switch normalized(raw) {
        case "y", "yes":
            return .once
        case "always":
            return .always
        default:
            return .deny
        }
    }

    /// Fail closed. `y`/`yes` → accept this batch. `always` → accept + durable folder grant.
    /// Empty/`n`/`no`/unknown → reject all.
    public static func parsePatchChoice(_ raw: String?) -> TTYPatchChoice {
        switch normalized(raw) {
        case "y", "yes":
            return .acceptOnce
        case "always":
            return .always
        default:
            return .reject
        }
    }

    public enum TTYPatchChoice: Sendable, Equatable {
        case acceptOnce
        case always
        case reject
    }

    public static func shellReviewer(
        readLine: @escaping @Sendable () -> String? = { Swift.readLine() }
    ) -> ShellApprovalCoordinator {
        ShellApprovalReviewer { req in
            let detail = req.command ?? req.detail
            fputs("Allow \(req.toolName)? \(detail)\n[y/n/always] ", stderr)
            fflush(stderr)
            return parseShellDecision(readLine())
        }
    }

    public static func patchReviewer(
        projectKey: String? = nil,
        readLine: @escaping @Sendable () -> String? = { Swift.readLine() }
    ) -> PatchReviewer {
        PatchReviewer { previews in
            let paths = previews.map(\.path).joined(separator: ", ")
            fputs("Apply patch to \(paths)?\n[y/n/always] ", stderr)
            fflush(stderr)
            switch parsePatchChoice(readLine()) {
            case .acceptOnce:
                return .acceptAll
            case .always:
                await persistPatchAlways(previews: previews, projectKey: projectKey)
                return .acceptAll
            case .reject:
                return .rejectAll
            }
        }
    }

    public static func questionReviewer(
        readLine: @escaping @Sendable () -> String? = { Swift.readLine() }
    ) -> UserQuestionReviewer {
        UserQuestionReviewer { q in
            fputs("\(q.question)\n", stderr)
            if !q.options.isEmpty {
                for (i, opt) in q.options.enumerated() {
                    fputs("  \(i + 1). \(opt)\n", stderr)
                }
            }
            fputs("> ", stderr)
            fflush(stderr)
            return (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Same durable folder grant as in-app "Always allow this folder".
    public static func persistPatchAlways(
        previews: [PatchPreview],
        projectKey: String?
    ) async {
        guard let projectKey, !projectKey.isEmpty else { return }
        let urls = previews.map { URL(fileURLWithPath: $0.path) }
        guard let dir = PathConfinement.commonDirectory(for: urls) else { return }
        await RememberedGrants.shared.alwaysAllowDirectory(dir, projectKey: projectKey)
    }

    private static func normalized(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

//
//  ExecutionMode.swift
//
//  Mirrors z.code's 4-mode permission system. The host app exposes
//  the selected mode as a chip in the input card; this enum is the
//  shared vocabulary between UI (ExecutionModeChip) and backend
//  (AgentLoop.Configuration / SafeModeConfig mapping).
//
//  z.code's actual mode set (extracted from its app bundle):
//
//    plan   — "Inspect the code and present a plan before editing."
//    build  — "Ask before each file changes."
//    edit   — "Edit selected files or relevant workspace files automatically."
//    yolo   — "Edit and run commands with fewer confirmations."
//
//  VibeCoder's backend today has two levers: `safeModeOn` (enforces
//  path + shell allow-lists) and `patchReviewCoordinator` (surfaces a
//  sheet before each write). The mapping below is the closest faithful
//  projection of z.code's 4 modes onto those levers — it is honest
//  about which modes are fully backed vs. aspirational.
//

import Foundation

/// z.code-style execution / permission mode for the agent loop.
public enum ExecutionMode: String, CaseIterable, Sendable, Identifiable {

    /// Inspect the code and present a plan before editing.
    case plan

    /// Ask before each file changes (patch review sheet surfaces).
    case build

    /// Edit selected files or relevant workspace files automatically.
    case edit

    /// Full access — edit and run commands with fewer confirmations.
    case yolo

    // MARK: - Identifiable

    public var id: String { rawValue }

    // MARK: - Display

    /// Short label shown on the chip (e.g. "Plan", "Full access").
    public var shortLabel: String {
        switch self {
        case .plan:  return "Plan"
        case .build:  return "Ask"
        case .edit:   return "Auto"
        case .yolo:   return "Full"
        }
    }

    /// Full descriptive label for the popup menu rows.
    public var fullLabel: String {
        switch self {
        case .plan:  return "Plan mode"
        case .build:  return "Ask before changes"
        case .edit:   return "Edit automatically"
        case .yolo:   return "Full access"
        }
    }

    /// One-line description matching z.code's wording.
    public var description: String {
        switch self {
        case .plan:  return "Inspect the code and present a plan before editing."
        case .build:  return "Ask before each file changes."
        case .edit:   return "Edit selected files or relevant workspace files automatically."
        case .yolo:   return "Edit and run commands with fewer confirmations."
        }
    }

    /// SF Symbol for this mode. The chip shows the icon + short label;
    /// the popup menu rows show the same icon + full label.
    public var iconName: String {
        switch self {
        case .plan:  return "doc.text.magnifyingglass"
        case .build:  return "shield.lefthalf.filled"
        case .edit:   return "pencil.and.ruler"
        case .yolo:   return "bolt.fill"
        }
    }

    // MARK: - Backend mapping
    //
    // VibeCoder has two backend levers today:
    //   1. safeModeOn       — enforces allow-lists (paths + shell prefixes)
    //   2. patchReview      — surfaces a sheet before each file write
    //
    // We map the 4 z.code modes onto these levers as faithfully as
    // possible. Modes that can't be fully backed yet (plan's read-only
    // behavior) still get a sensible mapping so the chip never lies
    // about what will actually happen.

    /// Whether this mode enables Safe Mode (path + shell allow-lists).
    ///
    /// `build` and `plan` enforce restrictions; `edit` and `yolo`
    /// give the agent free rein over the filesystem.
    ///
    /// When true, the host must install Safe Mode via
    /// `AppSettings.safeModeConfig(projectRoots:)` (or
    /// `SafeModeConfig.reconciledForAutoSafeMode`) so the open project is
    /// on the path list and SafeBash RO inspect shell is not dual-denied
    /// by narrow default prefixes (Wave B S10a).
    public var enablesSafeMode: Bool {
        switch self {
        case .plan, .build:
            return true
        case .edit, .yolo:
            return false
        }
    }

    /// Whether this mode enables the per-file patch review sheet.
    ///
    /// `build` (Ask) asks before each change. Other modes do not interrupt.
    public var enablesPatchReview: Bool {
        switch self {
        case .build:
            return true
        case .plan, .edit, .yolo:
            return false
        }
    }

    /// Plan mode is read-only: mutating + shell tools are denied at the
    /// registry (not just guided by the system prompt).
    public var isReadOnly: Bool {
        switch self {
        case .plan: return true
        case .build, .edit, .yolo: return false
        }
    }

    /// Block text injected into the system prompt so the model plans
    /// within the active mode instead of discovering denials by trial.
    public var systemPromptSummary: String {
        switch self {
        case .plan:
            return """
            # Execution mode: PLAN (hard-gated read-only)
            You may inspect the codebase (read, search, list, git status/diff, safe inspect shell).
            You may update the session plan file only (create_plan / update_todo / revise_plan, \
            or write the canonical plan.md under .agentos/plans/<conversation>/plan.md).
            You MUST NOT edit application source, delete/move project files, or run mutating shell.
            Produce a clear implementation plan; when ready, ask the user to approve and switch \
            to Auto or Full access before making code changes.
            """
        case .build:
            return """
            # Execution mode: ASK before changes
            File mutations require explicit user approval in a review sheet. \
            Prefer small, reviewable edits. Shell commands are allowed but \
            stay within Safe Mode allow-lists when active.
            """
        case .edit:
            return """
            # Execution mode: AUTO edit
            You may edit workspace files without per-change confirmation. \
            Prefer targeted patches. Shell commands, MCP tools, and other \
            executes require user approval (read-only inspect shell is OK). \
            Switch to Full access to run non-dangerous commands with fewer confirmations.
            """
        case .yolo:
            return """
            # Execution mode: FULL access
            You may edit files and run commands with minimal confirmation. \
            Still prefer reversible, well-scoped changes.
            """
        }
    }

    /// Cycle order for ⇧Tab: Plan → Ask → Auto → Full → Plan…
    public func next() -> ExecutionMode {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .yolo }
        return all[(idx + 1) % all.count]
    }

    /// Accent color hint for the chip. Each mode gets a distinct hue
    /// so the user can tell at a glance what permission state is armed.
    /// Returned as an SF Symbol-friendly semantic — the chip maps these
    /// to actual SwiftUI Colors.
    public var accentHint: AccentHint {
        switch self {
        case .plan:  return .blue
        case .build:  return .amber
        case .edit:   return .green
        case .yolo:   return .red
        }
    }

    public enum AccentHint: String, Sendable {
        case blue, amber, green, red
    }
}
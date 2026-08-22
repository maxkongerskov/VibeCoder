// ToolsSettingsView.swift
// AgentOS — Claude Edition
//
// Ported from DEV PLAN ToolsSettingsView (~416 LOC).
//
// 2026-06-09: toggles are REAL now. The list below mirrors
// ToolRegistry.registerBuiltins() exactly (the old mock listed ~16
// tools that don't exist), state persists via AppSettings.toolEnabled,
// and AgentLoop enforces it (schemas filtered + dispatch rejected).
// When a tool is added to registerBuiltins(), add a row here.

import SwiftUI
import AppKit
import AgentCore

// MARK: - Full Disk Access probe
//
// Reliable test: open ~/Library/Application Support/com.apple.TCC/TCC.db
// for reading. The file is SIP-protected and only readable when the
// calling app has Full Disk Access. A failed `Data(contentsOf:)` (any
// throw) means FDA is denied; a successful read means it's granted.
// Falls back to a second known FDA-gated path so a missing TCC.db on
// older systems doesn't produce a false negative.

enum FullDiskAccessStatus {
    case unknown, granted, denied

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .granted: return "Full Disk Access granted"
        case .denied:  return "Full Disk Access not granted"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Theme.Palette.tertiary
        case .granted: return Theme.Palette.success
        case .denied:  return Theme.Palette.error
        }
    }
}

@MainActor
fileprivate func probeFullDiskAccess() -> FullDiskAccessStatus {
    let candidates = [
        ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath,
        ("~/Library/Mail/V10" as NSString).expandingTildeInPath,
    ]
    for path in candidates {
        let url = URL(fileURLWithPath: path)
        if (try? Data(contentsOf: url, options: .mappedIfSafe)) != nil {
            return .granted
        }
        if (try? url.checkResourceIsReachable()) == true {
            // File exists but isn't readable → denied (TCC blocked us).
            return .denied
        }
    }
    return .denied
}

@MainActor
fileprivate func openFullDiskAccessSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    NSWorkspace.shared.open(url)
}

// MARK: - Mock data types

enum ToolsSettingsCategory: String, CaseIterable, Identifiable {
    case filesystem = "Filesystem"
    case search     = "Search"
    case shell      = "Shell"
    case git        = "Git"
    case build      = "Build"
    case web        = "Web"
    case computer   = "Computer"
    case docs       = "Docs"
    case pdf        = "PDF"
    case planning   = "Planning"
    case memory     = "Memory"
    case worktree   = "Worktree"
    case agent      = "Agent"

    var id: String { rawValue }

    /// Category badge color — picked to contrast against NEW DAY's canvas/surface.
    var color: Color {
        switch self {
        case .filesystem: return Color(red: 0.20, green: 0.52, blue: 0.95)   // cobalt (accent)
        case .search:     return Color(red: 0.72, green: 0.51, blue: 0.94)   // violet
        case .shell:      return Color(red: 0.95, green: 0.64, blue: 0.18)   // amber (warning)
        case .git:        return Color(red: 0.91, green: 0.365, blue: 0.235) // orange (sendAccent)
        case .build:      return Color(red: 0.18, green: 0.72, blue: 0.42)   // green (success)
        case .web:        return Color(red: 0.20, green: 0.70, blue: 0.78)   // teal
        case .computer:   return Color(red: 0.35, green: 0.55, blue: 0.72)   // steel
        case .docs:       return Color(red: 0.55, green: 0.40, blue: 0.80)   // muted violet
        case .pdf:        return Color(red: 0.85, green: 0.35, blue: 0.45)   // rose
        case .planning:   return Color(red: 0.30, green: 0.60, blue: 0.40)   // sage
        case .memory:     return Color(red: 0.80, green: 0.45, blue: 0.30)   // terracotta
        case .worktree:   return Color(red: 0.60, green: 0.50, blue: 0.35)   // sand
        case .agent:      return Color(red: 0.90, green: 0.28, blue: 0.28)   // red (error)
        }
    }

    var systemImage: String {
        switch self {
        case .filesystem: return "folder"
        case .search:     return "magnifyingglass"
        case .shell:      return "terminal"
        case .git:        return "arrow.triangle.branch"
        case .build:      return "hammer"
        case .web:        return "globe"
        case .computer:   return "desktopcomputer"
        case .docs:       return "doc.text"
        case .pdf:        return "doc.richtext"
        case .planning:   return "list.bullet.clipboard"
        case .memory:     return "brain"
        case .worktree:   return "square.split.2x1"
        case .agent:      return "cpu"
        }
    }
}

struct BuiltinToolInfo: Identifiable {
    let name: String
    let description: String
    let category: ToolsSettingsCategory
    let defaultEnabled: Bool
    var id: String { name }
}

// MARK: - Built-in tool list
//
// Mirror of ToolRegistry.registerBuiltins() — names must match
// Tool.name exactly or the toggle gates nothing. Keep in sync when adding
// tools; tests assert this catalog covers registered names.

/// Public catalog for settings UI + unit tests (Wave C bug-hunt parity).
enum BuiltinToolCatalog {
    /// Tool names that `ToolRegistry.registerBuiltins()` registers today.
    /// Intentionally excludes unregistered stubs (text_edit, notebook, porting).
    static let registeredBuiltinNames: Set<String> = [
        "read_file", "write_file", "edit_file", "apply_patch",
        "list_directory", "grep_code", "glob_files", "run_shell",
        "git_status", "git_diff", "git_commit", "create_pull_request", "tool_search",
        "web_search", "fetch_url", "apple_docs", "fetch_rss",
        "delete_file", "move_file", "create_directory",
        "xcode_build", "xcode_project_editor",
        "create_plan", "update_todo", "revise_plan", "ask_user",
        "enter_plan_mode", "exit_plan_mode",
        "cron_create", "cron_list", "cron_update", "cron_delete",
        "task", "get_task_output", "wait_tasks", "kill_task",
        "list_background_jobs", "monitor_jobs", "send_message",
        "memory", "memory_search", "memory_get", "read_session_context", "find_symbol",
        "load_skill",
        "restore_checkpoint",
        "screenshot", "click", "type", "scroll",
        "browser_navigate", "browser_snapshot", "browser_click", "browser_type",
    ]

    /// App-hosted tools registered at boot via `PDFToolRegistration` (not in AgentCore builtins).
    static let appHostedToolNames: Set<String> = PDFToolRegistration.toolNames

    /// Builtins + app-hosted names Settings may toggle.
    static var allRegisteredNames: Set<String> {
        registeredBuiltinNames.union(appHostedToolNames)
    }

    static let all: [BuiltinToolInfo] = [
        .init(name: "read_file",        description: "Read contents of a file under the project root",            category: .filesystem, defaultEnabled: true),
        .init(name: "write_file",       description: "Write contents to a file",                                  category: .filesystem, defaultEnabled: true),
        .init(name: "edit_file",        description: "Edit a file with SEARCH/REPLACE blocks (primary edit)",     category: .filesystem, defaultEnabled: true),
        .init(name: "apply_patch",      description: "Apply a unified diff to one or more files",                 category: .filesystem, defaultEnabled: true),
        .init(name: "delete_file",      description: "Delete a file or directory",                                category: .filesystem, defaultEnabled: true),
        .init(name: "move_file",        description: "Move or rename a file or directory",                        category: .filesystem, defaultEnabled: true),
        .init(name: "create_directory", description: "Create a directory (mkdir -p)",                             category: .filesystem, defaultEnabled: true),
        .init(name: "list_directory",   description: "List files in a directory",                                 category: .filesystem, defaultEnabled: true),
        .init(name: "glob_files",       description: "Find files by glob pattern",                                category: .filesystem, defaultEnabled: true),
        .init(name: "grep_code",        description: "Search files for a regex pattern",                          category: .search,     defaultEnabled: true),
        .init(name: "find_symbol",      description: "Find a symbol by name in the project",                      category: .search,     defaultEnabled: true),
        .init(name: "run_shell",        description: "Run a shell command (safe-mode aware)",                     category: .shell,      defaultEnabled: true),
        .init(name: "xcode_build",      description: "Build/test an Xcode project on demand",                     category: .build,      defaultEnabled: true),
        .init(name: "xcode_project_editor", description: "Add a file to a .xcodeproj so it compiles",             category: .build,      defaultEnabled: true),
        .init(name: "git_status",       description: "Show working tree status",                                  category: .git,        defaultEnabled: true),
        .init(name: "git_diff",         description: "Show uncommitted changes",                                  category: .git,        defaultEnabled: true),
        .init(name: "git_commit",       description: "Create a git commit (stages by default, does not push)",    category: .git,        defaultEnabled: true),
        .init(name: "create_pull_request", description: "Open a GitHub pull request via gh",                     category: .git,        defaultEnabled: true),
        .init(name: "web_search",       description: "Search the web (DuckDuckGo)",                               category: .web,        defaultEnabled: true),
        .init(name: "fetch_url",        description: "Fetch a URL's contents",                                    category: .web,        defaultEnabled: true),
        .init(name: "fetch_rss",        description: "Read an RSS feed",                                          category: .web,        defaultEnabled: true),
        .init(name: "browser_navigate", description: "Open a URL in the isolated this-Mac browser",               category: .web,        defaultEnabled: true),
        .init(name: "browser_snapshot", description: "Read visible text in the isolated this-Mac browser",        category: .web,        defaultEnabled: true),
        .init(name: "browser_click",    description: "Click a CSS selector in the isolated this-Mac browser",     category: .web,        defaultEnabled: true),
        .init(name: "browser_type",     description: "Type into a CSS selector in the isolated this-Mac browser", category: .web,        defaultEnabled: true),
        .init(name: "screenshot",       description: "Screenshot this Mac (opt-in computer use, vision image)",   category: .computer,   defaultEnabled: true),
        .init(name: "click",            description: "Click this Mac (opt-in computer use, needs Accessibility)", category: .computer,   defaultEnabled: true),
        .init(name: "type",             description: "Type on this Mac (opt-in computer use, needs Accessibility)", category: .computer, defaultEnabled: true),
        .init(name: "scroll",           description: "Scroll this Mac (opt-in computer use, needs Accessibility)", category: .computer,  defaultEnabled: true),
        .init(name: "apple_docs",       description: "Search developer.apple.com",                                category: .docs,       defaultEnabled: true),
        // Offline PDF (App-hosted PDFKit / Vision / local MD→PDF)
        .init(name: "extract_pdf_text", description: "Extract text from a local PDF (offline)",                   category: .pdf,        defaultEnabled: true),
        .init(name: "ocr_image",        description: "On-device Vision OCR for images / scanned pages",            category: .pdf,        defaultEnabled: true),
        .init(name: "create_pdf",       description: "Create a PDF from markdown offline (local render)",         category: .pdf,        defaultEnabled: true),
        .init(name: "manipulate_pdf",   description: "Merge, split, extract pages, rotate, watermark (deferred)", category: .pdf,        defaultEnabled: true),
        .init(name: "fill_pdf_form",    description: "List or fill AcroForm fields offline (deferred)",           category: .pdf,        defaultEnabled: true),
        .init(name: "sign_pdf",         description: "Stamp a local signature image onto a PDF (deferred)",       category: .pdf,        defaultEnabled: true),
        .init(name: "create_plan",      description: "Create a multi-step plan with todos",                       category: .planning,   defaultEnabled: true),
        .init(name: "update_todo",      description: "Update a plan step status",                                 category: .planning,   defaultEnabled: true),
        .init(name: "revise_plan",      description: "Amend the current plan without resetting done steps",       category: .planning,   defaultEnabled: true),
        .init(name: "enter_plan_mode",  description: "Switch into read-only plan mode before implementation",     category: .planning,   defaultEnabled: true),
        .init(name: "exit_plan_mode",   description: "Present the plan for approval and leave plan mode",         category: .planning,   defaultEnabled: true),
        .init(name: "cron_create",      description: "Create a scheduled automation (runs while the app is open)", category: .planning,  defaultEnabled: true),
        .init(name: "cron_list",        description: "List scheduled automations",                                category: .planning,   defaultEnabled: true),
        .init(name: "cron_update",      description: "Update a scheduled automation",                             category: .planning,   defaultEnabled: true),
        .init(name: "cron_delete",      description: "Delete a scheduled automation",                             category: .planning,   defaultEnabled: true),
        .init(name: "memory",           description: "Remember decisions / handoffs for this project",            category: .memory,     defaultEnabled: true),
        .init(name: "memory_search",    description: "Search project memory",                                     category: .memory,     defaultEnabled: true),
        .init(name: "memory_get",       description: "Get a memory entry by id",                                  category: .memory,     defaultEnabled: true),
        .init(name: "read_session_context", description: "Read context from another persisted conversation",      category: .memory,     defaultEnabled: true),
        .init(name: "task",             description: "Spawn a subagent (explore / plan / general-purpose)",       category: .agent,      defaultEnabled: true),
        .init(name: "get_task_output",  description: "Read output from a background task/subagent",               category: .agent,      defaultEnabled: true),
        .init(name: "wait_tasks",       description: "Wait for background tasks to finish",                       category: .agent,      defaultEnabled: true),
        .init(name: "kill_task",        description: "Cancel a background task or subagent",                      category: .agent,      defaultEnabled: true),
        .init(name: "list_background_jobs", description: "List in-app background shell and subagent jobs",        category: .agent,      defaultEnabled: true),
        .init(name: "monitor_jobs",     description: "Alias of list_background_jobs",                             category: .agent,      defaultEnabled: true),
        .init(name: "send_message",     description: "Send a message to another agent",                           category: .agent,      defaultEnabled: true),
        .init(name: "ask_user",         description: "Ask the user a multiple-choice question",                   category: .agent,      defaultEnabled: true),
        .init(name: "tool_search",      description: "Search for additional tools to unlock",                     category: .agent,      defaultEnabled: true),
        .init(name: "load_skill",       description: "Load a SKILL.md skill into context",                        category: .agent,      defaultEnabled: true),
        .init(name: "restore_checkpoint", description: "Restore files from the last turn filesystem checkpoint",  category: .agent,      defaultEnabled: true),
    ]

    /// Names exposed in Settings toggles.
    static var settingsNames: Set<String> { Set(all.map(\.name)) }
}

private let builtinTools: [BuiltinToolInfo] = BuiltinToolCatalog.all

// MARK: - Root view

struct ToolsSettingsView: View {
    /// Backing store: AppSettings.toolEnabled (missing key = enabled).
    /// AgentLoop reads the inverse via settings.disabledToolNames.
    @Binding var settings: AppSettings
    @EnvironmentObject private var app: AppViewModel

    @State private var searchText: String = ""
    @State private var collapsedCategories: Set<ToolsSettingsCategory> = []
    @State private var newSafePath: String = ""
    @State private var newShellPrefix: String = ""

    // MARK: Derived data

    private func isEnabled(_ tool: BuiltinToolInfo) -> Bool {
        settings.toolEnabled[tool.name] ?? tool.defaultEnabled
    }

    private var filteredTools: [BuiltinToolInfo] {
        guard !searchText.isEmpty else { return builtinTools }
        let q = searchText.lowercased()
        return builtinTools.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var groupedTools: [(category: ToolsSettingsCategory, tools: [BuiltinToolInfo])] {
        let order = ToolsSettingsCategory.allCases
        return order.compactMap { cat in
            let tools = filteredTools.filter { $0.category == cat }
            return tools.isEmpty ? nil : (cat, tools)
        }
    }

    private var enabledCount: Int {
        builtinTools.filter { isEnabled($0) }.count
    }

    private var totalCount: Int { builtinTools.count }

    // Rough token cost heuristic: each enabled tool schema ≈ 150 tokens.
    private var estimatedTokens: Int { enabledCount * 150 }

    // MARK: Body

    @State private var fullDiskAccessStatus: FullDiskAccessStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            agentSessionSection
            // Phase C PC1 — Always/Never grant list + permission rule file paths.
            GrantManagerSettingsView()
            fullDiskAccessSection
            budgetHeader
            searchBar
            toolList
        }
        .onAppear { fullDiskAccessStatus = probeFullDiskAccess() }
    }

    // MARK: Agent session (moved from chat header fingerprint)

    private var agentSessionSection: some View {
        settingsCard {
            HStack(spacing: 6) {
                Image(systemName: "touchid")
                    .foregroundColor(Theme.Palette.accent)
                Text("Agent session")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("Modes for the next agent turn (same as the chat mode chip). Seatbelt and grants below refine shell/path safety — they do not replace Permission mode.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Agent mode (Plan/Ask/Auto/Full) is source of truth — chip in chat
            // and this picker stay aligned. Binary "Safe Mode" alone used to
            // eject Plan → Full (YOLO) when unchecked (Wave C bug-hunt).
            VStack(alignment: .leading, spacing: 6) {
                Text("Permission mode")
                    .font(.system(size: 12, weight: .medium))
                Text("Plan is read-only. Ask reviews edits. Auto edits freely. Full is least restricted. Same control as the chat mode chip.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Permission mode", selection: Binding(
                    get: { app.executionMode },
                    set: { app.executionMode = $0 }
                )) {
                    ForEach(ExecutionMode.allCases) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(isOn: Binding(
                get: { app.safeModeOn },
                set: { app.safeModeOn = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe Mode allow-list")
                        .font(.system(size: 12, weight: .medium))
                    Text(app.executionMode == .plan
                          ? "Always on in Plan mode (cannot disable)."
                          : "Restrict shell/path allow-lists. Turning off while in Ask switches to Auto.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                }
            }
            .toggleStyle(.switch)
            .disabled(app.executionMode == .plan)

            Toggle(isOn: Binding(
                get: { app.headlessModeOn },
                set: { app.headlessModeOn = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headless / unattended")
                        .font(.system(size: 12, weight: .medium))
                    Text("Keep the Mac awake, skip interactive questions, notify when done.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                }
            }
            .toggleStyle(.switch)

            // PC2 / P2: shell seatbelt — discoverable labels; default Auto stays honest.
            VStack(alignment: .leading, spacing: 6) {
                Text("Shell seatbelt")
                    .font(.system(size: 12, weight: .medium))
                Text(SettingsDiscoverabilityCopy.seatbeltIntro)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Current: \(SettingsDiscoverabilityCopy.seatbeltCurrent(settings.shellSeatbeltPreference))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Palette.secondary)
                Picker("Shell seatbelt", selection: Binding(
                    get: { settings.shellSeatbeltPreference },
                    set: { pref in app.updateSettings { $0.shellSeatbeltPreference = pref } }
                )) {
                    Text("Auto (default) — Auto mode only").tag(ShellSeatbeltPreference.auto)
                    Text("Always on — every mode").tag(ShellSeatbeltPreference.always)
                    Text("Off — never fence shell").tag(ShellSeatbeltPreference.never)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text(settings.shellSeatbeltPreference.detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // S5: auto-verify after file mutations (BuildGuard).
            Toggle(isOn: Binding(
                get: { settings.verifyEdits },
                set: { on in app.updateSettings { $0.verifyEdits = on } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-verify after edits")
                        .font(.system(size: 12, weight: .medium))
                    Text("After the agent changes files, run BuildGuard (swift build, xcodebuild, cargo check, or tsc). Failures are injected for the agent and shown in the transcript. On by default; turn off for docs-only or slow projects.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(settings.rawMode)

            Toggle(isOn: Binding(
                get: { settings.rawMode },
                set: { on in app.updateSettings { $0.rawMode = on } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat mode")
                        .font(.system(size: 12, weight: .medium))
                    Text("Talk to the model without the agent harness. No system prompt, project rules, or BuildGuard. Tools limited to web search and reading files. Leave off for full Agent mode (coding tools + harness).")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if app.safeModeOn {
                Divider().opacity(0.4)
                Text("Allowed path prefixes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.secondary)
                ForEach(app.safeModeAllowedPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            app.safeModeAllowedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.Palette.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("~/code/", text: $newSafePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Add") {
                        let p = newSafePath.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty, !app.safeModeAllowedPaths.contains(p) else { return }
                        app.safeModeAllowedPaths.append(p)
                        newSafePath = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Allowed shell prefixes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Palette.secondary)
                    .padding(.top, 4)
                ForEach(app.safeModeAllowedShellPrefixes, id: \.self) { prefix in
                    HStack {
                        Text(prefix)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            app.safeModeAllowedShellPrefixes.removeAll { $0 == prefix }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.Palette.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("git", text: $newShellPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Add") {
                        let p = newShellPrefix.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty, !app.safeModeAllowedShellPrefixes.contains(p) else { return }
                        app.safeModeAllowedShellPrefixes.append(p)
                        newShellPrefix = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Full Disk Access section

    private var fullDiskAccessSection: some View {
        settingsCard {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundColor(Theme.Palette.accent)
                Text("Full Disk Access")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("\(AppBranding.displayName) runs without the macOS sandbox, but macOS still blocks protected folders (Desktop, Documents, Downloads, iCloud Drive, external drives, other apps' data) until Full Disk Access is granted.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.s) {
                HStack(spacing: 5) {
                    Image(systemName: fullDiskAccessStatus == .granted
                          ? "checkmark.shield.fill"
                          : (fullDiskAccessStatus == .denied ? "xmark.shield.fill" : "shield.lefthalf.filled"))
                        .font(.system(size: 11))
                    Text(fullDiskAccessStatus.label)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(fullDiskAccessStatus.color)

                Spacer()

                Button {
                    fullDiskAccessStatus = probeFullDiskAccess()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(action: openFullDiskAccessSettings) {
                HStack(spacing: 8) {
                    Image(systemName: fullDiskAccessStatus == .granted
                          ? "checkmark.shield.fill"
                          : "arrow.up.right.square.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(fullDiskAccessStatus == .granted
                         ? "Full Disk Access is ON — Open System Settings to verify"
                         : "Grant Full Disk Access in System Settings →")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(fullDiskAccessStatus == .granted ? Theme.Palette.success : Theme.Palette.accent)

            if fullDiskAccessStatus == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How to enable:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)
                    Text("1. Click the button above — System Settings opens to the right pane.\n2. Find \(AppBranding.displayName) in the list (or drag the app in if it isn't listed).\n3. Toggle it ON.\n4. Relaunch \(AppBranding.displayName), then click \"Check Again\".")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.error.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.Palette.error.opacity(0.15), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: Budget header

    private var budgetHeader: some View {
        settingsCard {
            HStack(spacing: Theme.Spacing.m) {
                // Enabled pill
                HStack(spacing: Theme.Spacing.xs) {
                    Circle()
                        .fill(Theme.Palette.success)
                        .frame(width: 7, height: 7)
                    Text("\(enabledCount) of \(totalCount) tools enabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.primary)
                }

                Text("·")
                    .foregroundColor(Theme.Palette.tertiary)

                // Token estimate
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "bolt")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Palette.warning)
                    Text("≈ \(estimatedTokens) tokens / turn")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.secondary)
                }

                Spacer()

                // Reset button
                Button("Reset to defaults") { resetToDefaults() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.accent)
            }
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.tertiary)
            TextField("Filter tools…", text: $searchText)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
    }

    // MARK: Tool list

    private var toolList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if groupedTools.isEmpty {
                noResultsView
            } else {
                ForEach(groupedTools, id: \.category) { group in
                    categorySection(group.category, tools: group.tools)
                }
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(Theme.Palette.tertiary)
            Text("No tools match \"\(searchText)\"")
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
    }

    // MARK: Category section

    private func categorySection(_ category: ToolsSettingsCategory, tools: [BuiltinToolInfo]) -> some View {
        let isCollapsed = collapsedCategories.contains(category)
        let enabledInCategory = tools.filter { isEnabled($0) }.count

        return settingsCard {
            // Section header
            Button {
                withAnimation(Theme.Motion.quick) {
                    if isCollapsed {
                        collapsedCategories.remove(category)
                    } else {
                        collapsedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(category.color)
                        .frame(width: 16)

                    Text(category.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.primary)

                    // Enabled count chip
                    Text("\(enabledInCategory)/\(tools.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(category.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(category.color.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.Palette.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, isCollapsed ? 0 : Theme.Spacing.s)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools) { tool in
                        ToolToggleRowV2(
                            tool: tool,
                            isOn: Binding(
                                get: { settings.toolEnabled[tool.name] ?? tool.defaultEnabled },
                                // Write whole dictionary so `@Binding var settings`
                                // persists via AppSettings.didSet (subscript-only
                                // mutation can fail to write-back structs).
                                set: { newVal in
                                    var map = settings.toolEnabled
                                    map[tool.name] = newVal
                                    settings.toolEnabled = map
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func resetToDefaults() {
        withAnimation(Theme.Motion.standard) {
            settings.toolEnabled = [:]   // missing key = default (enabled)
        }
    }
}

// MARK: - Tool toggle row

private struct ToolToggleRowV2: View {
    let tool: BuiltinToolInfo
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(tool.name)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(Theme.Palette.primary)

                        CategoryBadge(category: tool.category)
                    }

                    Text(tool.description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(tool.category.color)
            }
            .padding(.vertical, Theme.Spacing.s)

            Divider()
                .opacity(0.5)
        }
    }
}

// MARK: - Category badge chip

private struct CategoryBadge: View {
    let category: ToolsSettingsCategory

    var body: some View {
        Text(category.rawValue.lowercased())
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(category.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(category.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#if DEBUG
struct ToolsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            ToolsSettingsView(settings: .constant(.default))
                .environmentObject(AppViewModel())
                .padding(Theme.Spacing.ml)
        }
        .frame(width: 560, height: 760)
        .background(Theme.Palette.canvas)
        .previewDisplayName("Tools Settings — Dark")
        .preferredColorScheme(.dark)

        ScrollView {
            ToolsSettingsView(settings: .constant(.default))
                .environmentObject(AppViewModel())
                .padding(Theme.Spacing.ml)
        }
        .frame(width: 560, height: 760)
        .background(Theme.Palette.canvas)
        .previewDisplayName("Tools Settings — Light")
        .preferredColorScheme(.light)
    }
}
#endif

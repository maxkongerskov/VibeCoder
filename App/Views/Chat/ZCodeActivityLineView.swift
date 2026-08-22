//
//  ZCodeActivityLineView.swift
//
//  BuildCode / ZCode-style tool activity rows for the transcript column.
//  Subagents (task tool) match Z Code: inline in chat —
//    [box] SubAgent  general-purpose  ·  list downloads folder content
//  with the type name in blue. Other tools keep Verb · Status rows.
//

import SwiftUI
import AgentCore

/// One tool call rendered as a ZCode activity line.
struct ZCodeActivityLineView: View {
    let state: ToolCallUIState
    /// Kill a running subagent/background job when the row can resolve an id.
    var onKillJob: ((UUID) -> Void)? = nil
    var runningJobID: UUID? = nil
    /// Inspector / nested child thread: verb row only, no full directory table.
    var compact: Bool = false

    @State private var expanded = false
    /// When true, detail blocks show full I/O (no 600/800 char hard cut).
    @State private var showFullDetail = false
    @State private var childThread: [SubagentThreadItem] = []

    private var isTask: Bool { state.toolName == "task" }

    private var taskArgs: (type: String, description: String) {
        guard let data = state.input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("general-purpose", "")
        }
        let type = (obj["subagent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (obj["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            (type?.isEmpty == false) ? type! : "general-purpose",
            desc ?? ""
        )
    }

    private var line: ActivityLine {
        let verb = ActivityLine.verb(forToolName: state.toolName)
        let status: String
        switch state.status {
        case .pending:
            status = "Queued…"
        case .running:
            if isTask {
                let d = taskArgs.description
                status = d.isEmpty ? "Running…" : d
            } else {
                status = ArtifactLabel.activityLabel(toolName: state.toolName, argsJSON: state.input)
            }
        case .success:
            status = successSummary
        case .failure:
            status = "Failed"
        }
        return ActivityLine(verb: verb, status: status)
    }

    private var successSummary: String {
        switch state.toolName {
        case "list_directory":
            if let listing = DirectoryListing.parse(state.output) {
                let dirs = listing.directories.count
                let files = listing.files.count
                if dirs > 0, files == 0 { return "\(dirs) folders" }
                if files > 0, dirs == 0 { return "\(files) files" }
                if dirs + files > 0 { return "\(dirs + files) entries" }
            }
            let label = ArtifactLabel.activityLabel(toolName: state.toolName, argsJSON: state.input)
            return label.isEmpty ? "1 list" : label
        case "read_file", "read_file_range": return "1 file"
        case "run_shell", "run_shell_command": return "1 command"
        case "write_file": return "1 write"
        case "edit_file", "apply_patch", "search_replace": return "1 edit"
        case "grep_code", "glob_files", "code_search": return "search done"
        case "task":
            let desc = taskArgs.description
            return desc.isEmpty ? "done" : desc
        default:
            let label = ArtifactLabel.activityLabel(toolName: state.toolName, argsJSON: state.input)
            return label.isEmpty ? "Done" : label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isTask {
                subagentRow
            } else {
                genericRow
            }

            if expanded, hasExpandableDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if isTask, !childThread.isEmpty {
                        ForEach(childThread) { item in
                            childThreadRow(item)
                        }
                    } else {
                        if !state.input.isEmpty {
                            detailBlock(
                                label: "Input",
                                text: previewText(state.input, limit: showFullDetail ? nil : 600)
                            )
                        }
                        if !compact, isListDirectory, let listing = DirectoryListing.parse(state.output) {
                            DirectoryListingTableView(listing: listing)
                        } else if !state.output.isEmpty {
                            detailBlock(
                                label: "Output",
                                text: previewText(state.output, limit: showFullDetail ? nil : 800)
                            )
                        }
                        if !showFullDetail, detailIsTruncated {
                            Button("Show full I/O") {
                                withAnimation(.easeOut(duration: 0.12)) { showFullDetail = true }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task(id: "\(runningJobID?.uuidString ?? state.id)-\(expanded)") {
            guard expanded else { return }
            while !Task.isCancelled {
                await refreshChildThread()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onChange(of: expanded) { _, open in
            if !open { showFullDetail = false }
        }
    }

    @ViewBuilder
    private func childThreadRow(_ item: SubagentThreadItem) -> some View {
        switch item.kind {
        case .thought:
            Text("Thought · \(previewText(item.text, limit: 160))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.tertiary)
        case .assistant:
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.secondary)
                .textSelection(.enabled)
        case .tool:
            ZCodeActivityLineView(
                state: ToolCallUIState(
                    id: item.id,
                    toolName: item.toolName ?? "tool",
                    status: {
                        switch item.status {
                        case .pending: return .pending
                        case .running: return .running
                        case .success: return .success
                        case .failure: return .failure
                        }
                    }(),
                    input: item.arguments,
                    output: item.output
                ),
                compact: true
            )
        }
    }

    private func refreshChildThread() async {
        guard isTask else {
            childThread = []
            return
        }
        let jobID = runningJobID
            ?? InspectorSubagentDirectory.parseResult(state.output).taskUUID
        guard let jobID else {
            childThread = []
            return
        }
        let items = await SubagentThreadStore.shared.items(for: jobID)
        childThread = items
    }

    private var detailIsTruncated: Bool {
        (!state.input.isEmpty && state.input.count > 600)
            || (!state.output.isEmpty && state.output.count > 800
                && !isListDirectory)
    }

    // MARK: - Z Code subagent row
    //
    //   [box] SubAgent  general-purpose  ·  list downloads folder content
    //         gray      blue               description

    private var subagentRow: some View {
        // Not one outer Button — nested Open/Kill would not receive clicks.
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(width: 16)

                    Text("SubAgent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)

                    Text(taskArgs.type)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.subagentType)

                    Text("·")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.activityDivider)

                    Text(subagentStatusText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if state.status == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 2)
                    }

                    Spacer(minLength: 4)

                    if hasExpandableDetail {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                openInSidePane()
            } label: {
                Text("Open in side pane")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Open in side pane")

            if state.status == .running, let jobID = runningJobID, let onKillJob {
                Button {
                    onKillJob(jobID)
                } label: {
                    Text("Kill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.error)
                }
                .buttonStyle(.plain)
                .help("Stop this subagent")
            }
        }
    }

    private var subagentStatusText: String {
        switch state.status {
        case .pending: return "Queued…"
        case .running:
            let d = taskArgs.description
            return d.isEmpty ? "Running…" : d
        case .success:
            let d = taskArgs.description
            return d.isEmpty ? "done" : d
        case .failure: return "Failed"
        }
    }

    private func openInSidePane() {
        let args = taskArgs
        let meta = InspectorSubagentDirectory.parseResult(state.output)
        let request = InspectorSubagentOpenRequest(
            taskId: runningJobID?.uuidString ?? meta.taskId,
            toolCallId: state.id,
            type: args.type,
            description: args.description.isEmpty ? nil : args.description
        )
        NotificationCenter.default.post(
            name: .openSubagentInInspector,
            object: nil,
            userInfo: request.userInfo()
        )
        NotificationCenter.default.post(
            name: .setInspectorVisible,
            object: nil,
            userInfo: ["visible": true]
        )
    }

    // MARK: - Generic tool row

    private var genericRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: line.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.activityVerb)
                    .frame(width: 16)

                Text(line.verb)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.activityVerb)

                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.activityDivider)

                Text(line.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.activityStatus)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.middle)

                if state.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                }

                Spacer(minLength: 0)

                if hasExpandableDetail {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isListDirectory: Bool {
        state.toolName == "list_directory" || state.toolName == "XcodeLS"
    }

    private var hasExpandableDetail: Bool {
        if compact {
            if isListDirectory { return false }
            if state.output.hasPrefix("VC_LIST") || state.output.hasPrefix("BC_LIST") {
                return false
            }
            return false
        }
        return !state.input.isEmpty || !state.output.isEmpty
    }

    @ViewBuilder
    private func detailBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.Palette.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func previewText(_ raw: String, limit: Int?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// Stack of non-edit tool activity for a turn.
///
/// **Default: collapsed** under a single "Tools" subheader with a chevron
/// pointing right — except while tools are running (live turn), when the
/// stack auto-expands so the user sees which tool is active. User toggle
/// always wins. File edits stay outside this stack (`InlineEditCardView`).
struct ZCodeActivityStack: View {
    let states: [ToolCallUIState]
    var isStreaming: Bool = false
    var onKillJob: ((UUID) -> Void)? = nil
    /// Running background jobs — used to attach Kill to subagent rows.
    var backgroundJobs: [BackgroundJobSnapshot] = []

    /// User has explicitly expanded/collapsed — auto policy stops.
    @State private var userToggled = false
    @State private var isExpanded = false

    private var failureCount: Int { states.filter { $0.status == .failure }.count }
    private var runningCount: Int { states.filter { $0.status == .running || $0.status == .pending }.count }
    private var successCount: Int { states.filter { $0.status == .success }.count }

    /// Auto-open while live tools run or `isStreaming` with activity present.
    private var shouldAutoExpand: Bool {
        (isStreaming || runningCount > 0) && !states.isEmpty
    }

    private var showRows: Bool {
        if userToggled { return isExpanded }
        return shouldAutoExpand || isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Subheader under the work hairline: Tools ▸ N steps
            toolsHeader

            if showRows {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groupedItems) { item in
                        switch item {
                        case .explore(_, let counts, let running):
                            exploreRow(counts: counts, running: running)
                        case .fileChange(_, let counts, let events, let indices, let running):
                            fileChangeRow(
                                counts: counts,
                                events: events,
                                memberIndices: indices,
                                running: running)
                        case .shell(let card):
                            shellRow(card)
                        case .line(let state):
                            ZCodeActivityLineView(
                                state: state,
                                onKillJob: onKillJob,
                                runningJobID: jobID(for: state)
                            )
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: showRows)
        .animation(.easeInOut(duration: 0.18), value: states.count)
        .onChange(of: runningCount) { _, count in
            guard !userToggled else { return }
            if count > 0 {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
            } else if !isStreaming {
                // Collapse when all tools finish on a settled turn (history
                // remounts collapsed by default via isExpanded=false).
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
            }
        }
        .onAppear {
            if !userToggled, shouldAutoExpand {
                isExpanded = true
            }
        }
    }

    private enum StackItem: Identifiable {
        case explore(id: String, counts: ExploreBucketCounts, running: Bool)
        case fileChange(
            id: String,
            counts: FileChangeGroupCounts,
            events: [ToolCallEvent],
            memberIndices: [Int],
            running: Bool)
        case line(ToolCallUIState)
        case shell(ShellCard)
        var id: String {
            switch self {
            case .explore(let id, _, _): return "explore-\(id)"
            case .fileChange(let id, _, _, _, _): return "fileChange-\(id)"
            case .line(let state): return state.id
            case .shell(let card): return "shell-\(card.index)-\(card.command)"
            }
        }
    }

    /// Consecutive searches/lists/reads collapse to one Explore card (2+).
    private var groupedItems: [StackItem] {
        let events = states.map { state -> ToolCallEvent in
            let running = state.status == .running || state.status == .pending
            let cmd: String? = (state.toolName == "run_shell" || state.toolName == "run_shell_command")
                ? state.input : nil
            return ToolCallEvent(name: state.toolName, isRunning: running, parsedCommand: cmd)
        }
        var items: [StackItem] = []
        for group in ToolCallGrouping.group(events) {
            switch group {
            case .explore(let counts, let indices):
                if counts.total >= 2 {
                    let running = indices.contains { events[$0].isRunning }
                    let id = indices.map { states[$0].id }.joined(separator: "+")
                    items.append(.explore(id: id, counts: counts, running: running))
                } else {
                    for i in indices {
                        items.append(.line(states[i]))
                    }
                }
            case .fileChange(let counts, let indices):
                if counts.total >= 2 {
                    let running = indices.contains { events[$0].isRunning }
                    let id = indices.map { states[$0].id }.joined(separator: "+")
                    items.append(.fileChange(
                        id: id,
                        counts: counts,
                        events: events,
                        memberIndices: indices,
                        running: running))
                } else {
                    for i in indices {
                        items.append(.line(states[i]))
                    }
                }
            case .shell(let card):
                items.append(.shell(card))
            case .skill(let card):
                items.append(.line(states[card.index]))
            case .agent(let card):
                items.append(.line(states[card.index]))
            case .standalone(let index, _):
                items.append(.line(states[index]))
            }
        }
        return items
    }

    @ViewBuilder
    private func exploreRow(counts: ExploreBucketCounts, running: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.activityVerb)
            Text(ExploreCardCopy.verb)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Palette.activityVerb)
            Text("·")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.Palette.activityDivider)
            Text(ExploreCardCopy.status(counts: counts))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.activityStatus)
                .lineLimit(1)
            if running {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("\(ExploreCardCopy.verb) · \(ExploreCardCopy.status(counts: counts))")
    }

    @ViewBuilder
    private func fileChangeRow(
        counts: FileChangeGroupCounts,
        events: [ToolCallEvent],
        memberIndices: [Int],
        running: Bool
    ) -> some View {
        let verb = FileChangeCardCopy.verb(events: events, memberIndices: memberIndices)
        let status = FileChangeCardCopy.status(counts: counts)
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.activityVerb)
            Text(verb)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Palette.activityVerb)
            Text("·")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.Palette.activityDivider)
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.activityStatus)
                .lineLimit(1)
            if running {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("\(verb) · \(status)")
    }


    @ViewBuilder
    private func shellRow(_ card: ShellCard) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = ShellCardCopy.status(card, now: context.date)
            let title = ShellCardCopy.title(card)
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.activityVerb)
                Text(card.kindLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.activityVerb)
                Text("·")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Theme.Palette.activityDivider)
                Text(status == card.kindLabel ? title : status)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.Palette.activityStatus)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if card.status == .running {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .accessibilityLabel("\(card.kindLabel) · \(status)")
        }
    }

    private var toolsHeader: some View {
        Button {
            userToggled = true
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = !showRows
            }
        } label: {
            HStack(spacing: 8) {
                // Collapsed: chevron.right · Expanded: chevron.down
                Image(systemName: showRows ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .frame(width: 12, alignment: .center)

                Text("Tools")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)

                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.activityDivider)

                Text(summaryStatus)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .lineLimit(1)

                if runningCount > 0 && !showRows {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                }

                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showRows ? "Collapse tools" : "Expand tools")
        .accessibilityHint("Shows shell, search, and other tool activity. Code edits stay visible separately.")
    }

    private var summaryStatus: String {
        if states.isEmpty { return "none" }
        if runningCount > 0 {
            return "\(states.count) · \(runningCount) running"
        }
        if failureCount > 0 {
            return "\(states.count) · \(failureCount) failed"
        }
        // Claude-style verb aggregation when all settled.
        let semantic = ToolActivitySummary.semantic(states)
        if !semantic.isEmpty {
            return semantic
        }
        if successCount == states.count {
            return "\(states.count) completed"
        }
        return "\(states.count) step\(states.count == 1 ? "" : "s")"
    }

    /// Match a `task` tool row to a BackgroundJobManager subagent job by
    /// description prefix (`type: description`).
    private func jobID(for state: ToolCallUIState) -> UUID? {
        guard state.toolName == "task", state.status == .running else { return nil }
        guard let data = state.input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = (obj["subagent_type"] as? String) ?? "general-purpose"
        let desc = (obj["description"] as? String) ?? ""
        let needle = desc.isEmpty ? type : "\(type): \(desc)"
        return backgroundJobs.first { job in
            job.kind == .subagent
                && job.status == .running
                && (job.command == needle || job.command.contains(desc) || job.command.contains(type))
        }?.id
    }
}

// MARK: - Semantic collapsed summary (Claude-style)

/// Pure aggregation of tool states for the Tools header.
enum ToolActivitySummary {
    /// e.g. "Read 3 files · Ran 2 commands · Edited 1 file"
    static func semantic(_ states: [ToolCallUIState]) -> String {
        guard !states.isEmpty else { return "" }
        var reads = 0
        var runs = 0
        var edits = 0
        var searches = 0
        var lists = 0
        var tasks = 0
        var other = 0
        for s in states where s.status == .success || s.status == .failure {
            switch s.toolName {
            case "read_file", "read_file_range", "XcodeRead":
                reads += 1
            case "run_shell", "run_shell_command":
                runs += 1
            case "edit_file", "write_file", "apply_patch", "search_replace",
                 "XcodeWrite", "XcodeUpdate":
                edits += 1
            case "grep_code", "glob_files", "code_search", "web_search":
                searches += 1
            case "list_directory", "XcodeLS":
                lists += 1
            case "task":
                tasks += 1
            default:
                other += 1
            }
        }
        var parts: [String] = []
        if reads > 0 {
            parts.append(reads == 1 ? "Read 1 file" : "Read \(reads) files")
        }
        if lists > 0 {
            parts.append(lists == 1 ? "Listed 1 dir" : "Listed \(lists) dirs")
        }
        if searches > 0 {
            parts.append(searches == 1 ? "1 search" : "\(searches) searches")
        }
        if runs > 0 {
            parts.append(runs == 1 ? "Ran 1 command" : "Ran \(runs) commands")
        }
        if edits > 0 {
            parts.append(edits == 1 ? "Edited 1 file" : "Edited \(edits) files")
        }
        if tasks > 0 {
            parts.append(tasks == 1 ? "1 subagent" : "\(tasks) subagents")
        }
        if other > 0 && parts.isEmpty {
            parts.append(other == 1 ? "1 step" : "\(other) steps")
        } else if other > 0 {
            parts.append("+\(other)")
        }
        return parts.joined(separator: " · ")
    }
}

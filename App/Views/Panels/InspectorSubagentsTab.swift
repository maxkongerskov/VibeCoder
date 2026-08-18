//
//  InspectorSubagentsTab.swift
//
//  Directory (Running / Ended) + per-agent detail. Polls jobs while visible.
//

import SwiftUI
import AgentCore

struct InspectorSubagentsTab: View {
    let conversation: Conversation?
    var liveTaskStates: [ToolCallUIState] = []
    var pendingOpen: InspectorSubagentOpenRequest?
    var onConsumedOpen: () -> Void = {}

    @State private var jobs: [BackgroundJobSnapshot] = []
    @State private var selectedID: String?
    @State private var endedLimit = InspectorSubagentDirectory.endedPageSize
    @State private var loadFailed = false
    @State private var now = Date()
    @State private var threadByJob: [UUID: [SubagentThreadItem]] = [:]
    @State private var sessionMetadata: [SubagentSessionMetadata] = []

    private var directory: InspectorSubagentDirectory {
        InspectorSubagentDirectory.build(
            conversation: conversation,
            jobs: jobs,
            liveTaskStates: liveTaskStates,
            sessionMetadata: sessionMetadata
        )
    }

    /// Restart the poll when the live transcript actually changes
    /// (message count / last id), not only when the conversation UUID does.
    private var pollEpoch: String {
        let last = conversation?.messages.last?.id.uuidString ?? "-"
        return "\(conversation?.id.uuidString ?? "")-\(conversation?.messages.count ?? 0)-\(last)-\(liveTaskStates.count)"
    }

    private var selected: InspectorSubagentEntry? {
        guard let selectedID else { return nil }
        return (directory.running + directory.ended).first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if loadFailed {
                emptyState(InspectorSubagentDirectory.loadFailedMessage)
                    .accessibilityIdentifier("inspector-subagents-load-failed")
            } else if let selected {
                detail(selected)
            } else if directory.isEmpty {
                emptyState(InspectorSubagentDirectory.allEmptyMessage)
                    .accessibilityIdentifier("inspector-subagents-empty")
            } else {
                directoryList
            }
        }
        .task(id: pollEpoch) {
            await pollLoop()
        }
        .onAppear { applyPendingOpen() }
        .onChange(of: pendingOpen) { _, _ in
            applyPendingOpen()
        }
        .onChange(of: conversation?.id) { _, _ in
            selectedID = nil
            endedLimit = InspectorSubagentDirectory.endedPageSize
        }
    }

    // MARK: - Directory

    private var directoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                section(
                    title: InspectorSubagentDirectory.runningTitle,
                    empty: directory.running.isEmpty
                        ? InspectorSubagentDirectory.runningEmptyMessage
                        : nil
                ) {
                    ForEach(directory.running) { entry in
                        row(entry)
                    }
                }

                if !directory.ended.isEmpty {
                    let visibleEnded = InspectorSubagentDirectory.pagedEnded(
                        directory.ended,
                        limit: endedLimit
                    )
                    section(title: InspectorSubagentDirectory.endedTitle, empty: nil) {
                        ForEach(visibleEnded) { entry in
                            row(entry)
                        }
                        if directory.ended.count > endedLimit {
                            Button {
                                endedLimit += InspectorSubagentDirectory.endedPageSize
                            } label: {
                                Text(InspectorSubagentDirectory.showMoreTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 6)
                            .padding(.top, 2)
                            .accessibilityIdentifier("inspector-subagents-show-more")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        empty: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.secondary)
                .padding(.horizontal, 6)
            if let empty {
                Text(empty)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("inspector-subagents-running-empty")
            } else {
                content()
            }
        }
    }

    private func row(_ entry: InspectorSubagentEntry) -> some View {
        let on = selectedID == entry.id
        return Button {
            selectedID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.type)
                        .font(Theme.Typography.mono(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.subagentType)
                        .lineLimit(1)
                    Text(entry.description.isEmpty ? "Subagent" : entry.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(entry.status.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor(entry.status))
                    Text(entry.elapsedLabel(now: now))
                        .font(Theme.Typography.mono(size: 10.5))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                if let compact = InspectorSubagentDirectory.formatExtrasCompact(entry.extras) {
                    Text(compact)
                        .font(Theme.Typography.mono(size: 10))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .lineLimit(1)
                        .padding(.top, 1)
                        .accessibilityIdentifier("inspector-subagent-extras-compact-\(entry.id)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Theme.Palette.accentSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.type), \(entry.description), \(entry.status.title)")
        .accessibilityIdentifier("inspector-subagent-row-\(entry.id)")
    }

    // MARK: - Detail

    private func detail(_ entry: InspectorSubagentEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    selectedID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Subagents")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector-subagent-back")
                Spacer(minLength: 8)
                if entry.canKill {
                    Button {
                        kill(entry)
                    } label: {
                        Text("Kill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.error)
                    }
                    .buttonStyle(.plain)
                    .help("Stop this subagent")
                    .accessibilityIdentifier("inspector-subagent-kill")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.type)
                            .font(Theme.Typography.mono(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.subagentType)
                        if !entry.description.isEmpty {
                            Text(entry.description)
                                .font(Theme.Typography.ui)
                                .foregroundStyle(Theme.Palette.primary)
                        }
                        HStack(spacing: 8) {
                            Text(entry.status.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(statusColor(entry.status))
                            Text(entry.elapsedLabel(now: now))
                                .font(Theme.Typography.mono(size: 11.5))
                                .foregroundStyle(Theme.Palette.tertiary)
                        }
                    }

                    extrasBlock(entry)

                    if !entry.prompt.isEmpty {
                        labeledBlock(
                            InspectorSubagentDirectory.promptTitle,
                            text: entry.prompt
                        )
                    }

                    threadBlock(entry)
                    resultBlock(entry)
                }
                .padding(12)
            }
        }
        .accessibilityIdentifier("inspector-subagent-detail")
    }

    @ViewBuilder
    private func extrasBlock(_ entry: InspectorSubagentEntry) -> some View {
        let extras = entry.extras
        if extras.hasAny {
            VStack(alignment: .leading, spacing: 6) {
                if let duration = InspectorSubagentDirectory.formatDurationLine(extras) {
                    extraRow(
                        InspectorSubagentDirectory.durationTitle,
                        value: duration,
                        identifier: "inspector-subagent-duration"
                    )
                }
                if let tokens = InspectorSubagentDirectory.formatTokenLine(extras) {
                    extraRow(
                        InspectorSubagentDirectory.tokensTitle,
                        value: tokens,
                        identifier: "inspector-subagent-tokens"
                    )
                }
                if let tools = InspectorSubagentDirectory.formatToolLine(extras) {
                    extraRow(
                        InspectorSubagentDirectory.toolsTitle,
                        value: tools,
                        identifier: "inspector-subagent-tools"
                    )
                }
            }
            .accessibilityIdentifier("inspector-subagent-extras")
        }
    }

    private func extraRow(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(value)
                .font(Theme.Typography.mono(size: 11.5))
                .foregroundStyle(Theme.Palette.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }

    private func threadBlock(_ entry: InspectorSubagentEntry) -> some View {
        let items = threadItems(for: entry)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Thread")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
            if items.isEmpty {
                if entry.status.isActive {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Thinking…")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                    .accessibilityIdentifier("inspector-subagent-thinking")
                } else {
                    Text("No tool steps recorded")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiary)
                        .accessibilityIdentifier("inspector-subagent-thread-empty")
                }
            } else {
                ForEach(items) { item in
                    threadRow(item)
                }
            }
        }
    }

    /// Parent summary / job heartbeat — never labeled as the child thread.
    @ViewBuilder
    private func resultBlock(_ entry: InspectorSubagentEntry) -> some View {
        let items = threadItems(for: entry)
        let raw = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let hide = raw.isEmpty
            || SubagentThreadBuilder.isHeartbeatOutput(raw)
            || (!items.isEmpty && items.contains(where: { $0.kind == .assistant && $0.text == raw }))
        if hide { EmptyView() } else if items.isEmpty {
            labeledBlock("Result", text: raw)
        }
    }

    @ViewBuilder
    private func threadRow(_ item: SubagentThreadItem) -> some View {
        switch item.kind {
        case .thought:
            DisclosureGroup {
                Text(item.text)
                    .font(Theme.Typography.ui)
                    .foregroundStyle(Theme.Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Thought")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
        case .assistant:
            Text(item.text)
                .font(Theme.Typography.ui)
                .foregroundStyle(Theme.Palette.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ZCodeActivityLineView(state: toolState(item), compact: true)
        }
    }

    private func toolState(_ item: SubagentThreadItem) -> ToolCallUIState {
        let status: ToolCallStatus
        switch item.status {
        case .pending: status = .pending
        case .running: status = .running
        case .success: status = .success
        case .failure: status = .failure
        }
        return ToolCallUIState(
            id: item.id,
            toolName: item.toolName ?? "tool",
            status: status,
            input: item.arguments,
            output: item.output
        )
    }

    private func threadItems(for entry: InspectorSubagentEntry) -> [SubagentThreadItem] {
        if !entry.threadItems.isEmpty { return entry.threadItems }
        if let id = entry.taskId, let items = threadByJob[id], !items.isEmpty {
            return items
        }
        if let uuid = UUID(uuidString: entry.id),
           let items = threadByJob[uuid], !items.isEmpty {
            return items
        }
        return []
    }

    private func labeledBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
            Text(text)
                .font(Theme.Typography.ui)
                .foregroundStyle(Theme.Palette.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(Theme.Typography.ui)
            .foregroundStyle(Theme.Palette.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
    }

    private func statusColor(_ status: InspectorSubagentStatus) -> Color {
        switch status {
        case .running: return Theme.Palette.accent
        case .waiting: return Theme.Palette.secondary
        case .blocked: return Theme.Palette.warning
        case .completed: return Theme.Palette.success
        case .failed: return Theme.Palette.error
        case .cancelled, .lost: return Theme.Palette.tertiary
        }
    }

    // MARK: - Data

    private func pollLoop() async {
        await refresh()
        applyPendingOpen()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await refresh()
            now = Date()
            applyPendingOpen()
        }
    }

    private func refresh() async {
        guard let conversation else {
            jobs = []
            sessionMetadata = []
            threadByJob = [:]
            loadFailed = false
            return
        }
        let scoped = await BackgroundJobManager.shared.list(conversationID: conversation.id)
        let live = await BackgroundJobManager.shared.listRunning()
        let allSubs = await BackgroundJobManager.shared.listSubagents()
        var merged: [UUID: BackgroundJobSnapshot] = [:]
        for snap in scoped where snap.kind == .subagent {
            merged[snap.id] = snap
        }
        for snap in live where snap.kind == .subagent {
            if snap.conversationID == nil || snap.conversationID == conversation.id {
                merged[snap.id] = snap
            }
        }
        for snap in allSubs {
            if snap.conversationID == nil || snap.conversationID == conversation.id {
                merged[snap.id] = snap
            }
        }
        jobs = Array(merged.values)
        let directory = InspectorSubagentDirectory.build(
            conversation: conversation,
            jobs: jobs,
            liveTaskStates: liveTaskStates
        )
        var ids = Set(jobs.map(\.id))
        for entry in directory.running + directory.ended {
            if let id = entry.taskId { ids.insert(id) }
        }
        var nextThread: [UUID: [SubagentThreadItem]] = [:]
        for id in ids {
            var items = await BackgroundJobManager.shared.threadItems(for: id)
            if items.isEmpty {
                items = await SubagentThreadStore.shared.items(for: id)
            }
            if !items.isEmpty {
                nextThread[id] = items
            }
        }
        threadByJob = nextThread
        sessionMetadata = await loadSessionMetadata(
            conversationID: conversation.id,
            directory: directory
        )
        loadFailed = false
    }

    private func loadSessionMetadata(
        conversationID: UUID,
        directory: InspectorSubagentDirectory
    ) async -> [SubagentSessionMetadata] {
        var byAgent: [String: SubagentSessionMetadata] = [:]
        var seen = Set<String>()

        func load(agentId: String) async {
            let key = AgentMailbox.normalizeAgentId(agentId).lowercased()
            guard seen.insert(key).inserted else { return }
            if let meta = await SubagentSessionStore.shared.loadMetadata(
                parentConversationID: conversationID,
                agentId: agentId
            ) {
                byAgent[key] = meta
            }
        }

        for entry in directory.running + directory.ended {
            if let agentId = entry.extras.agentId {
                await load(agentId: agentId)
            }
        }

        let root = await SubagentSessionStore.shared.resolvedRoot()
        let parentDir = root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path) {
            for name in names {
                await load(agentId: name)
            }
        }
        return Array(byAgent.values)
    }

    private func kill(_ entry: InspectorSubagentEntry) {
        guard let id = entry.taskId else { return }
        Task {
            _ = await BackgroundJobManager.shared.kill(id)
            await refresh()
        }
    }

    private func applyPendingOpen() {
        guard let pendingOpen else { return }
        if let id = pendingOpen.matchingID(in: directory) {
            selectedID = id
            onConsumedOpen()
        }
    }
}

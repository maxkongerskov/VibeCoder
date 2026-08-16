//
//  InspectorPanelView.swift
//
//  Right inspector column: Files + Changes + Subagents. No browser / whiteboard.
//

import SwiftUI
import AgentCore

/// Observes the live chat VM so Subagents sees in-flight `task` calls
/// (the sidebar `app.conversations` snapshot is a stale struct copy).
struct InspectorLiveHost: View {
    @ObservedObject var viewModel: ChatViewModel
    let openedProjectURL: URL?

    var body: some View {
        InspectorPanelView(
            projectRoot: InspectorWorkspace.projectRoot(
                conversation: viewModel.conversation,
                openedProjectURL: openedProjectURL
            ),
            conversation: viewModel.conversation,
            liveTaskStates: {
                var seen = Set<String>()
                return viewModel.toolCallsByMessage.values.flatMap { $0 }.filter {
                    $0.toolName == "task" && seen.insert($0.id).inserted
                }
            }()
        )
    }
}

struct InspectorPanelView: View {
    let projectRoot: URL?
    let conversation: Conversation?
    var liveTaskStates: [ToolCallUIState] = []

    @State private var selectedTab: InspectorPanelTab = .files
    @State private var pendingSubagentOpen: InspectorSubagentOpenRequest?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.45)
            Group {
                switch selectedTab {
                case .files:
                    InspectorFilesTab(projectRoot: projectRoot)
                case .changes:
                    InspectorChangesTab(conversation: conversation, projectRoot: projectRoot)
                case .subagents:
                    InspectorSubagentsTab(
                        conversation: conversation,
                        liveTaskStates: liveTaskStates,
                        pendingOpen: pendingSubagentOpen,
                        onConsumedOpen: { pendingSubagentOpen = nil }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
        .background(Theme.Palette.subtle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .onAppear { consumePendingSubagentOpen() }
        .onReceive(NotificationCenter.default.publisher(for: .openSubagentInInspector)) { note in
            applySubagentOpen(InspectorSubagentOpenRequest.parse(note))
            _ = InspectorSubagentOpenStore.take()
        }
    }

    private func consumePendingSubagentOpen() {
        if let pending = InspectorSubagentOpenStore.take() {
            applySubagentOpen(pending)
        }
    }

    private func applySubagentOpen(_ request: InspectorSubagentOpenRequest) {
        selectedTab = .subagents
        pendingSubagentOpen = request
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(InspectorPanelTab.allCases) { tab in
                let on = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(on ? Theme.Palette.accent : Color.clear)
                                .frame(height: 1.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("inspector-tab-\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

//
//  InspectorPanelAttach.swift
//
//  Self-contained `.inspector` attach API. Parent applies one modifier
//  on `navigationSplit`; menu / palette only post notifications.
//

import SwiftUI
import AgentCore

extension Notification.Name {
    /// View menu / palette — toggle the right inspector (⌥⌘B).
    static let toggleInspectorRequested = Notification.Name("agentos.toggleInspector")
    /// Force visibility. `userInfo["visible"]` is Bool.
    static let setInspectorVisible = Notification.Name("agentos.setInspectorVisible")
    /// Open a subagent row in the inspector. userInfo: taskId / toolCallId / type / description.
    static let openSubagentInInspector = Notification.Name("agentos.openSubagentInInspector")
}

struct InspectorPanelAttach: ViewModifier {
    @EnvironmentObject var app: AppViewModel
    @AppStorage(InspectorVisibilityStore.key) private var isPresented =
        InspectorVisibilityStore.defaultVisible

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $isPresented) {
                Group {
                    if let id = app.selectedConversationID {
                        InspectorLiveHost(
                            viewModel: app.chatViewModel(for: id),
                            openedProjectURL: app.openedProject?.url
                        )
                    } else {
                        InspectorPanelView(
                            projectRoot: app.openedProject?.url,
                            conversation: nil
                        )
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 300, max: 480)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleInspectorRequested)) { _ in
                isPresented.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .setInspectorVisible)) { note in
                if let visible = InspectorVisibilityStore.visible(from: note) {
                    isPresented = visible
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSubagentInInspector)) { note in
                // Stash only when the inspector content is not mounted yet.
                if !isPresented {
                    InspectorSubagentOpenStore.pending = InspectorSubagentOpenRequest.parse(note)
                }
                isPresented = true
            }
    }

    private var selectedConversation: Conversation? {
        guard let id = app.selectedConversationID else { return nil }
        return app.conversations.first(where: { $0.id == id })
    }
}

extension View {
    func vibecoderInspectorPanel() -> some View {
        modifier(InspectorPanelAttach())
    }
}

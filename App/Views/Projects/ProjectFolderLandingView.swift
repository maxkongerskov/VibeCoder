//
//  ProjectFolderLandingView.swift
//  AgentOS — Claude Edition
//
//  Detail-pane view shown when the user double-clicks a project card
//  on the Projects landing grid. Three things:
//
//    1. Header — back arrow (returns to Projects grid) + folder icon
//       + project name.
//    2. Top chat composer — typing + Send creates a new conversation
//       bound to this project (projectRoot = project.url.path),
//       selects it, and switches the sidebar tab so the new chat
//       streams in the main detail pane (Claude.ai behaviour).
//    3. List of chats already started in this project — filtered from
//       `app.conversations` by matching `projectRoot`. Each row opens
//       the conversation when clicked.
//
//  Conversations created here also appear in the sidebar Recents
//  list naturally — no separate filtering needed; project binding is
//  metadata, not a routing decision.
//

import SwiftUI
import AgentCore

@MainActor
struct ProjectFolderLandingView: View {
    let project: Project

    @EnvironmentObject var app: AppViewModel
    @State private var draft: String = ""

    // MARK: - Derived

    /// Conversations bound to this project, newest first. Path
    /// comparison standardises both URLs so trailing-slash or
    /// `~` expansion differences don't cause false negatives.
    private var projectChats: [Conversation] {
        let needle = project.url.standardizedFileURL.path
        return app.conversations
            .filter { conv in
                guard let url = conv.projectRoot else { return false }
                return url.standardizedFileURL.path == needle
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    composer
                        .padding(.top, Theme.Spacing.l)

                    chatList
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                app.openedProject = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Projects")

            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)

            Text(project.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.ml)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Start a new chat in this project")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
                .tracking(0.5)

            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                TextField("What do you want to work on here?",
                          text: $draft,
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .lineLimit(1 ... 6)
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.subtle)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card,
                                         style: .continuous)
                            .stroke(Theme.Palette.divider, lineWidth: 0.5)
                    )
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Theme.Palette.accent
                                            : Theme.Palette.tertiary.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Start a new chat (⏎)")
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send flow: create a project-bound conversation, fire the user's
    /// message into its ChatViewModel, and clear `openedProject` so
    /// the chat detail pane takes over. Matches Claude.ai's "send
    /// from project page → navigate into the new chat" behaviour.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let newID = app.newConversation(in: project)
        draft = ""
        app.selectedConversationID = newID

        let vm = app.chatViewModel(for: newID)
        vm.send(text)

        // Clear the project view AFTER seeding the send so the
        // transition is one render: project landing → chat view
        // with the user's message already submitted and the assistant
        // about to stream.
        app.openedProject = nil
    }

    // MARK: - Chat list

    @ViewBuilder
    private var chatList: some View {
        if projectChats.isEmpty {
            emptyChats
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Chats in this project")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .tracking(0.5)

                VStack(spacing: 0) {
                    ForEach(projectChats) { conv in
                        chatRow(conv)
                        if conv.id != projectChats.last?.id {
                            Divider()
                                .background(Theme.Palette.divider)
                        }
                    }
                }
                .background(Theme.Palette.subtle)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card,
                                     style: .continuous)
                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                )
            }
            .padding(.top, Theme.Spacing.m)
        }
    }

    private var emptyChats: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.tertiary)
            Text("No chats in this project yet — start one above.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func chatRow(_ conv: Conversation) -> some View {
        Button {
            app.selectedConversationID = conv.id
            app.openedProject = nil
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title.isEmpty ? "Untitled" : conv.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                    Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

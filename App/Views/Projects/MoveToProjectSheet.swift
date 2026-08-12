//
//  MoveToProjectSheet.swift
//  AgentOS — Claude Edition
//
//  Sheet shown when the user right-clicks a sidebar conversation and
//  picks "Move to project". Two paths:
//
//    1. **Pick an existing project** — vertical list of all currently
//       registered projects (via the ProjectsViewModel snapshot). Tap a
//       row to bind the conversation; sheet dismisses.
//    2. **Create a new project** — text field + Create button at the
//       bottom. Creates the project folder via ProjectsService, binds
//       the conversation to it in the same gesture, dismisses.
//
//  Detached projects (i.e. "no project") can be reached by tapping
//  the "Detach from any project" row at the very top. That sets
//  projectRoot to nil.
//

import SwiftUI
import AgentCore

@MainActor
struct MoveToProjectSheet: View {
    /// The conversation being moved. We only read its title for the
    /// header copy; the actual bind happens via `app.moveConversationToProject`.
    let conversation: Conversation

    @EnvironmentObject var app: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// Owns the live project list. Constructed locally so this sheet
    /// stays self-contained — no need for the caller to inject a VM.
    @StateObject private var projectsVM = ProjectsViewModel()

    @State private var newName: String = ""
    @State private var newError: String? = nil
    @State private var creating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 520, height: 560)
        .background(Theme.Palette.canvas)
        .task { await projectsVM.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Move to project")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Text("Bind \"\(conversation.title.isEmpty ? "Untitled" : conversation.title)\" to an existing project, or create a new one.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                detachRow

                if !projectsVM.projects.isEmpty {
                    Text("YOUR PROJECTS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .tracking(0.5)
                        .padding(.top, Theme.Spacing.s)
                        .padding(.horizontal, Theme.Spacing.s)

                    VStack(spacing: 4) {
                        ForEach(projectsVM.projects) { p in
                            projectRow(p)
                        }
                    }
                }

                Text("CREATE A NEW PROJECT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .tracking(0.5)
                    .padding(.top, Theme.Spacing.m)
                    .padding(.horizontal, Theme.Spacing.s)

                createNewProjectCard
            }
            .padding(Theme.Spacing.m)
        }
    }

    // MARK: - Rows

    private var detachRow: some View {
        Button {
            app.moveConversationToProject(conversation.id, project: nil)
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "folder.badge.minus")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Detach from any project")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                    Text("Conversation becomes untethered.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                Spacer()
                if conversation.projectRoot == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(Theme.Spacing.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.subtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card,
                                 style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectRow(_ p: Project) -> some View {
        let isCurrent = conversation.projectRoot?.standardizedFileURL.path
            == p.url.standardizedFileURL.path
        return Button {
            app.moveConversationToProject(conversation.id, project: p)
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                    Text(p.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(Theme.Spacing.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.subtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card,
                                 style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Create new project

    private var createNewProjectCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 22)
                TextField("Project name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { createAndBind() }
                Button {
                    createAndBind()
                } label: {
                    if creating {
                        ProgressView().scaleEffect(0.6).frame(width: 18, height: 18)
                    } else {
                        Text("Create")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(creating ||
                          newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let err = newError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.error)
            }
        }
        .padding(Theme.Spacing.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                    style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card,
                             style: .continuous)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    private func createAndBind() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !creating else { return }
        creating = true
        newError = nil
        Task {
            let result = await projectsVM.createReturning(name)
            await MainActor.run {
                creating = false
                switch result {
                case .success(let project):
                    app.moveConversationToProject(conversation.id, project: project)
                    dismiss()
                case .failure(let err):
                    newError = err.message
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
    }
}

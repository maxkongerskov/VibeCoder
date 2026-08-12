//
//  NewProjectSheet.swift
//  AgentOS — Claude Edition
//
//  Multi-step "New Project" sheet. Internal `step` enum drives content;
//  back arrow returns to the chooser. Two honest paths:
//    • Start from scratch     → create a named folder, optionally at a
//                               location the user picks.
//    • Use an existing folder → register a folder the user already owns.
//
//  2026-06-10: rewired from a visual shell. Previously the callback was
//  `(String) -> Void` — it could only carry a NAME, so the folder the
//  user picked was silently discarded and every project landed in the
//  managed root. Now the callback carries a `NewProjectRequest` with the
//  real URLs, and the parent forwards it to `ProjectsService`. The old
//  "Import a project" door (a Coming-Soon stub) was removed — it's
//  subsumed by "Use an existing folder" (point at the folder a past chat
//  created).
//

import SwiftUI
import AppKit
import AgentCore

/// What the user asked to create. Carries the real folder URLs the sheet
/// collected so nothing is dropped on the way to `ProjectsService`.
enum NewProjectRequest {
    /// Create a folder named `name`. `location == nil` → managed root;
    /// otherwise create it inside the user-picked `location`. `instructions`
    /// are written to the project's `.agentos/instructions.md`; `files` are
    /// copied into the new folder.
    case scratch(name: String, location: URL?, instructions: String, files: [URL])
    /// Register a folder the user already owns, in place.
    case existingFolder(url: URL)
}

@MainActor
struct NewProjectSheet: View {

    @Binding var isPresented: Bool

    /// Called when the user taps Create with the collected request. The
    /// parent (ProjectsView) forwards it to `ProjectsViewModel`.
    var onCreate: (NewProjectRequest) -> Void = { _ in }

    enum Step: Equatable {
        case chooser
        case startFromScratch
        case useExistingFolder
    }

    @State private var step: Step = .chooser

    // Shared form state across sub-screens.
    @State private var memoryOn: Bool = true

    // Start-from-scratch state.
    @State private var sName: String = ""
    @State private var sInstructions: String = ""
    @State private var sAddedFileURLs: [URL] = []
    /// User-picked location for the new project folder. `nil` → the
    /// managed root (the default). Set when the user picks a location.
    @State private var sLocationURL: URL? = nil
    @State private var sError: String? = nil

    // Use-existing-folder state.
    @State private var eFolderURL: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .chooser:            chooserPage
            case .startFromScratch:   startFromScratchPage
            case .useExistingFolder:  useExistingFolderPage
            }
        }
        .frame(width: 580, height: 560)
        .background(Theme.Palette.subtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }

    // MARK: - Page 1: chooser

    private var chooserPage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.ml) {
            HStack {
                Spacer()
                closeButton
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
                Text("Create a new project")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Text("A dedicated place for ongoing work where context builds over time. Files and instructions stay in a folder on your computer.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Spacing.s + 2) {
                chooserOption(
                    icon: "plus",
                    title: "Start from scratch",
                    subtitle: "Set up a new folder with instructions and files"
                ) { step = .startFromScratch }

                chooserOption(
                    icon: "folder.badge.plus",
                    title: "Use an existing folder",
                    subtitle: "Point \(AppBranding.displayName) at a folder already on your machine"
                ) { step = .useExistingFolder }
            }

            Spacer()
        }
        .padding(Theme.Spacing.l - 2)
    }

    private func chooserOption(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.ml - 2) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 32, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.Palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            .padding(Theme.Spacing.m + 2)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card + 2, style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 2a: start from scratch

    private var startFromScratchPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            subHeader(title: "Start a new project")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m + 2) {

                    field("Name", required: true) {
                        TextField("Project name", text: $sName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    field("Instructions") {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $sInstructions)
                                .font(.system(size: 12))
                                .frame(minHeight: 70)
                                .padding(Theme.Spacing.xs + 2)
                                .scrollContentBackground(.hidden)
                                .background(Theme.Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                        .stroke(Theme.Palette.divider, lineWidth: 0.5)
                                )

                            if sInstructions.isEmpty {
                                Text("Tell \(AppBranding.displayName) how to work in this project (optional)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Palette.tertiary)
                                    .padding(.horizontal, Theme.Spacing.s + 4)
                                    .padding(.vertical, Theme.Spacing.s + 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    field("Add Files") {
                        Button(action: pickFilesToAdd) {
                            HStack(spacing: Theme.Spacing.s) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.Palette.accent)
                                Text(sAddedFileURLs.isEmpty
                                     ? "Drop files here or click to browse"
                                     : "\(sAddedFileURLs.count) file(s) selected — add more")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Palette.secondary)
                                Spacer()
                            }
                            .padding(Theme.Spacing.s + 2)
                            .background(Theme.Palette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                    .stroke(style: StrokeStyle(lineWidth: 0.6, dash: [4]))
                                    .foregroundStyle(Theme.Palette.divider)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    field("Choose Project Location") {
                        Button(action: pickProjectLocation) {
                            HStack(spacing: Theme.Spacing.s) {
                                Image(systemName: "map")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Palette.secondary)
                                Text(sLocationURL?.path ?? "Default location (\(AppBranding.projectsFolderName))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.primary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            .padding(Theme.Spacing.s + 2)
                            .background(Theme.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let err = sError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.error)
                    }
                }
                .padding(Theme.Spacing.l - 4)
            }
            footer(
                createEnabled: !sName.trimmingCharacters(in: .whitespaces).isEmpty,
                onCreate: createFromScratch
            )
        }
    }

    // MARK: - Page 2b: use an existing folder

    private var useExistingFolderPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            subHeader(title: "Use an existing folder")
            VStack(alignment: .leading, spacing: Theme.Spacing.m + 2) {
                Text("Pick a folder. \(AppBranding.displayName) will treat its files as project context and add instructions to shape how it approaches the work.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                field("Choose folder") {
                    Button(action: pickExistingFolder) {
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Palette.accent)
                            Text(eFolderURL?.path ?? "Select a folder…")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.Palette.primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .padding(Theme.Spacing.s + 2)
                        .background(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                .stroke(Theme.Palette.divider, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.l - 4)
            Spacer()
            footer(createEnabled: eFolderURL != nil, onCreate: createFromExistingFolder)
        }
    }

    // MARK: - Shared sub-pieces

    private func subHeader(title: String) -> some View {
        HStack(spacing: Theme.Spacing.s + 2) {
            Button { step = .chooser } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to options")

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.primary)
            Spacer()
            closeButton
        }
        .padding(.horizontal, Theme.Spacing.l - 4)
        .padding(.vertical, Theme.Spacing.ml)
    }

    private var closeButton: some View {
        Button { isPresented = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                    .textCase(.uppercase)
                if required {
                    Text("*")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.error)
                }
            }
            content()
        }
    }

    private func footer(createEnabled: Bool, onCreate: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider().background(Theme.Palette.divider).opacity(0.6)
            HStack {
                // Memory toggle on the left
                HStack(spacing: Theme.Spacing.s) {
                    Toggle("", isOn: $memoryOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("Memory is on")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!createEnabled)
            }
            .padding(.horizontal, Theme.Spacing.l - 4)
            .padding(.vertical, Theme.Spacing.m)
        }
    }

    // MARK: - Actions

    private func pickFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            // De-dupe by path so re-picking the same file doesn't queue
            // two copies.
            for url in panel.urls where !sAddedFileURLs.contains(url) {
                sAddedFileURLs.append(url)
            }
        }
    }

    private func pickProjectLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true   // show the "New Folder" button
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sLocationURL = url
        }
    }

    private func pickExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true   // show the "New Folder" button
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            eFolderURL = url
        }
    }

    private func createFromScratch() {
        let trimmed = sName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            sError = "Project name is required."
            return
        }
        onCreate(.scratch(name: trimmed, location: sLocationURL,
                          instructions: sInstructions, files: sAddedFileURLs))
        isPresented = false
    }

    private func createFromExistingFolder() {
        guard let url = eFolderURL else { return }
        onCreate(.existingFolder(url: url))
        isPresented = false
    }
}

// MARK: - Preview

#Preview("New Project — chooser") {
    StatefulPreviewWrapper(true) { binding in
        NewProjectSheet(isPresented: binding, onCreate: { _ in })
    }
}

/// Tiny binding wrapper so previews can drive the @Binding without a parent.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}

//
//  VibeCoderApp.swift
//
//  App entry. Opens straight into the main UI — no onboarding.
//

import SwiftUI
import AppKit
import AgentCore

@main
struct VibeCoderApp: App {
    @StateObject private var app = AppViewModel()

    /// Brief splash while settings load, then RootView.
    @State private var launchPhase: LaunchPhase = .loading

    private enum LaunchPhase: Equatable {
        case loading
        case ready
    }

    var body: some Scene {
        // Empty WindowGroup title — BuildCode keeps a name for the Window menu
        // but strips it from the title bar via toolbar/chrome. We do both:
        // no nav title + WindowChromeAdjuster hides titleVisibility.
        WindowGroup {
            ZStack {
                switch launchPhase {
                case .loading:
                    Color.clear
                        .transition(.opacity)

                case .ready:
                    RootView()
                        .environmentObject(app)
                        .hidesSystemFocusRing()
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 960, minHeight: 620)
            .background(Theme.Palette.canvas)
            .onReceive(NotificationCenter.default.publisher(for: .openWorkspaceRequested)) { _ in
                openWorkspace()
            }
            .task {
                // RENDER-CRITICAL PATH FIRST. Never block first paint on
                // network (refreshModels / backend probes live in boot()).
                app.settings = await SettingsStore.shared.current()
                // Onboarding is retired — always land on the main UI.
                // Persist via AppViewModel.settings.didSet only (single write path).
                // Dual SettingsStore.update + property assign used to race two
                // concurrent replace()s on first launch (Wave C bug-hunt).
                if !app.settings.hasCompletedOnboarding {
                    app.settings.hasCompletedOnboarding = true
                }
                launchPhase = .ready

                await app.boot()
            }
        }
        // Unified toolbar keeps traffic lights + sidebar toggle in one strip;
        // title itself is removed (see RemoveWindowTitleModifier + chrome).
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New conversation") {
                    NotificationCenter.default.post(name: .newConversationRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Workspace…") {
                    NotificationCenter.default.post(name: .openWorkspaceRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            // Replaces the unused Save group so ⌘W is Close Window, not Save.
            // DEBUG View → Worktree Review keeps ⌘⇧W.
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .settingsRequested, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            // ⌘F belongs on Edit (system Find group). A View-menu button with
            // the same shortcut is swallowed by AppKit and never appears.
            CommandGroup(after: .pasteboard) {
                Button("Find in Task") {
                    NotificationCenter.default.post(name: .findInTaskRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            // Merge into the system View menu. CommandMenu("View") used to
            // create a second View menu next to Show Tab Bar / Full Screen.
            CommandGroup(after: .sidebar) {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Stop Agent") {
                    NotificationCenter.default.post(name: .cancelAgentRequested, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])

                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebarRequested, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Toggle Side Pane") {
                    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Button("Toggle Terminal") {
                    NotificationCenter.default.post(name: .toggleTerminalRequested, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command])

                Button("Previous Task") {
                    NotificationCenter.default.post(name: .previousTaskRequested, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Task") {
                    NotificationCenter.default.post(name: .nextTaskRequested, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                #if DEBUG
                Divider()

                Button("Show Patch Review (debug)") {
                    NotificationCenter.default.post(name: .showPatchReviewDebug, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Show Worktree Review (debug)") {
                    NotificationCenter.default.post(name: .showWorktreeReviewDebug, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("Show Tasks List (debug)") {
                    NotificationCenter.default.post(name: .showTasksListDebug, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                #endif
            }
            CommandGroup(after: .help) {
                Button("About VibeCoder") {
                    NotificationCenter.default.post(name: .settingsRequested, object: "about")
                }
            }
        }
    }

    /// Directory picker, then silent `ProjectsService` register + `openedProject`.
    /// Sheet fallback if the folder cannot be bound.
    private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            let service = ProjectsService()
            switch await service.register(existingFolder: url) {
            case .success(let project):
                app.openedProject = project
            case .failure:
                NotificationCenter.default.post(name: .newProjectSheetRequested, object: url)
            }
        }
    }
}

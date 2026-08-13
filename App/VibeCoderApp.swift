//
//  VibeCoderApp.swift
//
//  App entry. Opens straight into the main UI — no onboarding.
//

import SwiftUI
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
            }
            CommandMenu("View") {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])

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
            }
        }
    }
}

//
//  NewTaskLandingViewV2.swift
//  AgentOS — NEW DAY
//
//  Landing page shown in the main pane when the user clicks "+ New Task"
//  in the sidebar. Doesn't create a task until the user explicitly clicks
//  the big "+" button — mirrors the Projects-page pattern.
//
//  Ported from DEV PLAN's NewTaskLandingView into the Claude Edition
//  theme system: Geist-removed (system font), cobalt accent, theme
//  tokens, Swift 6 @MainActor.
//
//  Tapping the "+" (or pressing Return) creates a real conversation via
//  `AppViewModel.newConversation()`; the detail pane then re-renders into
//  that conversation's ChatView (RootView.conversationDetail picks up the
//  newly-inserted first conversation).
//

import SwiftUI
import AgentCore

// MARK: - Root view

@MainActor
struct NewTaskLandingViewV2: View {

    @EnvironmentObject private var app: AppViewModel

    @State private var hovering: Bool = false

    // MARK: Body

    var body: some View {
        VStack(spacing: Theme.Spacing.ml) {
            Spacer()

            heroBlock
                .padding(.bottom, Theme.Spacing.s)

            createButton

            returnHint

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }

    // MARK: Hero block (icon + title + subtitle)

    private var heroBlock: some View {
        VStack(spacing: Theme.Spacing.s + 2) {
            // Outline app monogram (matches empty-chat watermark in ChatView).
            BrandMarkOutline(size: 88, opacity: 0.55)
                .padding(.bottom, Theme.Spacing.xs)

            Text("Start a new task")
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(Theme.Palette.primary)

            Text("Click the button below to begin. Your new task will appear in Recents.")
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Theme.Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    // MARK: Create button — big circular "+"

    private var createButton: some View {
        Button(action: createTask) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(hovering ? 0.20 : 0.13))
                    .frame(width: 84, height: 84)

                Circle()
                    .stroke(Theme.Palette.accent.opacity(hovering ? 0.55 : 0.35),
                            lineWidth: 1)
                    .frame(width: 84, height: 84)

                Image(systemName: "plus")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .scaleEffect(hovering ? 1.04 : 1.0)
            .animation(Theme.Motion.quick, value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .onHover { hovering = $0 }
        .help("Create a new task and open the chat (Return)")
    }

    // MARK: Return hint

    private var returnHint: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("Or press")
                .foregroundStyle(Theme.Palette.tertiary)
            kbdReturn
            Text("Return")
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .font(.system(size: 11, weight: .regular, design: .default))
        .padding(.top, 2)
    }

    private var kbdReturn: some View {
        Text("\u{21A9}") // ↩
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.Palette.secondary)
            .padding(.horizontal, Theme.Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button - 2,
                                 style: .continuous)
                    .fill(Theme.Palette.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button - 2,
                                 style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
    }

    // MARK: Actions

    /// Create a real conversation and let the detail pane navigate to it.
    private func createTask() {
        app.newConversation()
    }
}


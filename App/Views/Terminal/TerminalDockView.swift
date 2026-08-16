//
//  TerminalDockView.swift
//  Wave U3 — bottom dock chrome + self-contained host for DetailPane.
//

import AppKit
import SwiftUI
import AgentCore

/// Parent one-liner: `.safeAreaInset(edge: .bottom, spacing: 0) { TerminalDockHost() }`.
struct TerminalDockHost: View {
    @EnvironmentObject private var app: AppViewModel
    @AppStorage(TerminalDockStorage.visibilityKey) private var visible =
        TerminalDockStorage.visibilityDefault
    @StateObject private var session = TerminalSession()

    var body: some View {
        Group {
            if visible {
                TerminalDockView(cwd: cwd, session: session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTerminalRequested)) { _ in
            visible.toggle()
        }
        .onChange(of: visible) { _, shown in
            if shown {
                session.ensureStarted(cwd: cwd)
            }
        }
        .onChange(of: cwdIdentity) { _, _ in
            if visible || session.isAlive {
                session.adoptCWD(cwd)
            }
        }
    }

    private var cwd: URL {
        let conversation: Conversation?
        if let id = app.selectedConversationID {
            conversation = app.conversations.first(where: { $0.id == id })
        } else {
            conversation = nil
        }
        return TerminalCwd.resolve(
            worktreeRoot: conversation?.worktreeRootURL,
            projectRoot: conversation?.projectRoot
        )
    }

    private var cwdIdentity: String {
        TerminalCwd.identity(of: cwd)
    }
}

struct TerminalDockView: View {
    let cwd: URL
    @ObservedObject var session: TerminalSession
    @AppStorage(TerminalDockStorage.heightKey) private var height =
        TerminalDockStorage.defaultHeight
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragOrigin: Double?

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 1)
            TerminalTextView(
                attributed: session.display,
                onInput: { session.send($0) },
                onResize: { session.setPixelSize($0) }
            )
        }
        .frame(height: CGFloat(TerminalDockStorage.clampHeight(height)))
        .frame(maxWidth: .infinity)
        .background(Theme.Palette.subtle)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 1)
        }
        .onAppear {
            session.ensureStarted(cwd: cwd)
        }
        .onChange(of: colorScheme) { _, _ in
            session.refreshDisplay()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Terminal")
                .font(Theme.Typography.captionSemi)
                .foregroundStyle(Theme.Palette.primary)
            Text(cwd.lastPathComponent)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !session.isAlive {
                Text("exited")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            Spacer(minLength: Theme.Spacing.s)
            headerIconButton(
                systemName: "stop.circle",
                help: "Kill",
                enabled: session.isAlive
            ) {
                session.terminate()
            }
            .accessibilityLabel("Kill terminal")
            headerIconButton(
                systemName: "chevron.down",
                help: "Hide",
                enabled: true
            ) {
                NotificationCenter.default.post(name: .toggleTerminalRequested, object: nil)
            }
            .accessibilityLabel("Hide terminal")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 6)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(height: 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? height
                        if dragOrigin == nil { dragOrigin = height }
                        height = TerminalDockStorage.clampHeight(origin - value.translation.height)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityHidden(true)
    }

    private func headerIconButton(
        systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.tertiary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

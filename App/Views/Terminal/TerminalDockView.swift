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
            guard shown else { return }
            DispatchQueue.main.async {
                session.ensureStarted(cwd: cwd)
            }
        }
        .onChange(of: cwdIdentity) { _, _ in
            guard visible || session.isAlive else { return }
            DispatchQueue.main.async {
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
                .fill(TerminalMetrics.tabBarDivider)
                .frame(height: 1)
            TerminalTextView(
                attributed: session.display,
                fixedGrid: session.isAlternateScreen,
                applicationCursorKeys: session.applicationCursorKeys,
                onInput: { session.send($0) },
                onPaste: { session.paste($0) },
                onResize: { session.setPixelSize($0) }
            )
        }
        .frame(height: CGFloat(TerminalDockStorage.clampHeight(height)))
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: TerminalMetrics.canvasColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalMetrics.tabBarDivider)
                .frame(height: 1)
        }
        .onAppear {
            session.ensureStarted(cwd: cwd)
        }
        .onChange(of: colorScheme) { _, _ in
            DispatchQueue.main.async {
                session.refreshDisplay()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(cwd.lastPathComponent)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(TerminalMetrics.chromeInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !session.isAlive {
                    Text("exited")
                        .font(.system(size: 11))
                        .foregroundStyle(TerminalMetrics.chromeSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Spacer(minLength: 8)
            if session.isAlive {
                headerIconButton(
                    systemName: "stop.circle",
                    help: "Kill",
                    enabled: true
                ) {
                    session.terminate()
                }
                .accessibilityLabel("Kill terminal")
            } else {
                headerIconButton(
                    systemName: "arrow.clockwise",
                    help: "Restart",
                    enabled: true
                ) {
                    session.restart()
                }
                .accessibilityLabel("Restart terminal")
            }
            headerIconButton(
                systemName: "xmark",
                help: "Hide",
                enabled: true
            ) {
                NotificationCenter.default.post(name: .toggleTerminalRequested, object: nil)
            }
            .accessibilityLabel("Hide terminal")
        }
        .padding(.trailing, 8)
        .background(TerminalMetrics.tabBarColor)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    enabled
                        ? TerminalMetrics.chromeSecondary
                        : TerminalMetrics.chromeSecondary.opacity(0.35)
                )
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

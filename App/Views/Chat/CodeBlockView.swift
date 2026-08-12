// CodeBlockView.swift
// AgentOS — Claude Edition
//
// Fenced code block with a header bar (language label + copy button)
// and a horizontally-scrollable monospaced body. Copy button mirrors
// the CopyChip pattern from MessageBubbleViewV2.swift.
//

import SwiftUI
import AppKit

struct CodeBlockView: View {
    let language: String?
    let code: String
    /// Font size for the code body. Defaults to 13 (one point below the
    /// chat body default of 14 to give code a slightly denser feel).
    var fontSize: CGFloat = 13

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header bar ──────────────────────────────────────────
            HStack(spacing: 0) {
                if let lang = language, !lang.isEmpty {
                    Text(lang.uppercased())
                        .font(Theme.Typography.mono(size: 10, weight: .medium))
                        .foregroundColor(Theme.Palette.tertiary)
                }
                Spacer()
                // Copy button — matches the CopyChip pattern in
                // MessageBubbleViewV2.swift: NSPasteboard write + brief
                // "Copied" state driven by a Task sleep.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Theme.Motion.quick) { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        await MainActor.run {
                            withAnimation(Theme.Motion.quick) { copied = false }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(copied ? Theme.Palette.success : Theme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .animation(Theme.Motion.quick, value: copied)
            }
            .padding(.horizontal, Theme.Spacing.ml)
            .padding(.vertical, Theme.Spacing.s)
            .background(headerBackground)

            // Thin hairline divider between header and body.
            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 0.5)

            // ── Code body ───────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.Typography.mono(size: fontSize))
                    .foregroundColor(Theme.Palette.primary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.ml)
            }
            .background(bodyBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.codeBlock))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.codeBlock)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    // MARK: - Adaptive backgrounds

    /// Header strip — slightly lighter than body so language label and
    /// copy button stand off the code. Adapts to dark / light mode.
    private static let headerBgDark  = NSColor(white: 0.12, alpha: 1)
    private static let headerBgLight = NSColor(white: 0.93, alpha: 1)
    private static let bodyBgDark    = NSColor(white: 0.08, alpha: 1)
    private static let bodyBgLight   = NSColor(white: 0.97, alpha: 1)

    private static let headerBackground = Color(
        dynamicLight: headerBgLight,
        dynamicDark:  headerBgDark
    )
    private static let bodyBackground = Color(
        dynamicLight: bodyBgLight,
        dynamicDark:  bodyBgDark
    )

    private var headerBackground: Color { Self.headerBackground }
    private var bodyBackground:   Color { Self.bodyBackground }
}

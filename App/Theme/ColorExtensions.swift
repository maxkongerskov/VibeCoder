// ColorExtensions.swift
// AgentOS — Claude Edition
//
// Legacy Color.* shorthand from DEV PLAN's iteration-1 view code.
//
// These names (agentBackground, sidebarBackground, textPrimary, tokenBlue,
// etc.) were sprinkled throughout the iteration-1 views before Theme.Palette
// became the single source of truth. Rather than rewrite every call site,
// each token here is a thin computed-property DELEGATE to the matching
// Theme.Palette.* value — so:
//
//   • Theme stays the source of truth (one place to change a color).
//   • Old call sites keep compiling without edits.
//   • No duplicate dynamic NSColor providers floating around.
//
// `Color.divider` is intentionally omitted here because it would shadow
// SwiftUI's own `Color.divider` symbol used in framework views; reach for
// `Theme.Palette.divider` directly at call sites instead.

import SwiftUI
import AppKit

extension Color {

    // ── Backgrounds ─────────────────────────────────────────────────

    /// Main chat pane background. Delegates to `Theme.Palette.canvas`.
    static var agentBackground:   Color { Theme.Palette.canvas }

    /// Sidebar background. Delegates to `Theme.Palette.muted`.
    static var sidebarBackground: Color { Theme.Palette.muted }

    /// Input card background (sits ABOVE the chat surface).
    /// Delegates to `Theme.Palette.subtle`.
    static var inputBackground:   Color { Theme.Palette.subtle }

    /// Generic card surface (popovers, settings panes).
    /// Delegates to `Theme.Palette.surface`.
    static var cardBackground:    Color { Theme.Palette.surface }

    /// Hover/pressed tint. Delegates to `Theme.Palette.hover`.
    static var hoverBackground:   Color { Theme.Palette.hover }

    // ── Bubbles ─────────────────────────────────────────────────────

    /// User message bubble. Delegates to `Theme.Palette.bubbleUser`.
    static var bubbleUser:        Color { Theme.Palette.bubbleUser }

    // ── Text / foreground ──────────────────────────────────────────

    static var textPrimary:       Color { Theme.Palette.primary }
    static var textSecondary:     Color { Theme.Palette.secondary }
    static var textTertiary:      Color { Theme.Palette.tertiary }
    static var placeholder:       Color { Theme.Palette.mutedFg }

    // ── Semantic chromatic tokens ──────────────────────────────────

    static var tokenGreen:        Color { Theme.Palette.success }
    static var tokenRed:          Color { Theme.Palette.error }
    static var tokenAmber:        Color { Theme.Palette.warning }
    static var tokenBlue:         Color { Theme.Palette.info }
    static var tokenViolet:       Color { Theme.Palette.violet }

    // ── Send button accent ─────────────────────────────────────────

    /// Warm orange used by the send button. Delegates to
    /// `Theme.Palette.sendAccent`.
    static var sendAccent:        Color { Theme.Palette.sendAccent }
}

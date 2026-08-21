//
//  Theme.swift
//  AgentOS — NEW DAY
//
//  Single source of truth for visual tokens.
//  Dark palette sampled from ZCode (sidebar lift, soft gray text,
//  orange Full-access accent). Light mode stays a calm warm paper.
//

import SwiftUI
import AppKit

enum Theme {

    // MARK: - Color tokens
    //
    // Dark hierarchy:
    //   canvas #161616  <  surface #222222  <  input/sidebar #2B2B2B (subtle)
    // Sidebar matches the composer input card (same `subtle` token).
    // Text is soft gray (#D2), not pure white — easier on the eyes.

    enum Palette {

        // ── Surfaces ────────────────────────────────────────────────

        /// Main chat / code pane background.
        /// Dark: #161616 · Light: #F7F7F5
        static let canvas = Color(dynamicLight: NSColor(white: 0.97, alpha: 1),
                                  dynamicDark:  NSColor(white: 0x16 / 255.0, alpha: 1))

        /// Generic card / panel / elevated chrome.
        /// Dark: #222222 · Light: system control.
        static let surface = Color(dynamicLight: NSColor.controlBackgroundColor,
                                   dynamicDark:  NSColor(white: 0x22 / 255.0, alpha: 1))

        /// Input composer card + sidebar — same plane so chrome feels unified.
        /// Dark: #2B2B2B · Light: #F0EFEC
        static let subtle = Color(dynamicLight: NSColor(white: 0.94, alpha: 1),
                                  dynamicDark:  NSColor(white: 0x2B / 255.0, alpha: 1))

        /// Elevated secondary chrome (legacy token; prefer `subtle` for sidebar/input).
        /// Dark: #353535 · Light: #F0EFEC
        static let muted = Color(dynamicLight: NSColor(white: 0.94, alpha: 1),
                                 dynamicDark:  NSColor(white: 0x35 / 255.0, alpha: 1))

        /// Hover/pressed state tint.
        static let hover = Color(dynamicLight: NSColor(white: 0, alpha: 0.05),
                                 dynamicDark:  NSColor(white: 1, alpha: 0.06))

        /// User message bubble — soft neutral pill.
        static let bubbleUser = Color(dynamicLight: NSColor(white: 0, alpha: 0.06),
                                      dynamicDark:  NSColor(white: 1, alpha: 0.06))

        // ── Foreground (text + icons) ──────────────────────────────
        // Fixed soft grays in dark mode (not pure label white).

        /// Body / title text. Dark: #D2D2D2
        static let primary = Color(dynamicLight: NSColor(white: 0.12, alpha: 1),
                                   dynamicDark:  NSColor(white: 0xD2 / 255.0, alpha: 1))

        /// Secondary labels. Dark: ~#9A9A9A
        static let secondary = Color(dynamicLight: NSColor(white: 0.35, alpha: 1),
                                     dynamicDark:  NSColor(white: 0x9A / 255.0, alpha: 1))

        /// Tertiary / timestamps. Dark: #797979
        static let tertiary = Color(dynamicLight: NSColor(white: 0.50, alpha: 1),
                                    dynamicDark:  NSColor(white: 0x79 / 255.0, alpha: 1))

        /// Placeholder text.
        static let mutedFg = Color(dynamicLight: NSColor(white: 0.55, alpha: 1),
                                   dynamicDark:  NSColor(white: 0x6E / 255.0, alpha: 1))

        // ── Divider ─────────────────────────────────────────────────

        static let divider = Color(dynamicLight: NSColor(white: 0.0, alpha: 0.08),
                                   dynamicDark:  NSColor(white: 1.0, alpha: 0.08))

        // ── Accent (ZCode orange ≈ #E48B46) ────────────────────────

        static let accent = Color(
            dynamicLight: NSColor(red: 0.89, green: 0.48, blue: 0.22, alpha: 1),
            dynamicDark:  NSColor(red: 0.894, green: 0.545, blue: 0.275, alpha: 1) // #E48B46
        )
        static let accentHover = Color(
            dynamicLight: NSColor(red: 0.82, green: 0.42, blue: 0.18, alpha: 1),
            dynamicDark:  NSColor(red: 0.96, green: 0.58, blue: 0.28, alpha: 1) // ~#F59447 peak
        )
        static let accentSubtle = Color(
            dynamicLight: NSColor(red: 0.89, green: 0.48, blue: 0.22, alpha: 0.12),
            dynamicDark:  NSColor(red: 0.894, green: 0.545, blue: 0.275, alpha: 0.14)
        )

        // ── Semantic chromatic tokens ───────────────────────────────

        static let success = Color(red: 0.42, green: 0.68, blue: 0.49) // calmer green
        static let warning = Color(red: 0.82, green: 0.70, blue: 0.42)
        static let error   = Color(red: 0.79, green: 0.48, blue: 0.48)
        static let info    = Color(red: 0.48, green: 0.62, blue: 0.75)

        // ── Diff (Code mode — match docs/code-ux mockup) ────────────
        // Mock: --green #6bcb8d · --red #e07a7a · dim fills ~12% alpha

        /// Added lines / "+" gutter (mockup green).
        static let diffAdd = Color(red: 0.420, green: 0.796, blue: 0.553) // #6BCB8D
        /// Removed lines / "−" gutter (mockup red).
        static let diffRemove = Color(red: 0.878, green: 0.478, blue: 0.478) // #E07A7A
        /// Soft row fill behind additions.
        static let diffAddBg = Color(red: 0.420, green: 0.796, blue: 0.553).opacity(0.14)
        /// Soft row fill behind deletions.
        static let diffRemoveBg = Color(red: 0.878, green: 0.478, blue: 0.478).opacity(0.14)
        /// Added line body text (slightly softer than gutter).
        static let diffAddText = Color(red: 0.722, green: 0.902, blue: 0.784) // #B8E6C8
        /// Removed line body text.
        static let diffRemoveText = Color(red: 0.910, green: 0.690, blue: 0.690) // #E8B0B0

        /// Capability chips (tool/reason/vision badges).
        static let violet  = Color(red: 0.65, green: 0.55, blue: 0.82)

        // ── Send button accent ─────────────────────────────────────

        /// Matches ZCode Full-access / send orange.
        static let sendAccent = Color(
            dynamicLight: NSColor(red: 0.89, green: 0.48, blue: 0.22, alpha: 1),
            dynamicDark:  NSColor(red: 0.894, green: 0.545, blue: 0.275, alpha: 1)
        )

        // ── Reasoning + activity ────────────────────────────────────

        static let thinkingBorder      = accent.opacity(0.55)
        static let thinkingBorderLive  = accent.opacity(0.85)

        static let activityVerb   = accent
        static let activityStatus = secondary
        static let activityDivider = tertiary

        /// Subagent type label in transcript (Z Code–style blue, not orange).
        static let subagentType = Color(
            dynamicLight: NSColor(red: 0.20, green: 0.48, blue: 0.85, alpha: 1),
            dynamicDark:  NSColor(red: 0.45, green: 0.68, blue: 0.95, alpha: 1) // ~#73ADF2
        )
    }

    // MARK: - Spacing (UI_DESIGN.md §2.2 — 8-pt base)

    enum Spacing {
        static let xxs:  CGFloat = 2
        static let xs:   CGFloat = 4
        static let s:    CGFloat = 8
        static let m:    CGFloat = 12
        static let ml:   CGFloat = 16
        static let l:    CGFloat = 24
        static let xl:   CGFloat = 32
        static let xxl:  CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    // MARK: - Chat column (BuildCode-aligned measure)
    //
    // Transcript + input card share one EXACT width driven by pane size:
    //   column = clamp(pane − 2×adaptiveGutter, min…max)
    // Inspired by Claude.ai: the chat + composer grow with the window instead
    // of sitting at a fixed 720pt island with huge empty side bands. Gutters
    // scale with pane width but are capped so ultra-wide screens still look
    // intentional; prose max stays readable (~1040pt).
    //
    // Call sites must use `.frame(width:)` (not only maxWidth) — ScrollView
    // content and composer ideal-size otherwise stay narrow and never grow.

    enum ChatLayout {
        /// Soft max for transcript + input card on wide panes (was 720 —
        /// felt stuck-in-the-middle on large windows).
        static let maxContentWidth: CGFloat = 1040
        /// Floor so the column stays usable in a very narrow split.
        static let minContentWidth: CGFloat = 320
        /// Minimum outer gutter on each side (narrow panes).
        static let sideGutter: CGFloat = 24
        /// Cap side gutters so wide windows reinvest space into the column
        /// (Claude-like) instead of endless empty margin.
        static let maxSideGutter: CGFloat = 96
        /// Body text in transcript + composer (parity).
        static let bodyFontSize: CGFloat = 15

        // ── Input card (BuildCode ChatTheme dimensions) ──────────────
        /// Composer card corner radius.
        static let inputCornerRadius: CGFloat = 18
        /// Horizontal inset of text / toolbar inside the input card.
        static let inputHorizontalInset: CGFloat = 14
        /// Vertical padding inside the input card.
        static let inputVerticalPad: CGFloat = 14
        /// Lift of the composer from the window bottom.
        static let inputBottomLift: CGFloat = 18
        /// Resting outer height of the card (padding + one-line field + toolbar).
        /// BuildCode: inputCardMinHeight (56) + 20 chrome = 76.
        static let inputCardMinHeight: CGFloat = 76
        /// Single-line text field floor inside the card.
        static let inputEditorMinHeight: CGFloat = 36
        /// Cap multi-line growth so the card stays BuildCode-thick, not a panel.
        static let inputEditorMaxHeight: CGFloat = 100
        /// Soft max lines before the field stops growing (≈ editor max height).
        static let inputEditorMaxLines: Int = 6

        /// Vertical gap between consecutive transcript blocks (Chat + Code).
        /// Shared so both modes feel the same rhythm.
        static let messageGap: CGFloat = 12
        /// Air under a finished user turn (pill ± copy) before the next block.
        /// Applied on the user row itself — Chat and Code both use this.
        /// Generous enough that wrapped long prompts never feel flush
        /// against the following assistant prose.
        static let afterUserTurn: CGFloat = 20
        /// Small top inset on assistant prose so it never collides with the
        /// user pill above (Chat + Code).
        static let beforeAssistant: CGFloat = 8
        /// Hard gap between message body and its Copy chip (Chat).
        static let bodyToCopyGap: CGFloat = 16
        /// @available legacy aliases (older call sites).
        static let afterUserGap: CGFloat = afterUserTurn
        static let copyChipGap: CGFloat = bodyToCopyGap

        /// Adaptive side gutter: grows gently with the pane, then caps so
        /// resizing a large window fills the column instead of the margins.
        ///
        /// Invariants (see `ChatLayoutContentWidthTests`):
        /// - result ∈ [sideGutter, maxSideGutter] for pane ≥ 0
        /// - proportional knee: 0.06×pane hits min at pane=400, max at pane=1600
        static func sideGutter(forPaneWidth paneWidth: CGFloat) -> CGFloat {
            // ~6% of pane per side, within [sideGutter, maxSideGutter].
            let proportional = max(0, paneWidth) * 0.06
            return min(maxSideGutter, max(sideGutter, proportional))
        }

        /// Shared column width for transcript + input given the chat pane width
        /// (detail width minus artifact rail / code tree when present).
        /// Grows with the window (Claude-style); soft-capped for readability.
        ///
        /// Formula: `column = min(maxContentWidth, pane − 2×sideGutter(pane))`,
        /// floored at 0. Below `minContentWidth` we still return available
        /// (usable narrow split) rather than forcing a wider-than-pane frame.
        ///
        /// Worked examples (pane → column):
        /// - 280 → 232  (narrow: gutters 24+24, use all available)
        /// - 800 → 704  (mid: gutters 48+48, grows with pane)
        /// - 1200 → 1040 (hits soft max; visual sides ≈ 80pt each)
        /// - 2000 → 1040 (soft max; visual sides larger — intentional readability cap)
        ///
        /// Call sites must pass the same value to transcript + composer
        /// (`.chatFluidColumn` / `maxCardWidth`) with `sideGutter: 0` so
        /// centering provides the outer air — do not double-apply gutters.
        static func contentWidth(paneWidth: CGFloat) -> CGFloat {
            let pane = max(0, paneWidth)
            guard pane > 0 else { return 0 }
            // Cannot fit two minimum gutters — use the full pane (no negative width).
            if pane <= sideGutter * 2 { return pane }
            let gutter = sideGutter(forPaneWidth: pane)
            let available = pane - 2 * gutter
            // Prefer filling available width up to the soft max; never wider than pane.
            return min(maxContentWidth, max(0, available))
        }
    }

    // MARK: - Corner radii (UI_DESIGN.md §2.4)

    enum Radius {
        static let button: CGFloat = 6
        static let card: CGFloat = 8
        static let codeBlock: CGFloat = 6
        static let chip: CGFloat = 999    // pill
        static let sheet: CGFloat = 12
        static let bubble: CGFloat = 12
        static let modal: CGFloat = 12
        /// Composer / floating input card (ZCode).
        static let inputCard: CGFloat = ChatLayout.inputCornerRadius
    }

    // MARK: - Typography
    //
    // One product voice (ZCode / Claude-adjacent):
    //   • SF Pro  — all UI + chat/code prose + markdown headings
    //   • SF Mono — code, diffs, paths, tool data only
    // Never use .serif in the app chrome or transcript (no New York flips).
    // Hierarchy is size + weight, not a second typeface family.

    enum Typography {
        // ── Scale (pt) ──────────────────────────────────────────────
        static let sizeCaption: CGFloat = 12
        static let sizeUI: CGFloat = 13
        static let sizeBody: CGFloat = ChatLayout.bodyFontSize // 15
        static let sizeTitle: CGFloat = 20
        static let sizeDisplay: CGFloat = 32
        static let sizeMono: CGFloat = 13
        static let sizeMonoSmall: CGFloat = 12

        // ── SF Pro ──────────────────────────────────────────────────
        static let display      = Font.system(size: sizeDisplay, weight: .semibold, design: .default)
        static let title        = Font.system(size: sizeTitle, weight: .semibold, design: .default)
        static let body         = Font.system(size: sizeBody, weight: .regular,  design: .default)
        static let bodyEmphasis = Font.system(size: sizeBody, weight: .semibold, design: .default)
        static let bodyMedium   = Font.system(size: sizeBody, weight: .medium,   design: .default)
        /// Sidebar rows, chips, dense chrome.
        static let ui           = Font.system(size: sizeUI, weight: .regular, design: .default)
        static let uiMedium     = Font.system(size: sizeUI, weight: .medium,  design: .default)
        static let uiSemibold   = Font.system(size: sizeUI, weight: .semibold, design: .default)
        static let caption      = Font.system(size: sizeCaption, weight: .regular, design: .default)
        static let captionEmph  = Font.system(size: sizeCaption, weight: .medium,  design: .default)
        static let captionSemi  = Font.system(size: sizeCaption, weight: .semibold, design: .default)

        // ── SF Mono (code-like only) ────────────────────────────────
        static let monoBody     = Font.system(size: sizeMono, weight: .regular, design: .monospaced)
        static let monoSmall    = Font.system(size: sizeMonoSmall, weight: .regular, design: .monospaced)
        static let monoMedium   = Font.system(size: sizeMonoSmall, weight: .medium, design: .monospaced)

        /// Marketing/welcome screen extra-large title.
        static let heroDisplay  = Font.system(size: 48, weight: .semibold, design: .default)

        /// Markdown heading sizes stay in SF Pro — modest steps, same family as body.
        static func markdownHeading(level: Int, base: CGFloat = sizeBody) -> Font {
            let size: CGFloat
            let weight: Font.Weight
            switch level {
            case 1: size = base + 4; weight = .semibold
            case 2: size = base + 2; weight = .semibold
            case 3: size = base + 1; weight = .semibold
            case 4: size = base;     weight = .semibold
            case 5: size = base;     weight = .medium
            default: size = base;    weight = .medium
            }
            return .system(size: size, weight: weight, design: .default)
        }

        static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // MARK: - Motion (UI_DESIGN.md §2.5)

    enum Motion {
        /// Instant when the user asked for reduced motion; otherwise `base`.
        private static func motion(_ base: Animation) -> Animation {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .linear(duration: 0)
                : base
        }

        /// 150 ms easeOut — hover, focus, button press.
        static var quick: Animation { motion(.easeOut(duration: 0.15)) }
        /// 250 ms easeOut — sheets, sidebar selection, tab switch.
        static var standard: Animation { motion(.easeOut(duration: 0.25)) }
        /// 300 ms easeInOut — disclosure, patch hunk reveal.
        static var gentle: Animation { motion(.easeInOut(duration: 0.30)) }
        /// Spring — chip pulse, build pass.
        static var pulse: Animation {
            motion(.spring(response: 0.4, dampingFraction: 0.65, blendDuration: 0))
        }
        /// Per-token stream — 80 ms easeOut.
        static var stream: Animation { motion(.easeOut(duration: 0.08)) }
    }
}

// MARK: - Fluid chat column helper

extension View {
    /// Pin this view to the shared chat column width and center it in the pane.
    /// Uses a hard `width` so ScrollView / composer content actually grow/shrink
    /// with window resize (maxWidth alone only caps and often stays at ideal size).
    func chatFluidColumn(width: CGFloat, alignment: Alignment = .leading) -> some View {
        self
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Color helpers

extension Color {

    /// Compatibility shim for iteration-1 hex literals.
    init(light: Int, dark: Int) {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight]) == .darkAqua
                       || appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight]) == .vibrantDark
            let hex = isDark ? dark : light
            return NSColor(
                red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >>  8) & 0xFF) / 255.0,
                blue:  CGFloat( hex        & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        self.init(nsColor: nsColor)
    }

    /// Initialize a dynamic Color from two NSColors (one for light, one
    /// for dark appearance). This is what DEV PLAN uses for its three-
    /// tone surfaces.
    init(dynamicLight light: NSColor, dynamicDark dark: NSColor) {
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? dark : light
        }
        self.init(nsColor: ns)
    }
}

// MARK: - Geist font support (dormant — product type is SF Pro + SF Mono)

extension Font {

    nonisolated(unsafe) static var geistAvailable: Bool = false

    /// Call once from `VibeCoderApp.init()` before any views render.
    /// Currently a no-op — DEV PLAN reverted from Geist to SF Pro on
    /// 2026-06-01 ("the system font feels better"). The `.geist(...)`
    /// factory below already falls back to `.system(...)`, so this
    /// non-registration is invisible to call sites.
    /// To enable Geist later: bundle the 3 TTFs, populate this body.
    static func registerGeist() {
        geistAvailable = false
    }

    /// Geist factory with SF Pro fallback. Use anywhere typography
    /// matters but you don't want to commit to a specific font yet.
    static func geist(_ size: CGFloat, weight: GeistWeight = .regular) -> Font {
        guard geistAvailable else {
            return .system(size: size, weight: weight.swiftUIWeight)
        }
        return .custom(weight.postScriptName, size: size)
    }

    // Semantic shortcuts
    static var geistBody:     Font { .geist(13) }
    static var geistCaption:  Font { .geist(11) }
    static var geistSmall:    Font { .geist(10) }
    static var geistLabel:    Font { .geist(12, weight: .medium) }
    static var geistHeadline: Font { .geist(14, weight: .semibold) }
    static var geistTitle:    Font { .geist(16, weight: .semibold) }
}

enum GeistWeight {
    case regular, medium, semibold

    var postScriptName: String {
        switch self {
        case .regular:  return "Geist-Regular"
        case .medium:   return "Geist-Medium"
        case .semibold: return "Geist-SemiBold"
        }
    }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        }
    }
}

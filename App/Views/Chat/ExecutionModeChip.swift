//
//  ExecutionModeChip.swift
//
//  z.code's 4-mode permission picker. Opens upward with the shared
//  input-card popup chrome (same schema as the context meter card).
//

import SwiftUI
import AgentCore

/// Compact chip + upward popup for z.code's 4 execution modes.
///
/// Visual language matches the rest of the input toolbar and sidebar
/// “New Task” accent: quiet secondary text by default, brand orange only
/// when the menu is open — never red/green mode-specific fills or a
/// permanent colored capsule.
struct ExecutionModeChip: View {

    @Binding var mode: ExecutionMode
    var isRunning: Bool = false

    @State private var showMenu = false
    @State private var hoverRow: ExecutionMode? = nil

    var body: some View {
        Button {
            guard !isRunning else { return }
            withAnimation(.easeOut(duration: 0.12)) { showMenu.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 11, weight: .medium))
                Text(mode.shortLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            // Brand orange when open (same token as sidebar New Task);
            // otherwise quiet secondary — no permanent colored “window”.
            .foregroundStyle(showMenu ? Theme.Palette.accent : Theme.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    showMenu
                        ? Theme.Palette.accent.opacity(0.12)
                        : Color.clear
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .help("\(mode.fullLabel): \(mode.description) — ⇧Tab to cycle")
        .animation(.easeInOut(duration: 0.15), value: mode)
        .animation(.easeOut(duration: 0.12), value: showMenu)
        .inputCardUpwardPopup(isPresented: $showMenu, alignment: .leading) {
            InputCardPopupChrome(
                width: InputCardPopupStyle.menuWidth,
                includePadding: false
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent mode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    ForEach(ExecutionMode.allCases) { candidate in
                        InputCardPopupRow(
                            title: candidate.fullLabel,
                            subtitle: candidate.description,
                            systemImage: candidate.iconName,
                            isSelected: candidate == mode,
                            isHovered: hoverRow == candidate
                        ) {
                            mode = candidate
                            showMenu = false
                        }
                        .onHover { hovering in
                            hoverRow = hovering ? candidate : (hoverRow == candidate ? nil : hoverRow)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: isRunning) { _, running in
            if running { showMenu = false }
        }
    }
}

#if DEBUG
struct ExecutionModePreviewHarness: View {
    @State private var mode: ExecutionMode = .yolo

    var body: some View {
        VStack(spacing: 16) {
            ExecutionModeChip(mode: $mode)
            Text("Current: \(mode.fullLabel)")
                .font(.caption)
                .foregroundColor(Theme.Palette.tertiary)
        }
        .padding(24)
        .frame(width: 360, height: 280, alignment: .bottom)
        .background(Theme.Palette.canvas)
    }
}

#Preview("Execution Mode") {
    ExecutionModePreviewHarness()
}
#endif

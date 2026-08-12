//
//  ThinkingEffortPicker.swift
//
//  Reasoning-effort chip. Opens upward with shared input-card popup chrome.
//

import SwiftUI
import AgentCore

/// Dropdown chip for choosing reasoning effort on models that support it.
struct ThinkingEffortPicker: View {

    let capability: ThinkingCapability?
    @Binding var effort: ThinkingEffort
    var isRunning: Bool = false

    @State private var showMenu = false
    @State private var hoverRow: ThinkingEffort? = nil

    private var displayEffort: ThinkingEffort {
        guard let cap = capability else { return effort }
        return cap.clamp(effort)
    }

    var body: some View {
        if let cap = capability {
            chip(capability: cap)
        }
    }

    private func chip(capability cap: ThinkingCapability) -> some View {
        let active = displayEffort != .off
        let levelsKey = cap.levels.map(\.rawValue).joined(separator: ",")

        return Button {
            guard !isRunning else { return }
            withAnimation(.easeOut(duration: 0.12)) { showMenu.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                Text(displayEffort.title)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            // Same language as mode chip: quiet secondary, brand orange only
            // while the menu is open — no permanent grey “window”.
            .foregroundStyle(
                showMenu
                    ? Theme.Palette.accent
                    : (active ? Theme.Palette.secondary : Theme.Palette.tertiary)
            )
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
        .id("think-\(levelsKey)")
        .help(thinkHelp(cap: cap))
        .onAppear { effort = cap.clamp(effort) }
        .onChange(of: levelsKey) { _, _ in
            effort = cap.clamp(effort)
        }
        .onChange(of: isRunning) { _, running in
            if running { showMenu = false }
        }
        .inputCardUpwardPopup(isPresented: $showMenu, alignment: .trailing) {
            InputCardPopupChrome(
                width: InputCardPopupStyle.menuWidth,
                includePadding: false
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    ForEach(cap.levels) { level in
                        InputCardPopupRow(
                            title: level.title,
                            isSelected: level == displayEffort,
                            isHovered: hoverRow == level
                        ) {
                            effort = level
                            showMenu = false
                        }
                        .onHover { hovering in
                            hoverRow = hovering ? level : (hoverRow == level ? nil : hoverRow)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    private func thinkHelp(cap: ThinkingCapability) -> String {
        let levels = cap.levels.map(\.title).joined(separator: " · ")
        return "\(cap.label) for this model — levels from scan: \(levels). Only these options are sent to the backend."
    }
}

#if DEBUG
struct ThinkingPickerPreviewHarness: View {
    @State private var effort: ThinkingEffort = .high
    var body: some View {
        VStack(spacing: 20) {
            ThinkingEffortPicker(
                capability: ThinkingModelScanner.detect(modelId: "glm-5.2-mxfp4"),
                effort: $effort)
        }
        .padding(24)
        .frame(width: 460, height: 320, alignment: .bottom)
        .background(Theme.Palette.canvas)
    }
}

#Preview("Thinking Picker") {
    ThinkingPickerPreviewHarness()
}
#endif

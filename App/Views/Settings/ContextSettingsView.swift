//
//  ContextSettingsView.swift
//
//  Settings tab: context window cap + auto-compact threshold.
//  Moved out of Appearance so compaction has a dedicated home.
//

import SwiftUI
import AgentCore

struct ContextSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(title: "Context window", icon: "rectangle.compress.vertical") {
                VStack(alignment: .leading, spacing: 12) {
                    row(label: "Max context (tokens)") {
                        HStack(spacing: 8) {
                            TextField(
                                "Auto",
                                value: Binding(
                                    get: {
                                        settings.maxContextWindowTokens == 0
                                            ? nil
                                            : settings.maxContextWindowTokens
                                    },
                                    set: { newVal in
                                        settings.maxContextWindowTokens = max(0, newVal ?? 0)
                                    }
                                ),
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            Text(settings.maxContextWindowTokens == 0
                                 ? "Auto (model default)"
                                 : "tokens")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.tertiary)
                        }
                    }
                    Text("0 = use the model’s full advertised window. Set a lower cap to save memory or leave headroom.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section(title: "Auto-compact", icon: "arrow.down.right.and.arrow.up.left") {
                VStack(alignment: .leading, spacing: 12) {
                    row(label: "Compact at") {
                        HStack(spacing: 10) {
                            Slider(
                                value: $settings.autoCompactThresholdPercent,
                                in: 10...100,
                                step: 1
                            )
                            .frame(maxWidth: 220)
                            Text("\(Int(settings.autoCompactThresholdPercent))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Text("When estimated context exceeds this share of the window, the agent budget is set and older tool outputs may be summarized/elided so long runs keep going. **Auto-compact is wire-only** — the chat transcript in the UI stays full. **Manual `/compact` rewrites** the saved transcript (use `/undo` to restore the previous snapshot).")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Live readout of current threshold vs a sample window.
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                        Text(exampleBudgetLine)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var exampleBudgetLine: String {
        let pct = settings.autoCompactThresholdPercent
        let window = settings.maxContextWindowTokens > 0
            ? settings.maxContextWindowTokens
            : 32_768
        let budget = Int((Double(window) * min(100, max(10, pct)) / 100.0).rounded())
        let wLabel = settings.maxContextWindowTokens == 0 ? "a 32.8k window" : "\(window) tokens"
        return "Example: at \(Int(pct))% of \(wLabel), the wire budget is ~\(budget) tokens (FullReplace fires at that budget; elision always applies if still over)."
    }

    // MARK: - Layout helpers (match Appearance / Connection cards)

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.primary)
            }
            content()
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Palette.divider, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func row<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.secondary)
                .frame(width: 116, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

#if DEBUG
struct ContextSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ContextSettingsView(settings: .constant(.default))
            .padding()
            .frame(width: 560)
    }
}
#endif

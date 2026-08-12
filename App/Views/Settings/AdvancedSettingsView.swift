//
//  AdvancedSettingsView.swift
//
//  Power-user / debug toggles. First feature: clean model chrome (presentation filter).
//

import SwiftUI
import AgentCore

struct AdvancedSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            settingsCard {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundColor(Theme.Palette.accent)
                    Text("Advanced")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("Power-user options. Defaults are safe for everyday chat.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.35)

                Toggle(isOn: $settings.cleanModelChrome) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clean model chrome")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.primary)
                        Text("Hide control tokens and thinking-channel markup from answers (e.g. <|channel|>thought). Clean models are unchanged. Turn off to see raw model output.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if !settings.cleanModelChrome {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.warning)
                        Text("Raw mode: special tokens and channel markers may appear in chat and the task list.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

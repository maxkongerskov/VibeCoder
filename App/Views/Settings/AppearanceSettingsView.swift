// AppearanceSettingsView.swift
// AgentOS — Claude Edition
//
// "General" tab inside SettingsViewV2. Binds directly to AppSettings
// (no more local @State mocks) so toggling Color Scheme or Font Size
// actually persists and propagates:
//   • colorScheme → applied at RootView via .preferredColorScheme
//   • chatFontScale → multiplier on chat body fontSize across
//     MessageBubbleViewV2, PendingAssistantBubble, MarkdownTextView
//

import SwiftUI
import AgentCore

// MARK: - Local enums (UI labels for the persisted strings/doubles)

enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}

enum FontSizeChoice: String, CaseIterable, Identifiable {
    case small, regular, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small:   return "Small"
        case .regular: return "Default"
        case .large:   return "Large"
        }
    }

    var scale: Double {
        switch self {
        case .small:   return 0.85
        case .regular: return 1.0
        case .large:   return 1.20
        }
    }

    /// Closest match to a persisted scale value — used to highlight the
    /// active segment when settings load.
    static func from(scale: Double) -> FontSizeChoice {
        let pairs: [(FontSizeChoice, Double)] = allCases.map { ($0, $0.scale) }
        return pairs.min(by: { abs($0.1 - scale) < abs($1.1 - scale) })?.0 ?? .regular
    }
}

// MARK: - View

struct GeneralSettingsView: View {
    @Binding var settings: AppSettings

    private var colorSchemeBinding: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: settings.colorScheme) ?? .system },
            set: { settings.colorScheme = $0.rawValue }
        )
    }

    private var fontSizeBinding: Binding<FontSizeChoice> {
        Binding(
            get: { FontSizeChoice.from(scale: settings.chatFontScale) },
            set: { settings.chatFontScale = $0.scale }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Context / auto-compact moved to Settings → Context tab.

            section(title: "Appearance", icon: "paintbrush.fill") {
                row(label: "Color Scheme") {
                    Picker("", selection: colorSchemeBinding) {
                        ForEach(ColorSchemePreference.allCases) { pref in
                            Label(pref.label, systemImage: pref.icon).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                row(label: "Font Size") {
                    Picker("", selection: fontSizeBinding) {
                        ForEach(FontSizeChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                row(label: "Notifications") {
                    Toggle("", isOn: $settings.notificationsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Master switch for turn-complete and halt notifications. Still requires macOS permission.")
                }

                Text("When on, VibeCoder may post macOS notifications when a turn finishes while the app is in the background (and for headless/scheduled runs). Off silences all app user notifications.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 130)

                // Tiny live preview so the user sees what Small/Default/Large
                // changes — same family + weight as the actual chat body.
                HStack {
                    Spacer().frame(width: 130)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: CGFloat(16 * settings.chatFontScale),
                                      weight: .light,
                                      design: .rounded))
                        .foregroundColor(Theme.Palette.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Layout helpers

    /// Matches the `sectionCard` styling used across ConnectionSettingsView
    /// — same `Theme.Palette.subtle` fill, same `Theme.Palette.divider`
    /// stroke, same corner radius, full-width frame. Keeps every pane in
    /// the Settings sheet reading as one consistent card system rather
    /// than three different colors and stroke weights.
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

// MARK: - Preview

#if DEBUG
struct GeneralSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        GeneralSettingsView(settings: .constant(.default))
            .padding()
            .frame(width: 560)
    }
}
#endif

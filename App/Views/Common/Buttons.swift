//
//  Buttons.swift
//
//  Theme-styled button variants. Mirrors UI_DESIGN.md §3.9.
//

import SwiftUI

/// Type-erased ButtonStyle wrapper so call sites can pick between two
/// concrete styles at runtime (e.g. `.buttonStyle(cond ? AnyButtonStyle(A())
/// : AnyButtonStyle(B()))`).
struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        _makeBody = { config in AnyView(style.makeBody(configuration: config)) }
    }
    func makeBody(configuration: Configuration) -> some View { _makeBody(configuration) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyEmphasis)
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 36)
            .padding(.horizontal, Theme.Spacing.ml)
            .background(
                configuration.isPressed
                    ? Theme.Palette.accentHover
                    : Theme.Palette.accent
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyEmphasis)
            .foregroundStyle(Theme.Palette.primary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 36)
            .padding(.horizontal, Theme.Spacing.ml)
            .background(
                configuration.isPressed
                    ? Theme.Palette.muted
                    : Theme.Palette.subtle
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

struct PlainTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.body)
            .foregroundStyle(
                configuration.isPressed
                    ? Theme.Palette.accentHover
                    : Theme.Palette.accent
            )
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyEmphasis)
            .foregroundStyle(Theme.Palette.error)
            .frame(height: 36)
            .padding(.horizontal, Theme.Spacing.ml)
            .background(
                configuration.isPressed
                    ? Theme.Palette.error.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

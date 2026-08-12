//
//  BrandMarkOutline.swift
//
//  Outline VB monogram used as the empty-chat / new-task hero mark
//  (ZCode-style watermark that disappears once the transcript has content).
//

import SwiftUI

/// Outline app mark. Uses the `AppMarkOutline` template asset so callers
/// can tint via `foregroundStyle`.
struct BrandMarkOutline: View {
    var size: CGFloat = 96
    var opacity: Double = 0.28

    var body: some View {
        Image("AppMarkOutline")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.Palette.accent.opacity(opacity))
            .accessibilityHidden(true)
    }
}

/// Centered empty-chat hero: outline mark + optional caption.
/// Shown only while the conversation has no visible transcript yet.
struct EmptyChatBrandHero: View {
    var title: String? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            BrandMarkOutline(size: 112, opacity: 0.32)

            if let title {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.Palette.primary)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Theme.Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

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
    var detected: [LoopbackDetectHit] = []
    var onUseDetected: ((LoopbackDetectTarget) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

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

            let ready = detected.filter { $0.verdict == .modelsReady }
            let busy = detected.filter { $0.verdict == .busyNotCompat }
            if !ready.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected on this Mac")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.tertiary)
                    ForEach(ready) { hit in
                        Button {
                            onUseDetected?(hit.target)
                        } label: {
                            HStack {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.green)
                                Text(hit.target.label)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(":\(hit.target.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.tertiary)
                                Text("Use")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.Palette.subtle, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 360)
            }
            if !busy.isEmpty {
                Text(busy.map { "\($0.target.label) :\($0.target.port) is in use, not a model server" }
                    .joined(separator: "\n"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if ready.isEmpty, onOpenSettings != nil {
                Button("Open Connection settings") {
                    onOpenSettings?()
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

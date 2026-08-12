//
//  ShimmerText.swift
//
//  Soft highlight that drifts slowly left → right across a label.
//  Ported from BuildCode’s thinking / working status chrome.
//

import SwiftUI

/// Soft light sweep across secondary status text (Thinking, Working, idle phrases).
struct ShimmerText: View {
    let text: String
    var font: Font = Theme.Typography.uiMedium
    /// Full sweep duration — slow and calm.
    var period: Double = 3.2
    /// Base (dim) opacity for non-highlight parts.
    var baseOpacity: Double = 0.55
    /// Peak highlight opacity.
    var peakOpacity: Double = 0.92

    init(
        _ text: String,
        font: Font = Theme.Typography.uiMedium,
        period: Double = 3.2,
        baseOpacity: Double = 0.55,
        peakOpacity: Double = 0.92
    ) {
        self.text = text
        self.font = font
        self.period = period
        self.baseOpacity = baseOpacity
        self.peakOpacity = peakOpacity
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Continuous 0…1 phase left → right
            let phase = (t.truncatingRemainder(dividingBy: period)) / period
            // Lead the band slightly past the edges so the light fully enters/exits
            let center = phase * 1.5 - 0.25

            Text(text)
                .font(font)
                .foregroundStyle(Theme.Palette.secondary.opacity(baseOpacity))
                .overlay {
                    Text(text)
                        .font(font)
                        .foregroundStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.primary.opacity(0.0), location: clamp(center - 0.35)),
                                    .init(color: Color.primary.opacity(peakOpacity * 0.55), location: clamp(center - 0.12)),
                                    .init(color: Color.primary.opacity(peakOpacity), location: clamp(center)),
                                    .init(color: Color.primary.opacity(peakOpacity * 0.55), location: clamp(center + 0.12)),
                                    .init(color: Color.primary.opacity(0.0), location: clamp(center + 0.35)),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .mask(Text(text).font(font))
                }
        }
        .accessibilityLabel(text)
    }

    private func clamp(_ v: Double) -> Double {
        min(1, max(0, v))
    }
}

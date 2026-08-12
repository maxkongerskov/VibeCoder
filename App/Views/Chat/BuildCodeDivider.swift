//
//  BuildCodeDivider.swift
//
//  Exact hairline chrome stolen from BuildCode’s AssistantMessageView.
//

import SwiftUI

enum BuildCodeDivider {
    /// Horizontal rule under “Working…” (BuildCode workSection).
    /// `Color.primary.opacity(0.08)`, height 1, top pad 10.
    static func workHairline() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.top, 10)
    }

    /// Vertical rail beside expanded thinking body (BuildCode thoughtSection).
    /// `Color.primary.opacity(0.12)`, width 2.
    static func thoughtRail() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 2)
            .padding(.vertical, 2)
    }

    /// Collapsed-thought tick (BuildCode collapsed thought affordance).
    /// `Color.primary.opacity(0.10)`, width 1.5, height 14.
    static func thoughtTick() -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1.5, height: 14)
            Spacer(minLength: 0)
        }
        .padding(.leading, 5)
        .padding(.top, 6)
    }
}

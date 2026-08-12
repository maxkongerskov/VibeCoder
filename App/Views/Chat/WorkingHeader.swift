//
//  WorkingHeader.swift
//
//  BuildCode-style working header: "Working for Ns" / "Worked for Ns"
//  + exact BuildCode horizontal hairline under the label.
//

import SwiftUI

struct WorkingHeader: View {
    /// Elapsed seconds since the turn started (driven by caller's timer).
    let seconds: Int

    /// When true: live "Working for Ns". When false: past-tense "Worked for Ns".
    let isLive: Bool

    private var label: String {
        // Z-Code style: seconds until 60s, then whole minutes only
        // ("Worked for 1 minute", "Worked for 2 minutes") — never 125s.
        WorkDurationFormat.workingLabel(seconds: seconds, isLive: isLive)
    }

    var body: some View {
        // ZCode / BuildCode workSection: label, then hairline under it.
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isLive {
                    ShimmerText(label, font: .system(size: 13, weight: .medium))
                } else {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hairline dividing "Working/Worked for Ns" from turn body.
            BuildCodeDivider.workHairline()
        }
        // Horizontal inset is applied by the parent (message column /
        // pending bubble) so we don't double-pad when nested.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

//
//  StepperRailSpec.swift
//
//  Single source of truth for ThoughtProcessBlock vertical stepper geometry.
//

import CoreGraphics
import SwiftUI

struct StepperRailSpec: Equatable {
    static let standard = StepperRailSpec()

    let iconSize: CGFloat = 14
    let iconColumnWidth: CGFloat = 14
    let rowCompactHeight: CGFloat = 36
    let rowWithSubtitleHeight: CGFloat = 52
    let iconFrameAlignment: Alignment = .top

    var iconCenterY: CGFloat { iconSize / 2 }
    var lineHorizontalOffset: CGFloat { (iconColumnWidth - 1) / 2 }

    func rowHeight(hasSubtitle: Bool) -> CGFloat {
        hasSubtitle ? rowWithSubtitleHeight : rowCompactHeight
    }

    func connectorHeight(rowHeights: [CGFloat]) -> CGFloat {
        guard rowHeights.count > 1 else { return 0 }
        return rowHeights.dropLast().reduce(0, +)
    }

    func connectorHeight(stepCount: Int) -> CGFloat {
        guard stepCount > 1 else { return 0 }
        return CGFloat(stepCount - 1) * rowCompactHeight
    }
}
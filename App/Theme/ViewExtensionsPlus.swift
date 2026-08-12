// ViewExtensionsPlus.swift
// AgentOS — Claude Edition
//
// Net-new View / NSViewRepresentable extensions from DEV PLAN's
// Utilities/Extensions+View.swift that aren't already defined in
// `ViewExtensions.swift`.
//
// As of this port, `ViewExtensions.swift` already provides:
//   • View.cardStyle(cornerRadius:)
//   • VisualEffectBackground
//   • WindowChromeAdjuster
//
// DEV PLAN's Extensions+View only contained `cardStyle` and
// `VisualEffectBackground` — both already shipped in the Claude Edition
// ViewExtensions file, so there's nothing net-new to port here. This
// file is kept as an intentional stub so the Xcode target has a stable
// home for future App-side view modifiers without re-touching the
// existing ViewExtensions.swift.

import SwiftUI
import AppKit

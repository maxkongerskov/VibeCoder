//
//  ViewExtensions.swift
//
//  Reusable view modifiers + NSViewRepresentable bridges. Ported from
//  DEV PLAN's Utilities/Extensions+View.swift.
//

import SwiftUI
import AppKit

extension View {

    /// Soft card style: rounded surface with a hairline divider stroke.
    /// Used for popovers, settings panes, tool result expanders.
    func cardStyle(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
    }
}

/// Bridges `NSVisualEffectView` into SwiftUI so views can use authentic
/// macOS vibrancy (sidebar, titlebar, popover, etc.) as a background.
/// `.behindWindow` blending samples the desktop / window-below content,
/// matching Finder / Mail / Notes sidebars.
///
/// Ported verbatim from DEV PLAN.
struct VisualEffectBackground: NSViewRepresentable {

    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }
}

/// Tweaks the macOS title bar so it blends seamlessly with the window
/// background — same approach that worked in BuildCode:
///   • hide the app-name title (no "VibeCoder" in the title bar)
///   • transparent titlebar + full-size content under the traffic lights
///   • no separator hairline, so the sidebar can slide left cleanly
///
/// Used inside `RootView` as `WindowChromeAdjuster()` at the bottom of
/// the view hierarchy. Re-applied on update because NavigationSplitView
/// can reintroduce title/separator chrome when columns toggle.
struct WindowChromeAdjuster: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(to: nsView.window)
        }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }

        // Hide the system window title string (app name / nav title).
        // This is the reliable macOS 14+ equivalent of SwiftUI
        // `.toolbar(removing: .title)` used in BuildCode.
        window.titleVisibility = .hidden
        window.title = ""

        window.titlebarAppearsTransparent = true
        // No horizontal divider under the traffic-light strip.
        window.titlebarSeparatorStyle = .none
        // Content draws under the titlebar so sidebar collapse doesn't
        // leave a titled dead strip; traffic lights stay usable.
        window.styleMask.insert(.fullSizeContentView)
    }
}

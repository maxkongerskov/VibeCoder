//
//  InputCardPopupChrome.swift
//
//  Single visual + placement schema for every popup on the input card.
//  Matches the context-meter hover card: surface fill, 12pt continuous
//  corners, light hairline, soft shadow — always opens *upward* from
//  the anchor (never downward into the window edge).
//
//  Outside-click dismiss: any mouse-down outside the popup *and* its
//  anchor chip closes the menu (standard macOS menu behavior).
//

import SwiftUI
import AppKit

enum InputCardPopupStyle {
    static let cornerRadius: CGFloat = 12
    static let contentPadding: CGFloat = 14
    static let strokeOpacity: Double = 0.10
    static let shadowRadius: CGFloat = 14
    static let shadowY: CGFloat = 6
    static let shadowOpacity: Double = 0.18
    /// Air between popup bottom and the chip/pill that anchors it.
    static let gapAboveAnchor: CGFloat = 8
    /// Default width for list-style menus (model / mode / thinking).
    static let menuWidth: CGFloat = 320
    static let modelMenuWidth: CGFloat = 360
    static let modelMenuMaxHeight: CGFloat = 480
}

/// Shared chrome: fill, border, shadow — identical for all input-card popups.
struct InputCardPopupChrome<Content: View>: View {
    var width: CGFloat? = nil
    var maxHeight: CGFloat? = nil
    /// When false, content supplies its own padding (e.g. list menus).
    var includePadding: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if includePadding {
                content().padding(InputCardPopupStyle.contentPadding)
            } else {
                content()
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: InputCardPopupStyle.cornerRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InputCardPopupStyle.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(InputCardPopupStyle.strokeOpacity), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(InputCardPopupStyle.shadowOpacity),
            radius: InputCardPopupStyle.shadowRadius,
            y: InputCardPopupStyle.shadowY
        )
    }
}

// MARK: - Frame prefs (global / screen space)

private struct InputCardAnchorFrameKey: PreferenceKey {
    // `let` avoids Swift 6 "nonisolated global shared mutable state".
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct InputCardPopupFrameKey: PreferenceKey {
    // `let` avoids Swift 6 "nonisolated global shared mutable state".
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Upward popup + outside click

/// Reference box so the NSEvent monitor always sees live frames/bindings.
private final class InputCardOutsideClickBox {
    var anchorGlobal: CGRect = .zero
    var popupGlobal: CGRect = .zero
    var dismiss: (() -> Void)?
    var monitor: Any?
}

/// Places `popup` above the modified view (context-meter technique).
/// Clicking anywhere outside the popup and its anchor chip dismisses it.
struct InputCardUpwardPopup<Popup: View>: ViewModifier {
    @Binding var isPresented: Bool
    var horizontalAlignment: HorizontalAlignment = .leading
    @ViewBuilder var popup: () -> Popup

    @State private var clickBox = InputCardOutsideClickBox()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: InputCardAnchorFrameKey.self,
                        value: geo.frame(in: .global)
                    )
                }
            )
            .onPreferenceChange(InputCardAnchorFrameKey.self) { clickBox.anchorGlobal = $0 }
            .overlay(alignment: Alignment(horizontal: horizontalAlignment, vertical: .top)) {
                if isPresented {
                    popup()
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: InputCardPopupFrameKey.self,
                                    value: geo.frame(in: .global)
                                )
                            }
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, InputCardPopupStyle.gapAboveAnchor)
                        .frame(height: 0, alignment: .bottom)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                        )
                }
            }
            .onPreferenceChange(InputCardPopupFrameKey.self) { clickBox.popupGlobal = $0 }
            .zIndex(isPresented ? 80 : 0)
            .animation(.easeOut(duration: 0.12), value: isPresented)
            .onChange(of: isPresented) { _, open in
                if open {
                    installOutsideClickMonitor()
                } else {
                    removeOutsideClickMonitor()
                }
            }
            .onDisappear {
                removeOutsideClickMonitor()
            }
    }

    // MARK: - Outside click (AppKit local monitor)

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let box = clickBox
        box.dismiss = {
            withAnimation(.easeOut(duration: 0.12)) {
                isPresented = false
            }
        }
        // Defer so the same click that opened the menu is not treated as outside.
        DispatchQueue.main.async {
            guard isPresented else { return }
            box.monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { event in
                if Self.shouldDismiss(event: event, box: box) {
                    DispatchQueue.main.async {
                        box.dismiss?()
                    }
                }
                return event
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = clickBox.monitor {
            NSEvent.removeMonitor(monitor)
            clickBox.monitor = nil
        }
        clickBox.dismiss = nil
    }

    /// Dismiss when the click is outside both the anchor chip and the popup.
    private static func shouldDismiss(event: NSEvent, box: InputCardOutsideClickBox) -> Bool {
        let point = globalPoint(for: event)
        let pad: CGFloat = 6
        let anchor = box.anchorGlobal.insetBy(dx: -pad, dy: -pad)
        let panel = box.popupGlobal.insetBy(dx: -pad, dy: -pad)
        if anchor != .zero, anchor.contains(point) { return false }
        if panel != .zero, panel.contains(point) { return false }
        return true
    }

    /// Convert an NSEvent location into SwiftUI `.global` space (top-left origin).
    private static func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window = event.window else {
            return CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let screen = window.screen ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0
        let screenOriginY = screen?.frame.origin.y ?? 0
        let flippedY = (screenOriginY + screenHeight) - screenPoint.y
        return CGPoint(x: screenPoint.x, y: flippedY)
    }
}

extension View {
    /// Attach an upward popup with shared input-card chrome placement.
    /// Dismisses when the user clicks anywhere outside the popup and its chip
    /// (except controls that never use this helper — e.g. + attach files).
    func inputCardUpwardPopup<Popup: View>(
        isPresented: Binding<Bool>,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder popup: @escaping () -> Popup
    ) -> some View {
        modifier(InputCardUpwardPopup(
            isPresented: isPresented,
            horizontalAlignment: alignment,
            popup: popup
        ))
    }
}

/// Standard selectable row inside input-card list menus.
struct InputCardPopupRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    var isHovered: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 14)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                        .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered || isSelected
                          ? Theme.Palette.hover
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

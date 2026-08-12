//
//  StickToBottomTracker.swift
//
//  ChatGPT / Cursor-style “stick to bottom” detection for SwiftUI ScrollView.
//  While the model streams, auto-scroll follows the latest tokens only when
//  the user is near the bottom. A slight trackpad nudge upward detaches;
//  scrolling back to the live edge re-attaches.
//
//  AppKit-backed so it works on macOS 14+ (no onScrollGeometryChange dependency).
//

import SwiftUI
import AppKit

/// Invisible probe: finds the enclosing `NSScrollView` and publishes whether
/// the viewport should stay glued to the bottom (`isPinned`).
struct StickToBottomTracker: NSViewRepresentable {
    @Binding var isPinned: Bool
    /// How close to the bottom (points) counts as “attached”.
    var threshold: CGFloat = 72

    func makeCoordinator() -> Coordinator {
        Coordinator(isPinned: $isPinned, threshold: threshold)
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPinned = $isPinned
        context.coordinator.threshold = threshold
        if let probe = nsView as? ProbeView {
            probe.coordinator = context.coordinator
        }
        // Defer attach until after layout settles.
        Task { @MainActor in
            context.coordinator.attach(from: nsView)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    /// All AppKit scroll geometry is MainActor-isolated under Swift 6.
    @MainActor
    final class Coordinator {
        var isPinned: Binding<Bool>
        var threshold: CGFloat

        private weak var scrollView: NSScrollView?
        /// Observation tokens must be removable from `deinit` (nonisolated).
        nonisolated(unsafe) private var observations: [NSObjectProtocol] = []
        private var lastContentHeight: CGFloat = 0
        private var lastDistance: CGFloat = 0

        init(isPinned: Binding<Bool>, threshold: CGFloat) {
            self.isPinned = isPinned
            self.threshold = threshold
        }

        deinit {
            for o in observations {
                NotificationCenter.default.removeObserver(o)
            }
        }

        func attach(from view: NSView) {
            guard let sv = Self.enclosingScrollView(from: view) else { return }
            if scrollView === sv {
                evaluate()
                return
            }
            detach()
            scrollView = sv

            sv.contentView.postsBoundsChangedNotifications = true
            sv.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            // Notification handlers are @Sendable; hop back to MainActor.
            observations = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: sv.contentView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.evaluate()
                    }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: sv,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.evaluate()
                    }
                },
            ]

            if let doc = sv.documentView {
                doc.postsFrameChangedNotifications = true
                observations.append(
                    center.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: doc,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.evaluate()
                        }
                    }
                )
            }

            evaluate()
        }

        func detach() {
            for o in observations {
                NotificationCenter.default.removeObserver(o)
            }
            observations.removeAll()
            scrollView = nil
            lastContentHeight = 0
        }

        func evaluate() {
            guard let sv = scrollView, let doc = sv.documentView else { return }

            let clip = sv.contentView.bounds
            let docHeight = max(doc.frame.height, doc.bounds.height)
            // SwiftUI’s scroll document is flipped (origin top-left).
            let visibleMaxY: CGFloat
            if doc.isFlipped {
                visibleMaxY = clip.maxY
            } else {
                // Unflipped: clip minY grows as you scroll up from the bottom.
                visibleMaxY = docHeight - clip.minY
            }

            let bottomInset = sv.contentInsets.bottom
                + sv.contentView.contentInsets.bottom
            let distance = max(0, docHeight - visibleMaxY - bottomInset)

            let contentGrew = docHeight > lastContentHeight + 1
            lastContentHeight = docHeight
            lastDistance = distance

            if distance <= threshold {
                setPinned(true)
                return
            }

            // Content grew while we were still pinned (streaming). Keep the
            // pin so the auto-scroll path can catch up — do NOT treat growth
            // as “user scrolled away”.
            if contentGrew && isPinned.wrappedValue {
                return
            }

            // User scrolled away from the live edge.
            setPinned(false)
        }

        private func setPinned(_ value: Bool) {
            if isPinned.wrappedValue != value {
                isPinned.wrappedValue = value
            }
        }

        private static func enclosingScrollView(from view: NSView) -> NSScrollView? {
            if let sv = view.enclosingScrollView { return sv }
            var current: NSView? = view.superview
            while let node = current {
                if let sv = node as? NSScrollView { return sv }
                current = node.superview
            }
            return nil
        }
    }

    // MARK: - Probe view

    @MainActor
    private final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override var intrinsicContentSize: NSSize {
            NSSize(width: 0, height: 0)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reattach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            reattach()
        }

        private func reattach() {
            // Stay on MainActor — do not capture Coordinator into a Sendable
            // DispatchQueue closure under Swift 6.
            Task { @MainActor [weak self] in
                guard let self, let coordinator = self.coordinator else { return }
                coordinator.attach(from: self)
            }
        }
    }
}

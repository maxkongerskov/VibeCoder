//
//  CommandPaletteView.swift
//
//  Global ⌘K searchable command overlay.
//

import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let items: [CommandPaletteItem]
    let onRun: (CommandPaletteItem) -> Void

    @State private var query: String = ""
    /// `nil` until the user arrows or hovers — Enter then runs the first match.
    @State private var focusedID: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [CommandPaletteItem] {
        CommandPaletteFilter.filter(items, query: query)
    }

    private var sections: [PaletteSection] {
        PaletteSection.group(filtered)
    }

    private var visibleItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    private var resolvedFocusedID: String? {
        if let focusedID, visibleItems.contains(where: { $0.id == focusedID }) {
            return focusedID
        }
        return visibleItems.first?.id
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary)
                    TextField("Search commands…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { runFocusedIfAny() }
                        .onKeyPress(.upArrow) {
                            moveFocus(-1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveFocus(1)
                            return .handled
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().opacity(0.5)

                if filtered.isEmpty {
                    Text("No matching commands")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sections) { section in
                                    Text(section.category.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.tertiary)
                                        .tracking(0.8)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)

                                    ForEach(section.items) { item in
                                        commandRow(item, isFocused: item.id == resolvedFocusedID)
                                            .id(item.id)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: resolvedFocusedID) { _, id in
                            guard let id else { return }
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            .frame(width: 520)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.Palette.divider, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .background(PaletteArrowMonitor(onUp: { moveFocus(-1) }, onDown: { moveFocus(1) }))
        }
        .onAppear {
            query = ""
            focusedID = nil
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            focusedID = nil
        }
        .onExitCommand { dismiss() }
    }

    private func commandRow(_ item: CommandPaletteItem, isFocused: Bool) -> some View {
        Button {
            onRun(item)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.primary)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.tertiary)
                    }
                }
                Spacer()
                if let hint = Self.shortcutHint(for: item.id) {
                    Text(hint)
                        .font(Theme.Typography.mono(size: 11))
                        .foregroundStyle(Theme.Palette.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isFocused ? Theme.Palette.hover : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { focusedID = item.id }
        }
    }

    private func moveFocus(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = resolvedFocusedID
        let idx = current.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        let next = (idx + delta + items.count) % items.count
        focusedID = items[next].id
    }

    private func runFocusedIfAny() {
        let items = visibleItems
        guard let id = resolvedFocusedID,
              let item = items.first(where: { $0.id == id }) else { return }
        onRun(item)
        dismiss()
    }

    private func dismiss() {
        isPresented = false
    }

    /// Shortcuts owned by app menus (or documented in the existing item copy).
    private static func shortcutHint(for id: String) -> String? {
        switch id {
        case "new-chat": return "⌘N"
        case "open-settings": return "⌘,"
        case "stop-agent": return "⌘."
        case "cycle-mode": return "⇧Tab"
        case "find-in-task": return "⌘F"
        case "toggle-sidebar": return "⌘B"
        case "toggle-side-pane": return "⌥⌘B"
        case "toggle-terminal": return "⌘J"
        case "prev-task": return "⌘⇧["
        case "next-task": return "⌘⇧]"
        case "open-workspace": return "⌘O"
        default: return nil
        }
    }
}

// MARK: - Sections

private struct PaletteSection: Identifiable {
    let category: String
    let items: [CommandPaletteItem]
    var id: String { category }

    /// Preferred header order; unknown categories append in first-seen order.
    static let preferredOrder = ["Chat", "Safety", "Model", "App"]

    static func group(_ items: [CommandPaletteItem]) -> [PaletteSection] {
        var buckets: [(String, [CommandPaletteItem])] = []
        var index: [String: Int] = [:]
        let present = Set(items.map(\.category))
        for category in preferredOrder where present.contains(category) {
            index[category] = buckets.count
            buckets.append((category, []))
        }
        for item in items {
            if let i = index[item.category] {
                buckets[i].1.append(item)
            } else {
                index[item.category] = buckets.count
                buckets.append((item.category, [item]))
            }
        }
        return buckets.compactMap { category, grouped in
            grouped.isEmpty ? nil : PaletteSection(category: category, items: grouped)
        }
    }
}

// MARK: - Arrow keys while the search field is focused

/// TextField swallows ↑/↓; consume them here so selection can wrap.
private struct PaletteArrowMonitor: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUp: onUp, onDown: onDown)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onUp: () -> Void
        var onDown: () -> Void
        var monitor: Any?

        init(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let mods = event.modifierFlags.intersection([.command, .option, .control])
                guard mods.isEmpty else { return event }
                switch event.keyCode {
                case 126:
                    self.onUp()
                    return nil
                case 125:
                    self.onDown()
                    return nil
                default:
                    return event
                }
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

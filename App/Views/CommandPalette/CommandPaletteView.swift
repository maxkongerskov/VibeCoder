//
//  CommandPaletteView.swift
//
//  Global ⌘K searchable command overlay.
//

import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let items: [CommandPaletteItem]
    let onRun: (CommandPaletteItem) -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [CommandPaletteItem] {
        CommandPaletteFilter.filter(items, query: query)
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
                        .onSubmit { runFirstIfAny() }
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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { item in
                                commandRow(item)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
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
        }
        .onAppear {
            query = ""
            searchFocused = true
        }
        .onExitCommand { dismiss() }
    }

    private func commandRow(_ item: CommandPaletteItem) -> some View {
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
                Text(item.category)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Palette.muted.opacity(0.7))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runFirstIfAny() {
        guard let first = filtered.first else { return }
        onRun(first)
        dismiss()
    }

    private func dismiss() {
        isPresented = false
    }
}
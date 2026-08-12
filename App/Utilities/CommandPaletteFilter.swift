//
//  CommandPaletteFilter.swift
//
//  Pure search/filter for the ⌘K command palette.
//

import Foundation

struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String
    let keywords: [String]
}

enum CommandPaletteFilter {
    static func filter(_ items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.title.lowercased().contains(needle)
                || (item.subtitle?.lowercased().contains(needle) ?? false)
                || item.category.lowercased().contains(needle)
                || item.keywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
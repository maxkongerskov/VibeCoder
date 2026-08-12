// NavigationState.swift
// AgentOS — Claude Edition
//
// Lightweight coordinator for which "page" is showing in the main pane.
// The sidebar's top nav writes here; RootView reads here to swap the
// detail view between Chat / Projects / Tasks / Notes / Models.

import Foundation
import Combine

@MainActor
final class NavigationState: ObservableObject {
    enum Pane: Equatable {
        case chat
        case newTaskLanding   // Welcome screen with a big + button (creates the task on click)
        case projects
        case tasksList        // "View All" → full Tasks landing with tabs/list
        case notes            // Notes pane — list + search + edit
        case models           // Models landing — downloaded library + catalog + status
    }
    @Published var pane: Pane = .chat
}

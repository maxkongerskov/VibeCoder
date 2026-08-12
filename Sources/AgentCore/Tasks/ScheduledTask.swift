//
//  ScheduledTask.swift
//
//  Persisted shape of a scheduled task. The DEV PLAN shipped the model +
//  form UI in Phase 1.5b; the actual scheduler runtime (timer-driven
//  dispatch) is wired in a later phase.
//
//  Ported as a pure value type — no SwiftUI imports. Display labels and
//  SF Symbol names live here so the App target can render without
//  duplicating the mapping, but they're plain strings (no `Image` types).
//

import Foundation

public enum TaskFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, hourly, daily, weekdays, weekly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual:   return "Manual"
        case .hourly:   return "Hourly"
        case .daily:    return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly:   return "Weekly"
        }
    }
}

public enum TaskAskMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, allow, never

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ask:   return "Ask"
        case .allow: return "Auto-allow"
        case .never: return "Never"
        }
    }

    /// SF Symbol name. Kept as a String so AgentCore stays UI-framework-free —
    /// the App target turns this into a SwiftUI `Image(systemName:)`.
    public var icon: String {
        switch self {
        case .ask:   return "hand.raised"
        case .allow: return "checkmark.circle"
        case .never: return "nosign"
        }
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// One-sentence summary (short prompt).
    public var shortPrompt: String
    /// Longer description / detailed instructions.
    public var longPrompt: String
    /// Optional project folder path the task should operate in.
    public var projectFolder: String?
    public var askMode: TaskAskMode
    public var frequency: TaskFrequency
    /// Minutes after midnight (0–1439, local time) at which a day-based
    /// schedule should fire — e.g. 120 = 02:00. nil means "no specific
    /// time": fire on the first tick of the matching period (the legacy
    /// behaviour). Ignored for `.hourly` and `.manual`. This is what makes
    /// "run at 2am while I sleep" mean an actual time.
    public var timeOfDayMinutes: Int?
    public var createdAt: Date
    /// Free-form notes for the task kind ("News", "Reminder", etc.) gathered
    /// during the AI questionnaire. Used only by the in-chat questionnaire.
    public var taskKind: String
    /// True once the in-chat questionnaire has been completed (or dismissed)
    /// for this task — the questionnaire card stops showing after this.
    public var setupComplete: Bool
    /// Wall-clock time at which the scheduler last fired this task. Used by
    /// `SchedulerService.shouldFire(task:now:)` to decide whether the task
    /// is due again. Nil = never fired. Synthesised Codable handles the
    /// missing-key case for older saved tasks (decodes to nil).
    public var lastFiredAt: Date?
    /// The conversation the most recent firing produced. Lets the
    /// Scheduled pane link a schedule straight to "what it did last run"
    /// instead of making the user hunt through Recents. nil = never run
    /// (or ran before this field existed).
    public var lastRunConversationID: UUID?

    public init(id: UUID = UUID(),
                name: String,
                shortPrompt: String = "",
                longPrompt: String = "",
                projectFolder: String? = nil,
                askMode: TaskAskMode = .ask,
                frequency: TaskFrequency = .manual,
                timeOfDayMinutes: Int? = nil,
                createdAt: Date = Date(),
                taskKind: String = "",
                setupComplete: Bool = false,
                lastFiredAt: Date? = nil,
                lastRunConversationID: UUID? = nil) {
        self.id = id
        self.name = name
        self.shortPrompt = shortPrompt
        self.longPrompt = longPrompt
        self.projectFolder = projectFolder
        self.askMode = askMode
        self.frequency = frequency
        self.timeOfDayMinutes = timeOfDayMinutes
        self.createdAt = createdAt
        self.taskKind = taskKind
        self.setupComplete = setupComplete
        self.lastFiredAt = lastFiredAt
        self.lastRunConversationID = lastRunConversationID
    }

    /// Human-readable schedule, e.g. "Daily · 02:00" or "Weekdays".
    public var scheduleDescription: String {
        guard frequency != .manual else { return frequency.label }
        guard frequency != .hourly, let mins = timeOfDayMinutes else { return frequency.label }
        let h = mins / 60, m = mins % 60
        return "\(frequency.label) · \(String(format: "%02d:%02d", h, m))"
    }
}

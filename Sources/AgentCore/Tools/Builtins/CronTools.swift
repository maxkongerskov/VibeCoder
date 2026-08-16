//
//  CronTools.swift
//
//  Model-facing schedule tools (ZCode CronCreate / CronList / CronUpdate /
//  CronDelete). Persistence is ScheduledTaskStore — the same default
//  directory the Scheduled UI uses. SchedulerService is in-process, so
//  schedules run only while the app is open.
//
//  Wave-2 registry owner should add these four lines to registerBuiltins():
//      register(CronCreateTool.self)
//      register(CronListTool.self)
//      register(CronUpdateTool.self)
//      register(CronDeleteTool.self)
//

import Foundation

/// Test hook. Production leaves `override` nil so tools use
/// `ScheduledTaskStore()` (default directory, same as the UI).
enum CronToolStore {
    /// XCTest assigns a temp-dir store; `ParityCronToolsTests` clears this in tearDown.
    nonisolated(unsafe) static var override: ScheduledTaskStore?

    static func resolved() -> ScheduledTaskStore {
        override ?? ScheduledTaskStore()
    }
}

// MARK: - cron_create

public struct CronCreateTool: Tool {
    public static let name = "cron_create"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Create a persistent scheduled automation. Use this only when the user \
        explicitly asks to schedule future automatic work.

        Frequency is one of manual, hourly, daily, weekdays, weekly (user's \
        local timezone). For daily / weekdays / weekly, optional \
        timeOfDayMinutes (0–1439, minutes after local midnight) sets the \
        wall-clock time; omit it to fire on the first matching tick. Hourly \
        and manual ignore timeOfDayMinutes. Manual never auto-fires — the \
        user runs it from the Scheduled UI.

        Write prompt as a complete instruction that can run later without \
        unstated conversation context. Never ask the scheduled run to create, \
        schedule, or configure another automation, and never ask it to call \
        cron_create.

        Schedules persist until deleted (maximum 20) and run only while the \
        app is open — this is not a background daemon. Honor exact user times \
        without adding jitter.
        """,
        parameters: .init(
            properties: [
                "name": .init(
                    type: "string",
                    description: "Concise title. Preserve the user's natural-language schedule phrase (e.g. 'every weekday at 9')."
                ),
                "prompt": .init(
                    type: "string",
                    description: "Complete prompt sent at every scheduled fire. Include all instructions the run will need."
                ),
                "frequency": .init(
                    type: "string",
                    description: "How often to fire.",
                    enum: TaskFrequency.allCases.map(\.rawValue)
                ),
                "timeOfDayMinutes": .init(
                    type: "integer",
                    description: "Local minutes after midnight (0–1439), e.g. 540 = 09:00. Omit for no specific time. Ignored for hourly and manual."
                ),
                "projectFolder": .init(
                    type: "string",
                    description: "Optional project folder the run should operate in. Defaults to the current workspace."
                ),
            ],
            required: ["name", "prompt", "frequency"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let name = try arguments.string("name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = try arguments.string("prompt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let freqRaw = try arguments.string("frequency")

        guard !name.isEmpty else {
            return ToolResult(content: "Error: name must not be empty.", isError: true)
        }
        guard !prompt.isEmpty else {
            return ToolResult(content: "Error: prompt must not be empty.", isError: true)
        }
        guard let frequency = CronToolSupport.parseFrequency(freqRaw) else {
            return ToolResult(content: CronToolSupport.unknownFrequency(freqRaw), isError: true)
        }
        let parsedTime = CronToolSupport.parseTimeOfDayMinutes(arguments)
        if let message = parsedTime.error {
            return ToolResult(content: message, isError: true)
        }
        let store = CronToolStore.resolved()
        let existing = await store.load()
        if existing.count >= CronToolSupport.maxTasks {
            return ToolResult(
                content: "Error: do not retry; schedule limit reached",
                isError: true)
        }

        let projectFolder = CronToolSupport.parseProjectFolder(
            arguments.stringOptional("projectFolder"),
            defaultFolder: context.usableWorkspaceRoot?.path)

        let task = ScheduledTask(
            name: name,
            shortPrompt: prompt,
            longPrompt: prompt,
            projectFolder: projectFolder,
            frequency: frequency,
            timeOfDayMinutes: parsedTime.minutes,
            setupComplete: true)
        await store.add(task)
        return ToolResult(
            content: """
            Created schedule.
            \(CronToolSupport.render(task))

            \(CronToolSupport.appOpenNote)
            """)
    }
}

// MARK: - cron_list

public struct CronListTool: Tool {
    public static let name = "cron_list"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        List scheduled automations (id, name, frequency, time, last fired). \
        Use this before cron_update or cron_delete when the id is not already \
        known. Never guess an id. Schedules run only while the app is open.
        """,
        parameters: .init(properties: [:], required: [])
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let tasks = await CronToolStore.resolved().load()
        guard !tasks.isEmpty else {
            return ToolResult(content: "No scheduled tasks.")
        }
        let body = tasks.map(CronToolSupport.render).joined(separator: "\n\n")
        return ToolResult(content: """
            \(tasks.count) scheduled task(s). \(CronToolSupport.appOpenNote)

            \(body)
            """)
    }
}

// MARK: - cron_update

public struct CronUpdateTool: Tool {
    public static let name = "cron_update"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Update selected fields of an existing scheduled automation while \
        keeping its id and run history. Use cron_list first when the id is \
        not already known. Never guess an id. Do not delete and recreate.

        Only pass fields the user asked to change; omitted fields keep their \
        current values. After a successful update, reply with a brief \
        confirmation — do not restate every field.

        Schedules run only while the app is open.
        """,
        parameters: .init(
            properties: [
                "id": .init(
                    type: "string",
                    description: "Automation id returned by cron_create or cron_list."
                ),
                "name": .init(
                    type: "string",
                    description: "Replacement title. Omit to keep the current name."
                ),
                "prompt": .init(
                    type: "string",
                    description: "Replacement prompt for future fires. Omit to keep the current prompt."
                ),
                "frequency": .init(
                    type: "string",
                    description: "Replacement frequency.",
                    enum: TaskFrequency.allCases.map(\.rawValue)
                ),
                "timeOfDayMinutes": .init(
                    type: "integer",
                    description: "Replacement local minutes after midnight (0–1439). Omit to keep the current time."
                ),
                "projectFolder": .init(
                    type: "string",
                    description: "Replacement project folder. Pass an empty string to clear. Omit to keep the current folder."
                ),
            ],
            required: ["id"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let idRaw = try arguments.string("id")
        guard let id = CronToolSupport.parseID(idRaw) else {
            return ToolResult(content: CronToolSupport.invalidID(idRaw), isError: true)
        }

        let nameIn = arguments.stringOptional("name")
        let promptIn = arguments.stringOptional("prompt")
        let freqIn = arguments.stringOptional("frequency")
        let folderIn = arguments.stringOptional("projectFolder")
        let hasTime = arguments.raw["timeOfDayMinutes"] != nil

        guard nameIn != nil || promptIn != nil || freqIn != nil || folderIn != nil || hasTime else {
            return ToolResult(
                content: "Error: nothing to update — pass name, prompt, frequency, timeOfDayMinutes, or projectFolder.",
                isError: true)
        }

        let store = CronToolStore.resolved()
        _ = await store.load()
        guard var task = await store.task(id: id) else {
            return ToolResult(content: CronToolSupport.unknownID(id), isError: true)
        }

        if let nameIn {
            let name = nameIn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return ToolResult(content: "Error: name must not be empty.", isError: true)
            }
            task.name = name
        }
        if let promptIn {
            let prompt = promptIn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return ToolResult(content: "Error: prompt must not be empty.", isError: true)
            }
            task.shortPrompt = prompt
            task.longPrompt = prompt
        }
        if let freqIn {
            guard let frequency = CronToolSupport.parseFrequency(freqIn) else {
                return ToolResult(content: CronToolSupport.unknownFrequency(freqIn), isError: true)
            }
            task.frequency = frequency
        }
        if hasTime {
            let parsedTime = CronToolSupport.parseTimeOfDayMinutes(arguments)
            if let message = parsedTime.error {
                return ToolResult(content: message, isError: true)
            }
            task.timeOfDayMinutes = parsedTime.minutes
        }
        if let folderIn {
            task.projectFolder = CronToolSupport.parseProjectFolder(folderIn, defaultFolder: nil)
        }

        await store.update(task)
        return ToolResult(content: """
            Updated schedule.
            \(CronToolSupport.render(task))
            """)
    }
}

// MARK: - cron_delete

public struct CronDeleteTool: Tool {
    public static let name = "cron_delete"
    public static let category: ToolCategory = .planning
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Delete a scheduled automation by id. Use cron_list first when the \
        id is not already known. Never guess an id. Schedules run only \
        while the app is open.
        """,
        parameters: .init(
            properties: [
                "id": .init(
                    type: "string",
                    description: "Automation id returned by cron_create or cron_list."
                ),
            ],
            required: ["id"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let idRaw = try arguments.string("id")
        guard let id = CronToolSupport.parseID(idRaw) else {
            return ToolResult(content: CronToolSupport.invalidID(idRaw), isError: true)
        }
        let store = CronToolStore.resolved()
        _ = await store.load()
        guard let task = await store.task(id: id) else {
            return ToolResult(content: CronToolSupport.unknownID(id), isError: true)
        }
        await store.remove(id: id)
        return ToolResult(content: "Deleted schedule \(task.id.uuidString) (\(task.name)).")
    }
}

// MARK: - Shared

private enum CronToolSupport {
    static let maxTasks = 20
    static let appOpenNote = "Schedules run only while the app is open."

    static func parseFrequency(_ raw: String) -> TaskFrequency? {
        TaskFrequency(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func parseID(_ raw: String) -> UUID? {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `nil` minutes means "not provided" (or JSON null). Non-nil `error` is a tool message.
    static func parseTimeOfDayMinutes(_ arguments: ToolArguments) -> (minutes: Int?, error: String?) {
        guard arguments.raw["timeOfDayMinutes"] != nil,
              !(arguments.raw["timeOfDayMinutes"] is NSNull) else {
            return (nil, nil)
        }
        guard let mins = arguments.intOptional("timeOfDayMinutes"),
              (0...1439).contains(mins) else {
            return (nil, "Error: timeOfDayMinutes must be an integer from 0 to 1439.")
        }
        return (mins, nil)
    }

    static func parseProjectFolder(_ raw: String?, defaultFolder: String?) -> String? {
        guard let raw else { return defaultFolder }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func formatTime(_ minutes: Int?) -> String {
        guard let mins = minutes else { return "—" }
        let clamped = max(0, min(mins, 1439))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func formatLastFired(_ date: Date?) -> String {
        guard let date else { return "never" }
        return ISO8601DateFormatter().string(from: date)
    }

    static func render(_ task: ScheduledTask) -> String {
        [
            "id: \(task.id.uuidString)",
            "name: \(task.name)",
            "frequency: \(task.frequency.rawValue)",
            "time: \(formatTime(task.timeOfDayMinutes))",
            "last_fired: \(formatLastFired(task.lastFiredAt))",
        ].joined(separator: "\n")
    }

    static func unknownFrequency(_ raw: String) -> String {
        "Error: unknown frequency '\(raw)'. Use one of: manual, hourly, daily, weekdays, weekly."
    }

    static func invalidID(_ raw: String) -> String {
        "Error: invalid schedule id '\(raw)'."
    }

    static func unknownID(_ id: UUID) -> String {
        "Error: no schedule with id '\(id.uuidString)'. Use cron_list."
    }
}

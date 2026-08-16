//
//  HookConfigStore.swift
//  Load/save hooks.json using HookDispatcher's nested schema.
//
//  Project file: <project>/.vibecoder/hooks/hooks.json (or existing
//  config.json / .grok/hooks). User path ~/.vibecoder/hooks.json is
//  exposed for the Settings UI only — HookDispatcher does not read it.
//

import Foundation

/// Flattened row for the Settings editor. File shape stays nested
/// `{ "hooks": { "PreToolUse": [{ matcher, hooks: [{ type, command, … }] }] } }`.
public struct HookEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var event: String
    public var matcher: String?
    public var command: String
    public var args: [String]
    public var timeoutSeconds: Int?
    public var background: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        event: String,
        matcher: String? = nil,
        command: String,
        args: [String] = [],
        timeoutSeconds: Int? = nil,
        background: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.command = command
        self.args = args
        self.timeoutSeconds = timeoutSeconds
        self.background = background
        self.enabled = enabled
    }
}

public enum HookConfigStoreError: Error, Equatable, LocalizedError, Sendable {
    case noProjectRoot
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .noProjectRoot: return "No project folder is open."
        case .encodeFailed: return "Could not encode hooks.json."
        }
    }
}

public enum HookConfigStore: Sendable {

    /// ZCode Settings event list (`f2t`). Notification is still parsed if present.
    public static let editorEvents: [String] = [
        HookDispatcher.eventSessionStart,
        HookDispatcher.eventUserPromptSubmit,
        HookDispatcher.eventPreToolUse,
        HookDispatcher.eventPermissionRequest,
        HookDispatcher.eventPostToolUse,
        HookDispatcher.eventPostToolUseFailure,
        HookDispatcher.eventStop,
    ]

    /// Display-only. Dispatcher never searches `$HOME/.vibecoder`.
    public static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibecoder/hooks.json", isDirectory: false)
    }

    /// Write target: existing hooks.json/config.json if the dispatcher
    /// would read it; otherwise `<project>/.vibecoder/hooks/hooks.json`.
    public static func configURL(projectRoot: URL) -> URL {
        if let dir = HookDispatcher.hooksDir(projectRoot: projectRoot) {
            if let existing = HookDispatcher.configURL(hooksDir: dir) {
                return existing
            }
            return dir.appendingPathComponent("hooks.json")
        }
        return projectRoot
            .appendingPathComponent(".vibecoder/hooks/hooks.json", isDirectory: false)
    }

    // MARK: HookConfigFile (dispatcher schema)

    public static func load(projectRoot: URL?) -> HookConfigFile {
        guard let root = projectRoot,
              let dir = HookDispatcher.hooksDir(projectRoot: root)
        else { return .empty }
        return HookDispatcher.loadConfig(hooksDir: dir)
    }

    public static func save(_ config: HookConfigFile, projectRoot: URL?) throws {
        guard let root = projectRoot else { throw HookConfigStoreError.noProjectRoot }
        let url = configURL(projectRoot: root)
        let written = HookDispatcher.encodeConfigObject(config)
        let merged = mergePreservingUnknown(
            existingURL: url,
            incoming: written,
            preserveUnknownHookEvents: true
        )
        try writePrettyJSON(merged, to: url)
    }

    // MARK: Entries (Settings editor)

    public static func loadEntries(projectRoot: URL?) -> [HookEntry] {
        guard let root = projectRoot else { return [] }
        let url = configURL(projectRoot: root)
        return loadEntries(from: url)
    }

    public static func loadUserEntries() -> [HookEntry] {
        loadEntries(from: userConfigURL)
    }

    public static func saveEntries(_ entries: [HookEntry], projectRoot: URL?) throws {
        guard let root = projectRoot else { throw HookConfigStoreError.noProjectRoot }
        let url = configURL(projectRoot: root)
        try saveEntries(entries, to: url)
    }

    public static func prettyJSONData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HookConfigStoreError.encodeFailed
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    public static func encodeEntriesObject(_ entries: [HookEntry]) -> [String: Any] {
        let enabled = entries.filter(\.enabled)
        let disabled = entries.filter { !$0.enabled }
        var root: [String: Any] = ["hooks": groupedHookObject(enabled)]
        if !disabled.isEmpty {
            root["disabledHooks"] = groupedHookObject(disabled)
        }
        return root
    }

    public static func decodeEntries(from data: Data) throws -> [HookEntry] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return parseEntries(from: obj)
    }

    public static func canonicalEventName(_ raw: String) -> String {
        switch raw {
        case HookDispatcher.eventPreToolUse, "pre_tool_use", "pre", "preToolUse":
            return HookDispatcher.eventPreToolUse
        case HookDispatcher.eventPostToolUse, "post_tool_use", "post", "postToolUse":
            return HookDispatcher.eventPostToolUse
        case HookDispatcher.eventSessionStart, "session_start", "sessionStart":
            return HookDispatcher.eventSessionStart
        case HookDispatcher.eventUserPromptSubmit,
             "user_prompt_submit", "userPromptSubmit", "beforeSubmitPrompt":
            return HookDispatcher.eventUserPromptSubmit
        case HookDispatcher.eventStop, "stop":
            return HookDispatcher.eventStop
        case HookDispatcher.eventNotification, "notification":
            return HookDispatcher.eventNotification
        case HookDispatcher.eventPermissionRequest, "permission_request", "permissionRequest":
            return HookDispatcher.eventPermissionRequest
        case HookDispatcher.eventPostToolUseFailure, "post_tool_use_failure", "postToolUseFailure":
            return HookDispatcher.eventPostToolUseFailure
        default:
            return raw
        }
    }

    public static func config(from entries: [HookEntry]) -> HookConfigFile {
        func groups(_ event: String) -> [HookMatcherGroup] {
            let rows = entries.filter {
                canonicalEventName($0.event) == event && $0.enabled
            }
            var matcherOrder: [String] = []
            var handlers: [String: [HookHandlerSpec]] = [:]
            var matcherValue: [String: String?] = [:]
            for row in rows {
                let key = normalizedMatcherKey(row.matcher)
                if handlers[key] == nil {
                    matcherOrder.append(key)
                    matcherValue[key] = normalizedMatcher(row.matcher)
                }
                let timeout: TimeInterval
                if let t = row.timeoutSeconds {
                    timeout = TimeInterval(t)
                } else {
                    timeout = HookDispatcher.defaultTimeoutSeconds
                }
                let idx = handlers[key, default: []].count
                handlers[key, default: []].append(
                    HookHandlerSpec(
                        type: "command",
                        command: row.command,
                        timeoutSeconds: timeout,
                        name: "command-\(idx)"
                    )
                )
            }
            return matcherOrder.compactMap { key in
                guard let list = handlers[key], !list.isEmpty else { return nil }
                return HookMatcherGroup(matcher: matcherValue[key] ?? nil, handlers: list)
            }
        }
        return HookConfigFile(
            pre: groups(HookDispatcher.eventPreToolUse),
            post: groups(HookDispatcher.eventPostToolUse),
            sessionStart: groups(HookDispatcher.eventSessionStart),
            userPromptSubmit: groups(HookDispatcher.eventUserPromptSubmit),
            stop: groups(HookDispatcher.eventStop),
            notification: groups(HookDispatcher.eventNotification),
            permissionRequest: groups(HookDispatcher.eventPermissionRequest),
            postToolUseFailure: groups(HookDispatcher.eventPostToolUseFailure)
        )
    }

    public static func entries(from config: HookConfigFile) -> [HookEntry] {
        func flatten(_ event: String, _ groups: [HookMatcherGroup]) -> [HookEntry] {
            groups.flatMap { group in
                group.handlers.map { handler in
                    let timeout = Int(handler.timeoutSeconds.rounded())
                    return HookEntry(
                        event: event,
                        matcher: normalizedMatcher(group.matcher),
                        command: handler.command,
                        args: [],
                        timeoutSeconds: timeout,
                        background: false,
                        enabled: true
                    )
                }
            }
        }
        return flatten(HookDispatcher.eventPreToolUse, config.pre)
            + flatten(HookDispatcher.eventPostToolUse, config.post)
            + flatten(HookDispatcher.eventSessionStart, config.sessionStart)
            + flatten(HookDispatcher.eventUserPromptSubmit, config.userPromptSubmit)
            + flatten(HookDispatcher.eventStop, config.stop)
            + flatten(HookDispatcher.eventNotification, config.notification)
            + flatten(HookDispatcher.eventPermissionRequest, config.permissionRequest)
            + flatten(HookDispatcher.eventPostToolUseFailure, config.postToolUseFailure)
    }

    // MARK: - File IO

    static func loadEntries(from url: URL) -> [HookEntry] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return parseEntries(from: obj)
    }

    static func saveEntries(_ entries: [HookEntry], to url: URL) throws {
        let written = encodeEntriesObject(entries)
        let merged = mergePreservingUnknown(
            existingURL: url,
            incoming: written,
            preserveUnknownHookEvents: false
        )
        try writePrettyJSON(merged, to: url)
    }

    static func writePrettyJSON(_ object: [String: Any], to url: URL) throws {
        let data = try prettyJSONData(object)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Parse / encode entries

    static func parseEntries(from obj: Any) -> [HookEntry] {
        guard let root = obj as? [String: Any] else { return [] }
        var entries: [HookEntry] = []
        entries.append(contentsOf: parseHookMap(hooksMap(from: root), defaultEnabled: true))
        if let disabled = root["disabledHooks"] as? [String: Any] {
            entries.append(contentsOf: parseHookMap(disabled, defaultEnabled: false))
        }
        return entries
    }

    private static func hooksMap(from root: [String: Any]) -> [String: Any] {
        if let nested = root["hooks"] as? [String: Any] {
            return nested
        }
        var flat: [String: Any] = [:]
        for key in root.keys {
            if isManagedTopLevelKey(key) && key != "hooks" && key != "disabledHooks" {
                if let value = root[key] {
                    flat[key] = value
                }
            }
        }
        return flat
    }

    private static func parseHookMap(_ map: [String: Any], defaultEnabled: Bool) -> [HookEntry] {
        var entries: [HookEntry] = []
        let keys = map.keys.sorted { lhs, rhs in
            let li = editorSortIndex(lhs)
            let ri = editorSortIndex(rhs)
            if li != ri { return li < ri }
            return lhs < rhs
        }
        for key in keys {
            let event = canonicalEventName(key)
            guard let groups = parseMatcherItems(map[key]) else { continue }
            for item in groups {
                for handler in item.handlers {
                    var row = handler
                    if !defaultEnabled { row.enabled = false }
                    row.event = event
                    row.matcher = item.matcher
                    entries.append(row)
                }
            }
        }
        return entries
    }

    private struct ParsedGroup {
        var matcher: String?
        var handlers: [HookEntry]
    }

    private static func parseMatcherItems(_ value: Any?) -> [ParsedGroup]? {
        guard let arr = value as? [Any] else { return nil }
        var groups: [ParsedGroup] = []
        for item in arr {
            guard let dict = item as? [String: Any] else { continue }
            if let hooksArr = dict["hooks"] as? [Any] {
                let matcher = normalizedMatcher(dict["matcher"] as? String)
                var handlers: [HookEntry] = []
                for h in hooksArr {
                    if let entry = parseHandlerEntry(h, matcher: matcher) {
                        handlers.append(entry)
                    }
                }
                if !handlers.isEmpty {
                    groups.append(ParsedGroup(matcher: matcher, handlers: handlers))
                }
                continue
            }
            if let entry = parseHandlerEntry(dict, matcher: normalizedMatcher(dict["matcher"] as? String)) {
                groups.append(ParsedGroup(matcher: entry.matcher, handlers: [entry]))
            }
        }
        return groups
    }

    private static func parseHandlerEntry(_ value: Any, matcher: String?) -> HookEntry? {
        guard let dict = value as? [String: Any] else { return nil }
        let type = (dict["type"] as? String)?.lowercased() ?? "command"
        guard type == "command" else { return nil }
        guard let command = dict["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let args: [String]
        if let raw = dict["args"] as? [String] {
            args = raw
        } else if let raw = dict["args"] as? [Any] {
            args = raw.compactMap { $0 as? String }
        } else {
            args = []
        }

        let timeout = intValue(dict["timeout"])
            ?? intValue(dict["timeoutSeconds"])
            ?? intValue(dict["timeout_seconds"])

        let background = boolValue(dict["async"]) || boolValue(dict["background"])
        let enabled = dict["enabled"] == nil ? true : boolValue(dict["enabled"])

        return HookEntry(
            event: "",
            matcher: matcher,
            command: command,
            args: args,
            timeoutSeconds: timeout,
            background: background,
            enabled: enabled
        )
    }

    private static func groupedHookObject(_ entries: [HookEntry]) -> [String: Any] {
        var eventOrder: [String] = []
        var byEvent: [String: [HookEntry]] = [:]
        for entry in entries {
            let event = canonicalEventName(entry.event)
            if byEvent[event] == nil { eventOrder.append(event) }
            byEvent[event, default: []].append(entry)
        }
        var hooks: [String: Any] = [:]
        for event in eventOrder {
            let rows = byEvent[event] ?? []
            var matcherOrder: [String] = []
            var handlers: [String: [[String: Any]]] = [:]
            var matcherValue: [String: String?] = [:]
            for row in rows {
                let key = normalizedMatcherKey(row.matcher)
                if handlers[key] == nil {
                    matcherOrder.append(key)
                    matcherValue[key] = normalizedMatcher(row.matcher)
                }
                if let encoded = encodeEntryHandler(row) {
                    handlers[key, default: []].append(encoded)
                }
            }
            var arr: [[String: Any]] = []
            for key in matcherOrder {
                let list = handlers[key] ?? []
                guard !list.isEmpty else { continue }
                var group: [String: Any] = ["hooks": list]
                if let matcher = matcherValue[key] ?? nil {
                    group["matcher"] = matcher
                }
                arr.append(group)
            }
            if !arr.isEmpty {
                hooks[event] = arr
            }
        }
        return hooks
    }

    private static func encodeEntryHandler(_ row: HookEntry) -> [String: Any]? {
        let command = row.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        var handler: [String: Any] = [
            "type": "command",
            "command": command,
        ]
        if !row.args.isEmpty { handler["args"] = row.args }
        if let timeout = row.timeoutSeconds { handler["timeout"] = timeout }
        if row.background { handler["async"] = true }
        if !row.enabled { handler["enabled"] = false }
        return handler
    }

    // MARK: - Merge / keys

    /// Keep unknown top-level keys (e.g. `$schema`). Drop flat event aliases
    /// after rewriting to nested `hooks`. Optionally keep extra event names
    /// already under `hooks` (HookConfigFile save has no slot for them).
    static func mergePreservingUnknown(
        existingURL: URL,
        incoming: [String: Any],
        preserveUnknownHookEvents: Bool
    ) -> [String: Any] {
        guard let data = try? Data(contentsOf: existingURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let existing = obj as? [String: Any]
        else { return incoming }

        var merged: [String: Any] = [:]
        for (key, value) in existing {
            if !isManagedTopLevelKey(key) {
                merged[key] = value
            }
        }
        for (key, value) in incoming {
            merged[key] = value
        }
        if incoming["disabledHooks"] == nil {
            merged.removeValue(forKey: "disabledHooks")
        }

        if preserveUnknownHookEvents,
           let existingHooks = existing["hooks"] as? [String: Any],
           var newHooks = incoming["hooks"] as? [String: Any] {
            for (key, value) in existingHooks {
                if !isKnownEventKey(key) && newHooks[key] == nil {
                    newHooks[key] = value
                }
            }
            merged["hooks"] = newHooks
        }
        return merged
    }

    private static func isManagedTopLevelKey(_ key: String) -> Bool {
        if key == "hooks" || key == "disabledHooks" { return true }
        return isKnownEventKey(key)
    }

    private static func isKnownEventKey(_ key: String) -> Bool {
        let canon = canonicalEventName(key)
        switch canon {
        case HookDispatcher.eventPreToolUse,
             HookDispatcher.eventPostToolUse,
             HookDispatcher.eventSessionStart,
             HookDispatcher.eventUserPromptSubmit,
             HookDispatcher.eventStop,
             HookDispatcher.eventNotification,
             HookDispatcher.eventPermissionRequest,
             HookDispatcher.eventPostToolUseFailure:
            return canon != key || knownEventNames.contains(key)
        default:
            return false
        }
    }

    private static let knownEventNames: Set<String> = [
        HookDispatcher.eventPreToolUse, "pre_tool_use", "pre", "preToolUse",
        HookDispatcher.eventPostToolUse, "post_tool_use", "post", "postToolUse",
        HookDispatcher.eventSessionStart, "session_start", "sessionStart",
        HookDispatcher.eventUserPromptSubmit, "user_prompt_submit",
        "userPromptSubmit", "beforeSubmitPrompt",
        HookDispatcher.eventStop, "stop",
        HookDispatcher.eventNotification, "notification",
        HookDispatcher.eventPermissionRequest, "permission_request", "permissionRequest",
        HookDispatcher.eventPostToolUseFailure, "post_tool_use_failure", "postToolUseFailure",
    ]

    private static func editorSortIndex(_ key: String) -> Int {
        let name = canonicalEventName(key)
        if let idx = editorEvents.firstIndex(of: name) { return idx }
        if name == HookDispatcher.eventNotification { return editorEvents.count }
        return editorEvents.count + 1
    }

    private static func normalizedMatcher(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func normalizedMatcherKey(_ raw: String?) -> String {
        normalizedMatcher(raw) ?? ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String, let n = Int(s) { return n }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            default: return false
            }
        }
        return false
    }
}

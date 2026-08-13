//
//  HookDispatcher.swift
//  File-based hooks (Grok / Claude Code–style v1 tools + v2 lifecycle).
//
//  Discovery (first existing dir wins):
//    <project>/.vibecoder/hooks/
//    <project>/.grok/hooks/
//
//  Layers (pre-tool, first deny wins):
//    1. deny-tools.txt — exact tool name or `*` per line (# comments)
//    2. Command runners from hooks.json / config.json
//
//  Events:
//    Tool: PreToolUse / PostToolUse
//    Lifecycle (v2): SessionStart, UserPromptSubmit, Stop, Notification
//
//  Nested (Claude/Grok-compatible keys):
//    {
//      "hooks": {
//        "PreToolUse":  [{ "matcher": "run_shell", "hooks": [{ "type": "command", "command": "block.sh" }] }],
//        "PostToolUse": [{ "matcher": "edit_file",  "hooks": [{ "type": "command", "command": "lint.sh" }] }],
//        "SessionStart": [{ "hooks": [{ "type": "command", "command": "setup.sh" }] }],
//        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "guard.sh" }] }],
//        "Stop": [{ "hooks": [{ "type": "command", "command": "notify.sh" }] }],
//        "Notification": [{ "matcher": "idle_prompt", "hooks": [{ "type": "command", "command": "n.sh" }] }]
//      }
//    }
//
//  Flat tool keys still work: { "pre": [...], "post": [...] }
//  Flat lifecycle aliases: session_start / user_prompt_submit / stop / notification
//
//  Command protocol:
//    - stdin: JSON envelope { tool_name?, hook_event_name, phase, payload, cwd, … }
//    - env: VIBECODER_PROJECT_DIR, CLAUDE_PROJECT_DIR, GROK_WORKSPACE_ROOT,
//           VIBECODER_HOOK_EVENT, VIBECODER_HOOK_TOOL, VIBECODER_HOOK_NAME
//    - exit 0 + empty stdout → allow (no decision)
//    - exit 2 → deny (stderr/stdout as reason) — blocks tool or turn when wired
//    - stdout JSON: { "decision": "allow"|"deny", "reason": "..." }
//      or Claude-style hookSpecificOutput.permissionDecision
//    - spawn/timeout/parse failures → fail-open (allow) + log
//

import Foundation

// MARK: - Concurrent pipe capture (Swift 6)

/// Thread-safe Data accumulator for process pipe readability handlers.
/// Handlers run concurrently; locals cannot be mutated from those closures.
private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if storage.count < limit {
            storage.append(chunk.prefix(limit - storage.count))
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Public types

public struct HookEvent: Sendable, Equatable {
    public var toolName: String
    public var phase: Phase
    public var payload: String
    public enum Phase: String, Sendable { case pre, post }
    public init(toolName: String, phase: Phase, payload: String) {
        self.toolName = toolName
        self.phase = phase
        self.payload = payload
    }
}

public struct HookDecision: Sendable, Equatable {
    public var allow: Bool
    public var message: String?
    public static let allow = HookDecision(allow: true, message: nil)
    public static func deny(_ msg: String) -> HookDecision {
        HookDecision(allow: false, message: msg)
    }
    public static func allowWithMessage(_ msg: String) -> HookDecision {
        HookDecision(allow: true, message: msg)
    }
}

// MARK: - Config models (internal)

struct HookHandlerSpec: Equatable {
    var type: String
    var command: String
    /// Timeout in seconds (default 5).
    var timeoutSeconds: TimeInterval
    var name: String
}

struct HookMatcherGroup: Equatable {
    /// Tool-name matcher: empty/`*` = all; `a|b` exact alternatives; else unanchored regex.
    var matcher: String?
    var handlers: [HookHandlerSpec]
}

struct HookConfigFile: Equatable {
    var pre: [HookMatcherGroup]
    var post: [HookMatcherGroup]
    /// v2 lifecycle (Claude/Grok nested keys).
    var sessionStart: [HookMatcherGroup]
    var userPromptSubmit: [HookMatcherGroup]
    var stop: [HookMatcherGroup]
    var notification: [HookMatcherGroup]

    static let empty = HookConfigFile(
        pre: [], post: [],
        sessionStart: [], userPromptSubmit: [], stop: [], notification: []
    )
}

// MARK: - Dispatcher

public enum HookDispatcher {

    public static let defaultTimeoutSeconds: TimeInterval = 5
    /// Exit code that means explicit deny (Claude/Grok convention).
    public static let denyExitCode = 2
    /// Max stdout/stderr bytes retained for decision parsing.
    public static let maxCaptureBytes = 64 * 1024

    // MARK: Discovery

    /// Serializes hook log writes (batch tool dispatch can race appendLog).
    private static let logLock = NSLock()

    /// Returns an existing hooks directory, or nil when none is configured.
    /// Does **not** create `.vibecoder/hooks` — logging only writes after a
    /// real hooks dir already exists (avoids polluting every project on the
    /// first tool call).
    ///
    /// Search order (first hit wins):
    /// 1. `projectRoot` — repo security policy (deny-tools / hooks.json)
    /// 2. `worktreeRoot` — session-local hooks when project has none
    public static func hooksDir(projectRoot: URL?, worktreeRoot: URL? = nil) -> URL? {
        for root in [projectRoot, worktreeRoot].compactMap({ $0 }) {
            if let dir = existingHooksDir(under: root) { return dir }
        }
        return nil
    }

    private static func existingHooksDir(under root: URL) -> URL? {
        let a = root.appendingPathComponent(".vibecoder/hooks", isDirectory: true)
        if FileManager.default.fileExists(atPath: a.path) { return a }
        let b = root.appendingPathComponent(".grok/hooks", isDirectory: true)
        if FileManager.default.fileExists(atPath: b.path) { return b }
        return nil
    }

    /// Resolve config path if present under hooks dir.
    public static func configURL(hooksDir: URL) -> URL? {
        let names = ["hooks.json", "config.json"]
        for name in names {
            let url = hooksDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Pre / Post

    /// Pre-tool: deny-tools.txt then matching command runners. First deny wins.
    public static func preTool(
        toolName: String,
        argumentsSummary: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil
    ) -> HookDecision {
        guard let dir = hooksDir(projectRoot: projectRoot, worktreeRoot: worktreeRoot) else {
            return .allow
        }

        if let deny = denyToolsDecision(toolName: toolName, hooksDir: dir) {
            appendLog(hooksDir: dir, phase: "pre", line: "deny-tools \(toolName)")
            return deny
        }

        appendLog(
            hooksDir: dir,
            phase: "pre",
            line: "\(toolName) \(argumentsSummary.prefix(120))"
        )

        let cwd = worktreeRoot ?? projectRoot ?? dir.deletingLastPathComponent()
        let config = loadConfig(hooksDir: dir)
        for group in config.pre where matcherMatches(group.matcher, toolName: toolName) {
            for handler in group.handlers {
                let decision = runHandler(
                    handler,
                    eventName: "PreToolUse",
                    toolName: toolName,
                    payload: argumentsSummary,
                    hooksDir: dir,
                    cwd: cwd
                )
                if !decision.allow {
                    appendLog(
                        hooksDir: dir,
                        phase: "pre",
                        line: "command-deny \(handler.name) \(toolName): \(decision.message ?? "")"
                    )
                    return decision
                }
            }
        }
        return .allow
    }

    /// Post-tool: observability log + command runners. Explicit deny can flag the result.
    @discardableResult
    public static func postTool(
        toolName: String,
        resultSummary: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil
    ) -> HookDecision {
        guard let dir = hooksDir(projectRoot: projectRoot, worktreeRoot: worktreeRoot) else {
            return .allow
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        appendLog(
            hooksDir: dir,
            phase: "post",
            line: "\(toolName) \(resultSummary.prefix(160))"
        )

        let cwd = worktreeRoot ?? projectRoot ?? dir.deletingLastPathComponent()
        let config = loadConfig(hooksDir: dir)
        var lastMessage: String?
        for group in config.post where matcherMatches(group.matcher, toolName: toolName) {
            for handler in group.handlers {
                let decision = runHandler(
                    handler,
                    eventName: "PostToolUse",
                    toolName: toolName,
                    payload: resultSummary,
                    hooksDir: dir,
                    cwd: cwd
                )
                if let msg = decision.message, !msg.isEmpty {
                    lastMessage = msg
                }
                if !decision.allow {
                    appendLog(
                        hooksDir: dir,
                        phase: "post",
                        line: "command-deny \(handler.name) \(toolName): \(decision.message ?? "")"
                    )
                    return decision
                }
            }
        }
        if let lastMessage {
            return .allowWithMessage(lastMessage)
        }
        return .allow
    }

    // MARK: Lifecycle (v2)

    /// Session start (first turn of a conversation, or explicit caller).
    /// Deny blocks the turn when the call site honors the decision.
    @discardableResult
    public static func sessionStart(
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        payload: String = ""
    ) -> HookDecision {
        runLifecycle(
            eventName: "SessionStart",
            groups: { $0.sessionStart },
            payload: payload,
            subject: "*",
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            logPhase: "session_start"
        )
    }

    /// User submitted a prompt. Deny can block the turn (wire in App / PB2).
    @discardableResult
    public static func userPromptSubmit(
        prompt: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil
    ) -> HookDecision {
        runLifecycle(
            eventName: "UserPromptSubmit",
            groups: { $0.userPromptSubmit },
            payload: prompt,
            subject: "*",
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            logPhase: "user_prompt_submit",
            extraEnvelope: [
                "prompt": String(prompt.prefix(8_000))
            ]
        )
    }

    /// Agent turn ended (completed, cancelled, cap, error reason string).
    /// Deny is recorded but typically non-blocking after the turn has finished.
    @discardableResult
    public static func stop(
        reason: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil
    ) -> HookDecision {
        runLifecycle(
            eventName: "Stop",
            groups: { $0.stop },
            payload: reason,
            subject: reason,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            logPhase: "stop",
            extraEnvelope: [
                "reason": String(reason.prefix(2_000))
            ]
        )
    }

    /// Optional notification hook (matcher against notification type).
    @discardableResult
    public static func notification(
        type: String,
        message: String = "",
        projectRoot: URL?,
        worktreeRoot: URL? = nil
    ) -> HookDecision {
        runLifecycle(
            eventName: "Notification",
            groups: { $0.notification },
            payload: message.isEmpty ? type : "\(type): \(message)",
            subject: type,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            logPhase: "notification",
            extraEnvelope: [
                "notification_type": type,
                "message": String(message.prefix(2_000))
            ]
        )
    }

    /// Shared lifecycle runner: first deny wins; fail-open on spawn/timeout.
    static func runLifecycle(
        eventName: String,
        groups: (HookConfigFile) -> [HookMatcherGroup],
        payload: String,
        subject: String,
        projectRoot: URL?,
        worktreeRoot: URL?,
        logPhase: String,
        extraEnvelope: [String: Any] = [:]
    ) -> HookDecision {
        guard let dir = hooksDir(projectRoot: projectRoot, worktreeRoot: worktreeRoot) else {
            return .allow
        }
        appendLog(
            hooksDir: dir,
            phase: logPhase,
            line: "\(eventName) \(payload.prefix(160))"
        )
        let cwd = worktreeRoot ?? projectRoot ?? dir.deletingLastPathComponent()
        let config = loadConfig(hooksDir: dir)
        let matched = groups(config)
        for group in matched where matcherMatches(group.matcher, toolName: subject) {
            for handler in group.handlers {
                let decision = runHandler(
                    handler,
                    eventName: eventName,
                    toolName: "",
                    payload: payload,
                    hooksDir: dir,
                    cwd: cwd,
                    extraEnvelope: extraEnvelope
                )
                if !decision.allow {
                    appendLog(
                        hooksDir: dir,
                        phase: logPhase,
                        line: "command-deny \(handler.name) \(eventName): \(decision.message ?? "")"
                    )
                    return decision
                }
            }
        }
        return .allow
    }

    // MARK: deny-tools.txt

    static func denyToolsDecision(toolName: String, hooksDir: URL) -> HookDecision? {
        let denyFile = hooksDir.appendingPathComponent("deny-tools.txt")
        guard let text = try? String(contentsOf: denyFile, encoding: .utf8) else { return nil }
        // Normalize CRLF/CR so Windows-edited deny lists still match.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n") {
            var name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.hasPrefix("#") { continue }
            // Inline comments: `run_shell  # never auto`
            if let hash = name.firstIndex(of: "#") {
                name = String(name[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name.isEmpty { continue }
            if name == toolName || name == "*" {
                return .deny("Denied by project hook deny-tools.txt: \(toolName)")
            }
        }
        return nil
    }

    // MARK: Config load / parse

    static func loadConfig(hooksDir: URL) -> HookConfigFile {
        guard let url = configURL(hooksDir: hooksDir),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else {
            return .empty
        }
        return parseConfigJSON(obj)
    }

    /// Parse flat or nested hook config. Invalid structure → empty (fail-open).
    static func parseConfigJSON(_ obj: Any) -> HookConfigFile {
        guard let root = obj as? [String: Any] else {
            return .empty
        }

        // Nested: { "hooks": { "PreToolUse": [...], "SessionStart": [...], ... } }
        if let hooks = root["hooks"] as? [String: Any] {
            return HookConfigFile(
                pre: parseMatcherGroups(hooks["PreToolUse"] ?? hooks["pre_tool_use"] ?? hooks["pre"]),
                post: parseMatcherGroups(hooks["PostToolUse"] ?? hooks["post_tool_use"] ?? hooks["post"]),
                sessionStart: parseMatcherGroups(
                    hooks["SessionStart"] ?? hooks["session_start"] ?? hooks["sessionStart"]),
                userPromptSubmit: parseMatcherGroups(
                    hooks["UserPromptSubmit"]
                        ?? hooks["user_prompt_submit"]
                        ?? hooks["userPromptSubmit"]
                        ?? hooks["beforeSubmitPrompt"]),
                stop: parseMatcherGroups(hooks["Stop"] ?? hooks["stop"]),
                notification: parseMatcherGroups(
                    hooks["Notification"] ?? hooks["notification"])
            )
        }

        // Flat: { "pre": [...], "post": [...], "session_start": [...], ... }
        return HookConfigFile(
            pre: parseMatcherGroups(root["pre"] ?? root["PreToolUse"]),
            post: parseMatcherGroups(root["post"] ?? root["PostToolUse"]),
            sessionStart: parseMatcherGroups(
                root["session_start"] ?? root["SessionStart"] ?? root["sessionStart"]),
            userPromptSubmit: parseMatcherGroups(
                root["user_prompt_submit"]
                    ?? root["UserPromptSubmit"]
                    ?? root["userPromptSubmit"]
                    ?? root["beforeSubmitPrompt"]),
            stop: parseMatcherGroups(root["stop"] ?? root["Stop"]),
            notification: parseMatcherGroups(root["notification"] ?? root["Notification"])
        )
    }

    /// Accepts either matcher groups `[{matcher, hooks:[...]}]` or flat handler list
    /// `[{matcher, type, command, ...}]`.
    static func parseMatcherGroups(_ value: Any?) -> [HookMatcherGroup] {
        guard let arr = value as? [Any] else { return [] }
        var groups: [HookMatcherGroup] = []

        for item in arr {
            guard let dict = item as? [String: Any] else { continue }

            // Nested group with hooks array
            if let hooksArr = dict["hooks"] as? [Any] {
                let matcher = dict["matcher"] as? String
                var handlers: [HookHandlerSpec] = []
                for (idx, h) in hooksArr.enumerated() {
                    if let spec = parseHandler(h, index: idx, fallbackMatcher: matcher) {
                        handlers.append(spec)
                    }
                }
                if !handlers.isEmpty {
                    groups.append(HookMatcherGroup(matcher: matcher, handlers: handlers))
                }
                continue
            }

            // Flat handler with optional matcher on the same object
            if let spec = parseHandler(dict, index: groups.count, fallbackMatcher: nil) {
                let matcher = dict["matcher"] as? String
                groups.append(HookMatcherGroup(matcher: matcher, handlers: [spec]))
            }
        }
        return groups
    }

    static func parseHandler(_ value: Any, index: Int, fallbackMatcher: String?) -> HookHandlerSpec? {
        guard let dict = value as? [String: Any] else { return nil }
        let type = (dict["type"] as? String)?.lowercased() ?? "command"
        // v1: command only (http deferred)
        guard type == "command" else { return nil }
        guard let command = dict["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let timeout: TimeInterval
        if let t = dict["timeout"] as? Double {
            timeout = t
        } else if let t = dict["timeout"] as? Int {
            timeout = TimeInterval(t)
        } else if let t = dict["timeout"] as? String, let d = Double(t) {
            timeout = d
        } else if let t = dict["timeoutSeconds"] as? Double {
            timeout = t
        } else if let t = dict["timeout_seconds"] as? Int {
            timeout = TimeInterval(t)
        } else if let t = dict["timeoutSeconds"] as? String, let d = Double(t) {
            timeout = d
        } else {
            timeout = defaultTimeoutSeconds
        }

        let name = (dict["name"] as? String)
            ?? "command-\(index)"
        return HookHandlerSpec(
            type: type,
            command: command,
            timeoutSeconds: max(0.5, timeout),
            name: name
        )
    }

    // MARK: Matcher

    /// Match tool names. Empty / `*` / absent → all. Pipe list → exact. Else regex unanchored.
    static func matcherMatches(_ matcher: String?, toolName: String) -> Bool {
        guard let raw = matcher?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "*"
        else { return true }

        // Exact multi: "run_shell|edit_file" (only safe chars → split, not regex)
        let exactSafe = raw.unicodeScalars.allSatisfy { c in
            CharacterSet.alphanumerics.contains(c)
                || c == "_" || c == "-" || c == "|" || c == " " || c == ","
        }
        if exactSafe && (raw.contains("|") || raw.contains(",")) {
            let parts = raw.split { $0 == "|" || $0 == "," }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.contains(toolName)
        }
        if exactSafe && !raw.contains("|") && !raw.contains(",") {
            return raw == toolName
        }

        // Regex path
        guard let re = try? NSRegularExpression(pattern: raw, options: []) else {
            return raw == toolName
        }
        let range = NSRange(toolName.startIndex..<toolName.endIndex, in: toolName)
        return re.firstMatch(in: toolName, options: [], range: range) != nil
    }

    // MARK: Command runner

    static func runHandler(
        _ handler: HookHandlerSpec,
        eventName: String,
        toolName: String,
        payload: String,
        hooksDir: URL,
        cwd: URL,
        extraEnvelope: [String: Any] = [:]
    ) -> HookDecision {
        guard handler.type == "command" else { return .allow }

        let phaseLabel: String
        switch eventName {
        case "PreToolUse": phaseLabel = "pre"
        case "PostToolUse": phaseLabel = "post"
        default: phaseLabel = eventName
        }

        var envelope: [String: Any] = [
            "tool_name": toolName,
            "hook_event_name": eventName,
            "phase": phaseLabel,
            "payload": String(payload.prefix(8_000)),
            "arguments_summary": eventName == "PreToolUse" ? String(payload.prefix(8_000)) : "",
            "result_summary": eventName == "PostToolUse" ? String(payload.prefix(8_000)) : "",
            "cwd": cwd.path,
        ]
        for (k, v) in extraEnvelope {
            envelope[k] = v
        }
        guard let stdinData = try? JSONSerialization.data(withJSONObject: envelope) else {
            return .allow
        }

        let result = runCommand(
            handler.command,
            hooksDir: hooksDir,
            cwd: cwd,
            stdin: stdinData,
            timeoutSeconds: handler.timeoutSeconds,
            eventName: eventName,
            toolName: toolName,
            hookName: handler.name
        )

        switch result {
        case .failed(let err):
            appendLog(hooksDir: hooksDir, phase: phaseLabel, line: "command-fail \(handler.name): \(err)")
            return .allow // fail-open
        case .completed(let exitCode, let stdout, let stderr):
            return interpretCommandOutput(
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                hookName: handler.name,
                toolName: toolName.isEmpty ? eventName : toolName
            )
        }
    }

    enum CommandRunResult {
        case completed(exitCode: Int, stdout: String, stderr: String)
        case failed(String)
    }

    /// Split `command args…` into the executable token and the remainder.
    static func hookCommandHead(_ command: String) -> (head: String, rest: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return (trimmed, "")
        }
        let head = String(trimmed[..<split])
        let rest = String(trimmed[trimmed.index(after: split)...])
            .trimmingCharacters(in: .whitespaces)
        return (head, rest)
    }

    /// Single-quote a path for `sh -c`.
    static func quoteForShell(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Spawn a command hook. Relative paths resolve against hooksDir; shell metacharacters use `sh -c`.
    static func runCommand(
        _ command: String,
        hooksDir: URL,
        cwd: URL,
        stdin: Data,
        timeoutSeconds: TimeInterval,
        eventName: String,
        toolName: String,
        hookName: String
    ) -> CommandRunResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("empty command") }

        let process = Process()
        process.currentDirectoryURL = cwd

        var env = ProcessInfo.processInfo.environment
        env["VIBECODER_PROJECT_DIR"] = cwd.path
        env["CLAUDE_PROJECT_DIR"] = cwd.path
        env["GROK_WORKSPACE_ROOT"] = cwd.path
        env["VIBECODER_HOOK_EVENT"] = eventName
        env["GROK_HOOK_EVENT"] = eventName
        env["VIBECODER_HOOK_TOOL"] = toolName
        env["VIBECODER_HOOK_NAME"] = hookName
        env["GROK_HOOK_NAME"] = hookName

        let hasShellMeta = trimmed.contains("|")
            || trimmed.contains("&")
            || trimmed.contains(";")
            || trimmed.contains(">")
            || trimmed.contains("<")
            || trimmed.contains("$")
            || trimmed.hasPrefix("~")
        let needsShell = hasShellMeta || trimmed.contains(" ")

        // Relative first token (e.g. `deny-args.sh --strict`) must still
        // resolve against hooksDir — do not fail-open via PATH-only `sh -c`.
        let (head, rest) = Self.hookCommandHead(trimmed)
        let hooksResolved: String? = {
            guard !head.hasPrefix("/") else { return nil }
            let candidate = hooksDir.appendingPathComponent(head)
            if FileManager.default.isExecutableFile(atPath: candidate.path)
                || FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            return nil
        }()

        if needsShell {
            let hooksPath = hooksDir.path
            if let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = hooksPath + ":" + existing
            } else {
                env["PATH"] = hooksPath
            }
            var shellCommand = trimmed
            if let resolved = hooksResolved {
                let quoted = Self.quoteForShell(resolved)
                shellCommand = rest.isEmpty ? quoted : "\(quoted) \(rest)"
            }
            process.environment = env
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", shellCommand]
        } else {
            process.environment = env
            let path: String
            if trimmed.hasPrefix("/") {
                path = trimmed
            } else {
                path = hooksResolved ?? hooksDir.appendingPathComponent(trimmed).path
            }
            guard FileManager.default.isExecutableFile(atPath: path)
                    || FileManager.default.fileExists(atPath: path)
            else {
                return .failed("command not found: \(path)")
            }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = []
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failed("spawn failed: \(error.localizedDescription)")
        }

        // Drain pipes while the process runs so large stdout/stderr cannot
        // fill the OS pipe buffer and deadlock the child until timeout.
        // Use a Sendable box so readability handlers (concurrent) can mutate
        // capture buffers under Swift 6 strict concurrency.
        let outChunks = LockedDataBuffer(limit: maxCaptureBytes)
        let errChunks = LockedDataBuffer(limit: maxCaptureBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outChunks.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errChunks.append(chunk)
        }

        // Write stdin then close (best-effort if child exits early).
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try inPipe.fileHandleForWriting.close()
        } catch {
            // Child may have exited; still wait for reaping.
            try? inPipe.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            // Reap
            _ = group.wait(timeout: .now() + 1)
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failed("timed out after \(Int(timeoutSeconds))s")
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Collect any remaining buffered data after handlers stop.
        let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailOut.isEmpty { outChunks.append(tailOut) }
        if !tailErr.isEmpty { errChunks.append(tailErr) }
        let outData = outChunks.snapshot()
        let errData = errChunks.snapshot()

        let stdout = String(data: outData.prefix(maxCaptureBytes), encoding: .utf8) ?? ""
        let stderr = String(data: errData.prefix(maxCaptureBytes), encoding: .utf8) ?? ""
        let code = Int(process.terminationStatus)
        return .completed(exitCode: code, stdout: stdout, stderr: stderr)
    }

    /// Map process output to allow/deny.
    static func interpretCommandOutput(
        exitCode: Int,
        stdout: String,
        stderr: String,
        hookName: String,
        toolName: String
    ) -> HookDecision {
        // Explicit deny exit code (Claude/Grok).
        if exitCode == denyExitCode {
            let reason = firstNonEmpty(stdout, stderr)
                ?? "Denied by hook \(hookName) (exit \(denyExitCode))"
            return .deny(stripJSONNoise(reason) + " [hook:\(hookName) tool:\(toolName)]")
        }

        // Try JSON decision from stdout (and stderr as fallback).
        if let decision = parseDecisionJSON(stdout) ?? parseDecisionJSON(stderr) {
            return decision
        }

        // Non-zero other than 2 → fail-open (non-blocking error), keep optional message.
        if exitCode != 0 {
            let msg = firstNonEmpty(stderr, stdout)
            if let msg, !msg.isEmpty {
                return .allowWithMessage("hook \(hookName) exit \(exitCode): \(msg.prefix(200))")
            }
            return .allow
        }

        return .allow
    }

    /// Parse allow/deny from stdout JSON (Grok `decision` or Claude `permissionDecision`).
    /// Accepts pure JSON or a blob with leading/trailing log noise (extract first `{…}`).
    static func parseDecisionJSON(_ text: String) -> HookDecision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func object(from jsonText: String) -> [String: Any]? {
            guard let data = jsonText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        let obj: [String: Any]
        if let direct = object(from: trimmed) {
            obj = direct
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end,
                  let embedded = object(from: String(trimmed[start...end])) {
            obj = embedded
        } else {
            return nil
        }

        // Grok-style: { "decision": "deny"|"allow", "reason": "..." }
        if let decision = obj["decision"] as? String {
            let reason = obj["reason"] as? String
                ?? obj["message"] as? String
                ?? obj["permissionDecisionReason"] as? String
            if decision.lowercased() == "deny" || decision.lowercased() == "block" {
                return .deny(reason ?? "Denied by hook")
            }
            if decision.lowercased() == "allow" {
                return reason.map { .allowWithMessage($0) } ?? .allow
            }
        }

        // Claude-style nested:
        // { "hookSpecificOutput": { "permissionDecision": "deny", "permissionDecisionReason": "..." } }
        if let specific = obj["hookSpecificOutput"] as? [String: Any] {
            if let pd = specific["permissionDecision"] as? String {
                let reason = specific["permissionDecisionReason"] as? String
                    ?? specific["reason"] as? String
                switch pd.lowercased() {
                case "deny", "block":
                    return .deny(reason ?? "Denied by hook")
                case "allow":
                    return reason.map { .allowWithMessage($0) } ?? .allow
                default:
                    break
                }
            }
        }

        // Top-level permissionDecision
        if let pd = obj["permissionDecision"] as? String {
            let reason = obj["permissionDecisionReason"] as? String ?? obj["reason"] as? String
            if pd.lowercased() == "deny" || pd.lowercased() == "block" {
                return .deny(reason ?? "Denied by hook")
            }
        }

        return nil
    }

    // MARK: Logging

    static func appendLog(hooksDir: URL, phase: String, line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let logName: String
        switch phase {
        case "post": logName = "post-tool.log"
        case "pre": logName = "pre-tool.log"
        default: logName = "lifecycle.log"
        }
        let log = hooksDir.appendingPathComponent(logName)
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(phase) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: log.path),
           let h = try? FileHandle(forWritingTo: log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? entry.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    private static func firstNonEmpty(_ a: String, _ b: String) -> String? {
        let at = a.trimmingCharacters(in: .whitespacesAndNewlines)
        if !at.isEmpty { return at }
        let bt = b.trimmingCharacters(in: .whitespacesAndNewlines)
        return bt.isEmpty ? nil : bt
    }

    private static func stripJSONNoise(_ s: String) -> String {
        // If reason was a full JSON blob, try to extract human text.
        if let d = parseDecisionJSON(s), let msg = d.message, !msg.isEmpty {
            return msg
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

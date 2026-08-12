//
//  XcodeBuildTool.swift
//
//  Xcode-focused tool that turns raw `xcodebuild` output into agent-
//  friendly summaries. Exposes one tool with an `action` discriminator:
//
//    • build         — run `xcodebuild build`, summarise errors/warnings.
//    • test          — run `xcodebuild test`, summarise pass/fail counts.
//    • clean         — run `xcodebuild clean`.
//    • list_schemes  — `xcodebuild -list -json`, pretty-printed.
//    • get_log       — return the raw output of the most recent build/test.
//    • swift_check   — fast single-file typecheck via `xcrun swiftc -typecheck`.
//
//  Output is always capped so a chatty build log never floods the
//  context window.
//

import Foundation

public struct XcodeBuildTool: Tool {
    public static let name = "xcode_build"
    public static let category: ToolCategory = .build
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Run Xcode build/test commands and return summarised output. Actions:
          • build         — `xcodebuild build` with auto-located workspace/project.
          • test          — `xcodebuild test` with optional -only-testing filter.
          • clean         — `xcodebuild clean`.
          • list_schemes  — `xcodebuild -list -json`.
          • get_log       — raw output of the most recent build/test.
          • swift_check   — `xcrun swiftc -typecheck` against a single .swift file.
        """,
        parameters: .init(
            properties: [
                "action": .init(
                    type: "string",
                    description: "One of: build, test, clean, list_schemes, get_log, swift_check.",
                    enum: ["build", "test", "clean", "list_schemes", "get_log", "swift_check"]
                ),
                "scheme": .init(type: "string", description: "build/test/clean: xcodebuild -scheme value."),
                "configuration": .init(type: "string", description: "build: -configuration value (Debug/Release)."),
                "filter": .init(type: "string", description: "test: -only-testing filter, e.g. TargetTests/MyTests/testFoo."),
                "project_path": .init(type: "string", description: "Directory containing the .xcodeproj or .xcworkspace. Default project root."),
                "file": .init(type: "string", description: "swift_check: path to the .swift file to typecheck."),
                "tail_lines": .init(type: "integer", description: "get_log: return only the last N lines.")
            ],
            required: ["action"]
        )
    )

    private static let outputCap = 16_000

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let action = try arguments.string("action").lowercased()
        let base = context.workingDirectory
        switch action {
        case "build":
            return build(arguments: arguments, base: base)
        case "test":
            return runTests(arguments: arguments, base: base)
        case "clean":
            return clean(arguments: arguments, base: base)
        case "list_schemes":
            return listSchemes(arguments: arguments, base: base)
        case "get_log":
            return getLog(arguments: arguments)
        case "swift_check":
            return swiftCheck(arguments: arguments, base: base)
        default:
            return ToolResult(
                content: "Unknown action '\(action)'. Use build, test, clean, list_schemes, get_log, or swift_check.",
                isError: true
            )
        }
    }

    // MARK: - build

    private func build(arguments: ToolArguments, base: URL) -> ToolResult {
        let dir = resolveDir(arguments.stringOptional("project_path"), workingDirectory: base)
        var args: [String] = []
        if let workspace = Self.autoFind(extensionType: "xcworkspace", in: dir) {
            args.append(contentsOf: ["-workspace", workspace])
        } else if let project = Self.autoFind(extensionType: "xcodeproj", in: dir) {
            args.append(contentsOf: ["-project", project])
        } else {
            return ToolResult(content: "Error: no .xcodeproj or .xcworkspace found in \(dir).", isError: true)
        }
        if let s = arguments.stringOptional("scheme"), !s.isEmpty {
            args.append(contentsOf: ["-scheme", s])
        }
        if let c = arguments.stringOptional("configuration"), !c.isEmpty {
            args.append(contentsOf: ["-configuration", c])
        }
        args.append("build")

        let r = runXcodebuild(args: args, workingDirectory: URL(fileURLWithPath: dir), timeout: 240)
        let combined = combinedOutput(r)
        BuildLogCache.shared.store(combined)
        let succeeded = r.exitCode == 0
        return ToolResult(
            content: summariseBuild(output: combined, succeeded: succeeded),
            isError: !succeeded
        )
    }

    // MARK: - test

    private func runTests(arguments: ToolArguments, base: URL) -> ToolResult {
        let dir = resolveDir(arguments.stringOptional("project_path"), workingDirectory: base)
        var args: [String] = []
        if let workspace = Self.autoFind(extensionType: "xcworkspace", in: dir) {
            args.append(contentsOf: ["-workspace", workspace])
        } else if let project = Self.autoFind(extensionType: "xcodeproj", in: dir) {
            args.append(contentsOf: ["-project", project])
        } else {
            return ToolResult(content: "Error: no .xcodeproj or .xcworkspace found in \(dir).", isError: true)
        }
        if let s = arguments.stringOptional("scheme"), !s.isEmpty {
            args.append(contentsOf: ["-scheme", s])
        }
        args.append(contentsOf: ["-destination", "platform=macOS", "test"])
        if let f = arguments.stringOptional("filter"), !f.isEmpty {
            args.append("-only-testing:\(f)")
        }

        let r = runXcodebuild(args: args, workingDirectory: URL(fileURLWithPath: dir), timeout: 600)
        let combined = combinedOutput(r)
        BuildLogCache.shared.store(combined)
        let summary = summariseTestRun(output: combined)
        let hasFailures = summary.range(of: #"Failed:\s*[1-9]"#, options: .regularExpression) != nil
        return ToolResult(
            content: summary,
            isError: r.exitCode != 0 || hasFailures
        )
    }

    // MARK: - clean

    private func clean(arguments: ToolArguments, base: URL) -> ToolResult {
        let dir = resolveDir(arguments.stringOptional("project_path"), workingDirectory: base)
        var args: [String] = []
        if let workspace = Self.autoFind(extensionType: "xcworkspace", in: dir) {
            args.append(contentsOf: ["-workspace", workspace])
        } else if let project = Self.autoFind(extensionType: "xcodeproj", in: dir) {
            args.append(contentsOf: ["-project", project])
        } else {
            return ToolResult(content: "Error: no .xcodeproj or .xcworkspace found in \(dir).", isError: true)
        }
        if let s = arguments.stringOptional("scheme"), !s.isEmpty {
            args.append(contentsOf: ["-scheme", s])
        }
        args.append("clean")
        let r = runXcodebuild(args: args, workingDirectory: URL(fileURLWithPath: dir), timeout: 60)
        let combined = combinedOutput(r)
        if r.exitCode == 0 {
            return ToolResult(content: "xcodebuild clean OK.")
        }
        return ToolResult(content: "xcodebuild clean failed:\n" + truncate(combined, to: Self.outputCap), isError: true)
    }

    // MARK: - list_schemes

    private func listSchemes(arguments: ToolArguments, base: URL) -> ToolResult {
        let dir = resolveDir(arguments.stringOptional("project_path"), workingDirectory: base)
        let r = runXcodebuild(args: ["-list", "-json"], workingDirectory: URL(fileURLWithPath: dir), timeout: 30)
        guard r.exitCode == 0 else {
            return ToolResult(content: "Error listing schemes:\n" + r.stderr + r.stdout, isError: true)
        }
        if let data = r.stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            return ToolResult(content: s)
        }
        return ToolResult(content: r.stdout)
    }

    // MARK: - get_log

    private func getLog(arguments: ToolArguments) -> ToolResult {
        let (log, ts) = BuildLogCache.shared.snapshot()
        let header: String
        if let ts = ts {
            let elapsed = Int(Date().timeIntervalSince(ts))
            header = "[Last build: \(elapsed)s ago]\n\n"
        } else {
            header = ""
        }
        var body = log
        if let n = arguments.intOptional("tail_lines"), n > 0 {
            let lines = body.components(separatedBy: "\n")
            body = Array(lines.suffix(n)).joined(separator: "\n")
        }
        if body.utf8.count > Self.outputCap {
            body = truncate(body, to: Self.outputCap) + "\n\n[…truncated by output cap, pass `tail_lines` to scope.]"
        }
        return ToolResult(content: header + body)
    }

    // MARK: - swift_check

    private func swiftCheck(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let file = arguments.stringOptional("file"), !file.isEmpty else {
            return ToolResult(content: "Error: `file` is required for swift_check.", isError: true)
        }
        let p = resolvePath(file, base: base).path
        guard FileManager.default.fileExists(atPath: p) else {
            return ToolResult(content: "Error: file not found at \(p).", isError: true)
        }
        let r = ShellRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["swiftc", "-typecheck", p],
            timeout: 60
        )
        let combined = combinedOutput(r).trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return ToolResult(content: "swift_check passed: \(p) — no diagnostics.")
        }
        var errors = 0
        var warnings = 0
        for line in combined.split(separator: "\n") {
            if line.contains(": error:") { errors += 1 }
            else if line.contains(": warning:") { warnings += 1 }
        }
        let header = "swift_check \(p) — \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")"
        let body = truncate(combined, to: Self.outputCap)
        return ToolResult(content: "\(header)\n\n\(body)", isError: errors > 0)
    }

    // MARK: - Helpers

    private func runXcodebuild(args: [String], workingDirectory: URL, timeout: TimeInterval) -> ShellResult {
        // Prefer /usr/bin/xcodebuild; if absent, fall back to running through xcrun.
        if FileManager.default.fileExists(atPath: "/usr/bin/xcodebuild") {
            return ShellRunner.run(
                executable: "/usr/bin/xcodebuild",
                arguments: args,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        }
        return ShellRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcodebuild"] + args,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    private func combinedOutput(_ r: ShellResult) -> String {
        if r.stderr.isEmpty { return r.stdout }
        if r.stdout.isEmpty { return r.stderr }
        return r.stdout + "\n" + r.stderr
    }

    private func truncate(_ s: String, to maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        return String(s.prefix(maxBytes)) + "\n[…truncated]"
    }

    private func resolveDir(_ path: String?, workingDirectory: URL) -> String {
        guard let p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else {
            return workingDirectory.path
        }
        if p.hasPrefix("/") { return (p as NSString).expandingTildeInPath }
        return workingDirectory.appendingPathComponent(p).path
    }

    private static func autoFind(extensionType: String, in dir: String) -> String? {
        // Shallow pass first (fast path — covers projects at the root)
        if let found = shallowFind(extensionType: extensionType, in: dir) { return found }
        // One level deeper — covers the common layout where the project
        // lives in a named subdirectory (e.g. ~/Projects/MyApp/MyApp.xcodeproj)
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for sub in subdirs {
            let subPath = (dir as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            if let found = shallowFind(extensionType: extensionType, in: subPath) { return found }
        }
        return nil
    }

    private static func shallowFind(extensionType: String, in dir: String) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        guard let match = contents.first(where: { $0.hasSuffix(".\(extensionType)") }) else { return nil }
        return (dir as NSString).appendingPathComponent(match)
    }

    // MARK: - Output summarisation

    private func summariseBuild(output: String, succeeded: Bool) -> String {
        var errorLines: [String] = []
        var warningLines: [String] = []
        for line in output.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.contains(": error:") || l.hasPrefix("error:") || l.hasPrefix("** BUILD FAILED **") {
                errorLines.append(l)
            } else if l.contains(": warning:") {
                warningLines.append(l)
            } else if l.hasPrefix("** BUILD SUCCEEDED **") {
                errorLines.append(l)
            }
        }
        var header = succeeded && errorLines.first(where: { $0.contains("FAILED") }) == nil
            ? "Build SUCCEEDED."
            : "Build FAILED."
        header += " (\(errorLines.count) error\(errorLines.count == 1 ? "" : "s"), \(warningLines.count) warning\(warningLines.count == 1 ? "" : "s"))"

        var body = ""
        if !errorLines.isEmpty {
            body += "\n\n## Errors\n" + errorLines.prefix(40).joined(separator: "\n")
        }
        if !warningLines.isEmpty {
            body += "\n\n## Warnings (first 20)\n" + warningLines.prefix(20).joined(separator: "\n")
        }
        if errorLines.isEmpty && warningLines.isEmpty && !succeeded {
            let tail = output.split(separator: "\n").suffix(40).joined(separator: "\n")
            body += "\n\n## Raw output (tail)\n" + tail
        }
        return truncate(header + body, to: Self.outputCap)
    }

    private func summariseTestRun(output: String) -> String {
        var passed = 0
        var failed = 0
        var failures: [String] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: "Test Case '.*' passed", options: .regularExpression) != nil {
                passed += 1
            } else if line.range(of: "Test Case '.*' failed", options: .regularExpression) != nil {
                failed += 1
                failures.append(line)
            } else if line.contains(": error:") && line.lowercased().contains("test") {
                failures.append(line)
            }
        }
        let header: String
        if failed == 0 && passed > 0 {
            header = "Tests PASSED — \(passed) test\(passed == 1 ? "" : "s")."
        } else if failed > 0 {
            header = "Tests FAILED — \(passed) passed, \(failed) failed."
        } else {
            header = "No tests detected. Output (tail) follows."
        }
        var body = ""
        if !failures.isEmpty {
            body += "\n\n## Failures\n" + failures.prefix(30).joined(separator: "\n")
        } else if passed == 0 {
            let tail = output.components(separatedBy: "\n").suffix(30).joined(separator: "\n")
            body += "\n\n## Output (tail)\n" + tail
        }
        return truncate(header + body, to: Self.outputCap)
    }
}

// MARK: - BuildLogCache
//
// Process-wide cache of the most recent build/test output so the
// `get_log` sub-action can return the raw text after the summary. Cheaper
// and more accurate than decoding the proprietary `.xcactivitylog`
// SLF0+gzip format on disk. Guarded by NSLock so it is safe to mutate
// from arbitrary executors.

private final class BuildLogCache: @unchecked Sendable {
    static let shared = BuildLogCache()

    private let lock = NSLock()
    private var log: String = "(no build has run in this session yet — run `xcode_build` with action=build first)"
    private var timestamp: Date? = nil

    func store(_ output: String) {
        lock.lock()
        defer { lock.unlock() }
        log = output
        timestamp = Date()
    }

    func snapshot() -> (String, Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (log, timestamp)
    }
}

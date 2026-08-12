//
//  BuildGuard.swift
//
//  Runs after any agent turn that mutated files. Detects the project
//  type and runs the right build/compile invocation. Failed builds
//  short-circuit the loop with the compiler error injected back as a
//  tool result; the model gets to fix it on the next turn.
//
//  This is the structural change vs. the original AgentOS, where build
//  verification was a soft nudge in the system prompt that the model
//  could ignore.
//

import Foundation

public enum BuildGuard {

    public enum Outcome: Sendable {
        case noBuildSystem        // not a buildable project (just text files, docs, etc.)
        case passed
        case failed(log: String)
    }

    // Project-type detection result, cached per working-directory path.
    // The project type cannot change during an agent run (the agent isn't
    // adding a Package.swift mid-session), so we pay the directory-scan
    // cost at most once per directory across all `verify` calls.
    private enum ProjectKind: Sendable {
        case swiftPackage
        case xcodeWorkspace(URL)
        case xcodeProject(URL)
        case cargo
        case npm
        case none
    }
    // `verify` runs from the AgentLoop actor across concurrent
    // conversations, so this cache is touched from multiple tasks. A bare
    // `static var` dictionary is a data race (concurrent dict writes can
    // crash, not just warn under Swift 6). Guard every access with a lock;
    // `nonisolated(unsafe)` tells the compiler the lock is the safety
    // mechanism. Capped so a long-lived app exploring many project dirs
    // can't grow it without bound.
    private static let _kindCacheLock = NSLock()
    nonisolated(unsafe) private static var _kindCache: [String: ProjectKind] = [:]
    private static let _kindCacheCap = 64

    private static func cachedKind(forKey key: String) -> ProjectKind? {
        _kindCacheLock.lock(); defer { _kindCacheLock.unlock() }
        return _kindCache[key]
    }

    private static func storeKind(_ kind: ProjectKind, forKey key: String) {
        _kindCacheLock.lock(); defer { _kindCacheLock.unlock() }
        if _kindCache.count >= _kindCacheCap { _kindCache.removeAll(keepingCapacity: true) }
        _kindCache[key] = kind
    }

    private static func detectKind(at dir: URL) -> ProjectKind {
        let key = dir.path
        if let cached = cachedKind(forKey: key) { return cached }
        let fm = FileManager.default
        let kind: ProjectKind
        if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            kind = .swiftPackage
        } else if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            if let ws = contents.first(where: { $0.pathExtension == "xcworkspace" }) {
                kind = .xcodeWorkspace(ws)
            } else if let proj = contents.first(where: { $0.pathExtension == "xcodeproj" }) {
                kind = .xcodeProject(proj)
            } else if fm.fileExists(atPath: dir.appendingPathComponent("Cargo.toml").path) {
                kind = .cargo
            } else if fm.fileExists(atPath: dir.appendingPathComponent("package.json").path),
                      fm.fileExists(atPath: dir.appendingPathComponent("tsconfig.json").path) {
                kind = .npm
            } else {
                kind = .none
            }
        } else if fm.fileExists(atPath: dir.appendingPathComponent("Cargo.toml").path) {
            kind = .cargo
        } else if fm.fileExists(atPath: dir.appendingPathComponent("package.json").path),
                  fm.fileExists(atPath: dir.appendingPathComponent("tsconfig.json").path) {
            kind = .npm
        } else {
            kind = .none
        }
        storeKind(kind, forKey: key)
        return kind
    }

    public static func verify(at workingDirectory: URL) async -> Outcome {
        switch detectKind(at: workingDirectory) {
        case .swiftPackage:
            return runSwiftBuild(at: workingDirectory)
        case .xcodeWorkspace(let ws):
            return runXcodeBuild(workingDirectory: workingDirectory, project: ws, isWorkspace: true)
        case .xcodeProject(let proj):
            return runXcodeBuild(workingDirectory: workingDirectory, project: proj, isWorkspace: false)
        case .cargo:
            let r = ShellRunner.run(executable: "/usr/bin/env",
                                    arguments: ["cargo", "check", "--quiet"],
                                    workingDirectory: workingDirectory, timeout: 180)
            return r.exitCode == 0 ? .passed : .failed(log: r.stderr.isEmpty ? r.stdout : r.stderr)
        case .npm:
            let r = ShellRunner.run(executable: "/usr/bin/env",
                                    arguments: ["npx", "tsc", "--noEmit"],
                                    workingDirectory: workingDirectory, timeout: 120)
            return r.exitCode == 0 ? .passed : .failed(log: r.stdout + "\n" + r.stderr)
        case .none:
            return .noBuildSystem
        }
    }

    private static func runSwiftBuild(at dir: URL) -> Outcome {
        // No `--quiet`: not every toolchain in the wild supports the flag,
        // and a bad flag here would surface as a phantom "build failure"
        // injected into the agent loop. Output is truncated by the caller.
        let r = ShellRunner.run(executable: "/usr/bin/env",
                                arguments: ["swift", "build"],
                                workingDirectory: dir, timeout: 240)
        if r.exitCode == 0 { return .passed }
        let log = r.stderr.isEmpty ? r.stdout : r.stderr
        return .failed(log: log)
    }

    private static func runXcodeBuild(workingDirectory: URL, project: URL, isWorkspace: Bool) -> Outcome {
        let containerArgs = isWorkspace
            ? ["-workspace", project.lastPathComponent]
            : ["-project", project.lastPathComponent]

        // xcodebuild refuses to build without a real scheme (the old code
        // passed a literal "GENERIC", which failed on every project).
        // Discover schemes via `-list -json`, preferring one named after
        // the project itself.
        let list = ShellRunner.run(executable: "/usr/bin/xcodebuild",
                                   arguments: containerArgs + ["-list", "-json"],
                                   workingDirectory: workingDirectory, timeout: 60)
        guard let scheme = firstScheme(
            fromXcodebuildListJSON: list.stdout,
            preferring: project.deletingPathExtension().lastPathComponent
        ) else {
            Diagnostics.warn("BuildGuard: no scheme found for \(project.lastPathComponent) — skipping build verification")
            return .noBuildSystem
        }

        // No destination flag — the agent wants a syntax-level check, not
        // a device build. Building the default destination is fast.
        let r = ShellRunner.run(executable: "/usr/bin/xcodebuild",
                                arguments: containerArgs + ["-scheme", scheme, "-quiet", "build"],
                                workingDirectory: workingDirectory, timeout: 300)
        if r.exitCode == 0 { return .passed }
        let log = r.stdout + "\n" + r.stderr
        return .failed(log: log)
    }

    /// Parse `xcodebuild -list -json` output and pick a scheme.
    /// Prefers an exact match on `preferred` (typically the project
    /// name), else the first scheme alphabetically-as-listed. Returns
    /// nil when no schemes exist or the JSON is unparseable.
    ///
    /// Pure + static so it's unit-testable without running xcodebuild.
    static func firstScheme(fromXcodebuildListJSON json: String,
                            preferring preferred: String? = nil) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Shape: {"project": {..., "schemes": [...]}} or {"workspace": {...}}.
        let container = (obj["project"] ?? obj["workspace"]) as? [String: Any]
        guard let schemes = container?["schemes"] as? [String], !schemes.isEmpty else {
            return nil
        }
        if let preferred, schemes.contains(preferred) { return preferred }
        return schemes.first
    }
}

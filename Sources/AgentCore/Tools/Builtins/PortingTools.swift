//
//  PortingTools.swift
//
//  Five primitives that bottle the recurring moves of a cross-platform
//  Swift port. Each is a single concrete operation — multi-step workflows
//  are still the model's job, but the per-step primitives below remove
//  the manual grunt work.
//
//  Exposed as a single tool with an `action` discriminator:
//    • scan_platform_imports     — find Apple-only imports across a tree.
//    • patch_dependency_checkout — edit a file inside SwiftPM/Cargo checkouts.
//    • wrap_imports_can_import   — guard imports with #if canImport(X).
//    • generate_framework_shim   — write a stub for a missing framework.
//    • atomic_write_text         — crash-safe write (temp + rename).
//

import Foundation

public struct PortingTools: Tool {
    public static let name = "porting"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Primitives for cross-platform Swift porting. Actions:
          • scan_platform_imports     — list every `import X` for Apple-only \
        frameworks under `root_path`, with #if-guard status and a suggested fix.
          • patch_dependency_checkout — clear read-only on a SwiftPM/Cargo \
        checkout file and do a single-occurrence find-and-replace; saves a \
        sidecar .diff for re-application after dependency refresh.
          • wrap_imports_can_import   — for a single file, wrap each listed \
        framework's import with #if canImport(X) ... #endif. Idempotent.
          • generate_framework_shim   — write a Swift file with no-op stubs \
        for a missing framework (Combine has a pre-baked shim).
          • atomic_write_text         — write text to a path via temp + \
        replaceItemAt so the file is never half-written.
        """,
        parameters: .init(
            properties: [
                "action": .init(
                    type: "string",
                    description: "One of: scan_platform_imports, patch_dependency_checkout, wrap_imports_can_import, generate_framework_shim, atomic_write_text.",
                    enum: [
                        "scan_platform_imports",
                        "patch_dependency_checkout",
                        "wrap_imports_can_import",
                        "generate_framework_shim",
                        "atomic_write_text"
                    ]
                ),
                "root_path": .init(type: "string", description: "scan_platform_imports: directory to walk."),
                "path": .init(type: "string", description: "patch_dependency_checkout / wrap_imports_can_import / atomic_write_text: target file."),
                "old_string": .init(type: "string", description: "patch_dependency_checkout: text to replace (must appear exactly once)."),
                "new_string": .init(type: "string", description: "patch_dependency_checkout: replacement text."),
                "diff_output_dir": .init(type: "string", description: "patch_dependency_checkout: optional directory to drop a .diff sidecar."),
                "frameworks": .init(
                    type: "array",
                    description: "wrap_imports_can_import: framework names to guard.",
                    items: .init(type: "string")
                ),
                "framework": .init(type: "string", description: "generate_framework_shim: framework name (Combine has a pre-baked shim)."),
                "output_path": .init(type: "string", description: "generate_framework_shim: where to write the shim file."),
                "content": .init(type: "string", description: "atomic_write_text: text contents.")
            ],
            required: ["action"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let action = try arguments.string("action").lowercased()
        let base = context.workingDirectory
        switch action {
        case "scan_platform_imports":
            return scanPlatformImports(arguments: arguments, base: base)
        case "patch_dependency_checkout":
            return patchDependencyCheckout(arguments: arguments, base: base)
        case "wrap_imports_can_import":
            return wrapImportsCanImport(arguments: arguments, base: base)
        case "generate_framework_shim":
            return generateFrameworkShim(arguments: arguments, base: base, context: context)
        case "atomic_write_text":
            return atomicWriteText(arguments: arguments, base: base, context: context)
        default:
            return ToolResult(
                content: "Unknown action '\(action)'. Use scan_platform_imports, patch_dependency_checkout, wrap_imports_can_import, generate_framework_shim, or atomic_write_text.",
                isError: true
            )
        }
    }

    // MARK: - Apple-only framework list

    private static let appleOnlyFrameworks: [String] = [
        "Combine", "CryptoKit", "AppKit", "SwiftUI", "IOKit", "IOKit.pwr_mgt",
        "UserNotifications", "PDFKit", "Vision", "CoreImage", "CoreGraphics",
        "CoreText", "WebKit", "AVFoundation", "Quartz", "QuartzCore",
        "MediaPlayer", "MapKit", "CoreLocation", "Speech", "NaturalLanguage",
        "CoreML", "CreateML", "GameKit", "StoreKit", "MetricKit",
        "HomeKit", "HealthKit", "Photos", "Contacts"
    ]

    // MARK: - scan_platform_imports

    private func scanPlatformImports(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let rootPath = arguments.stringOptional("root_path"), !rootPath.isEmpty else {
            return ToolResult(content: "Error: `root_path` is required for scan_platform_imports.", isError: true)
        }
        let root = resolvePath(rootPath, base: base).path
        guard FileManager.default.fileExists(atPath: root) else {
            return ToolResult(content: "Error: path not found: \(rootPath)", isError: true)
        }

        var results: [[String: Any]] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let full = (root as NSString).appendingPathComponent(rel)
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var inGuard = false
            for (idx, lineSub) in lines.enumerated() {
                let line = String(lineSub).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if ") || line.hasPrefix("#elseif ") { inGuard = true }
                if line == "#endif" { inGuard = false }
                guard line.hasPrefix("import ") else { continue }
                let imported = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let baseFramework = imported.split(separator: ".").first.map(String.init) ?? imported
                if Self.appleOnlyFrameworks.contains(baseFramework) || Self.appleOnlyFrameworks.contains(imported) {
                    results.append([
                        "file": full,
                        "line": idx + 1,
                        "import": imported,
                        "alreadyGuarded": inGuard,
                        "suggestion": inGuard ? "ok" : "wrap in #if canImport(\(baseFramework))"
                    ])
                }
            }
        }

        let payload: [String: Any] = [
            "scanned": root,
            "appleOnlyImportsFound": results.count,
            "unguardedCount": results.filter { ($0["alreadyGuarded"] as? Bool) == false }.count,
            "items": results
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return ToolResult(content: "Error: could not serialize result", isError: true)
        }
        return ToolResult(content: str)
    }

    // MARK: - patch_dependency_checkout

    private func patchDependencyCheckout(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let path = arguments.stringOptional("path"), !path.isEmpty else {
            return ToolResult(content: "Error: `path` is required for patch_dependency_checkout.", isError: true)
        }
        guard let oldString = arguments.stringOptional("old_string"), !oldString.isEmpty,
              let newString = arguments.stringOptional("new_string") else {
            return ToolResult(content: "Error: `old_string` and `new_string` are required.", isError: true)
        }
        let expanded = resolvePath(path, base: base).path
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ToolResult(content: "Error: file not found: \(expanded)", isError: true)
        }

        // Clear read-only.
        var attrs = (try? FileManager.default.attributesOfItem(atPath: expanded)) ?? [:]
        attrs[.posixPermissions] = 0o644
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: expanded)

        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read \(expanded)", isError: true)
        }
        let count = content.components(separatedBy: oldString).count - 1
        guard count == 1 else {
            return ToolResult(content: "Error: oldString matched \(count) times (must be exactly 1).", isError: true)
        }
        let updated = content.replacingOccurrences(of: oldString, with: newString)
        do {
            try updated.write(toFile: expanded, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(content: "Error: write failed: \(error.localizedDescription)", isError: true)
        }

        var mutated: [String] = [relativePath(expanded, base: base.path)]

        if let outDir = arguments.stringOptional("diff_output_dir"), !outDir.isEmpty {
            let outExpanded = resolvePath(outDir, base: base).path
            try? FileManager.default.createDirectory(atPath: outExpanded, withIntermediateDirectories: true)
            let basename = (expanded as NSString).lastPathComponent
            let diffPath = (outExpanded as NSString).appendingPathComponent("\(basename).diff")
            let diffContent = """
            --- \(expanded) (before)
            +++ \(expanded) (after)
            - \(oldString.replacingOccurrences(of: "\n", with: "\n- "))
            + \(newString.replacingOccurrences(of: "\n", with: "\n+ "))
            """
            try? diffContent.write(toFile: diffPath, atomically: true, encoding: .utf8)
            mutated.append(relativePath(diffPath, base: base.path))
        }

        return ToolResult(
            content: "Patched \(expanded): replaced 1 occurrence of \(oldString.count)-char block.",
            mutatedPaths: mutated
        )
    }

    // MARK: - wrap_imports_can_import

    private func wrapImportsCanImport(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let path = arguments.stringOptional("path"), !path.isEmpty else {
            return ToolResult(content: "Error: `path` is required for wrap_imports_can_import.", isError: true)
        }
        let frameworks = arguments.stringArray("frameworks")
        guard !frameworks.isEmpty else {
            return ToolResult(content: "Error: `frameworks` (non-empty array) is required.", isError: true)
        }
        let expanded = resolvePath(path, base: base).path
        guard var content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return ToolResult(content: "Error: could not read \(expanded)", isError: true)
        }

        var modifiedCount = 0
        for fw in frameworks {
            let importLine = "import \(fw)"
            let wrappedExpected = "#if canImport(\(fw))\n\(importLine)\n#endif"
            if content.contains(wrappedExpected) { continue }
            guard let range = content.range(
                of: "(?m)^\(NSRegularExpression.escapedPattern(for: importLine))$",
                options: .regularExpression
            ) else { continue }
            content.replaceSubrange(range, with: wrappedExpected)
            modifiedCount += 1
        }

        guard modifiedCount > 0 else {
            return ToolResult(content: "No changes — imports already wrapped or not present.")
        }
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(content: "Error: write failed: \(error.localizedDescription)", isError: true)
        }
        return ToolResult(
            content: "Wrapped \(modifiedCount) import(s) in \(expanded).",
            mutatedPaths: [relativePath(expanded, base: base.path)]
        )
    }

    // MARK: - generate_framework_shim

    private func generateFrameworkShim(arguments: ToolArguments, base: URL, context: ToolContext) -> ToolResult {
        guard let framework = arguments.stringOptional("framework"), !framework.isEmpty else {
            return ToolResult(content: "Error: `framework` is required for generate_framework_shim.", isError: true)
        }
        guard let outputPath = arguments.stringOptional("output_path"), !outputPath.isEmpty else {
            return ToolResult(content: "Error: `output_path` is required for generate_framework_shim.", isError: true)
        }
        let outURL = resolvePath(outputPath, base: base)
        do {
            try PathConfinement.requireInsideWorkspace(path: outputPath, resolved: outURL, context: context)
        } catch {
            return ToolResult(content: "Error: \(error.localizedDescription)", isError: true)
        }
        let expanded = outURL.path
        let content: String
        switch framework {
        case "Combine": content = Self.combineShim()
        default:        content = Self.genericShim(framework: framework)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(content: "Error: write failed: \(error.localizedDescription)", isError: true)
        }
        return ToolResult(
            content: "Wrote shim for \(framework) to \(expanded) (\(content.count) chars).",
            mutatedPaths: [relativePath(expanded, base: base.path)]
        )
    }

    // MARK: - atomic_write_text

    private func atomicWriteText(arguments: ToolArguments, base: URL, context: ToolContext) -> ToolResult {
        guard let path = arguments.stringOptional("path"), !path.isEmpty else {
            return ToolResult(content: "Error: `path` is required for atomic_write_text.", isError: true)
        }
        guard let content = arguments.stringOptional("content") else {
            return ToolResult(content: "Error: `content` is required for atomic_write_text.", isError: true)
        }
        let outURL = resolvePath(path, base: base)
        do {
            try PathConfinement.requireInsideWorkspace(path: path, resolved: outURL, context: context)
        } catch {
            return ToolResult(content: "Error: \(error.localizedDescription)", isError: true)
        }
        let expanded = outURL.path
        let tmp = expanded + ".tmp"
        let parent = (expanded as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        do {
            try content.write(toFile: tmp, atomically: false, encoding: .utf8)
        } catch {
            return ToolResult(content: "Error: temp write failed: \(error.localizedDescription)", isError: true)
        }
        let tmpURL = URL(fileURLWithPath: tmp)
        let dstURL = URL(fileURLWithPath: expanded)
        do {
            if FileManager.default.fileExists(atPath: expanded) {
                _ = try FileManager.default.replaceItemAt(dstURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: dstURL)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return ToolResult(content: "Error: atomic replace failed: \(error.localizedDescription)", isError: true)
        }
        return ToolResult(
            content: "Wrote \(content.count) chars to \(expanded) atomically.",
            mutatedPaths: [relativePath(expanded, base: base.path)]
        )
    }

    // MARK: - Helpers

    private func relativePath(_ path: String, base: String) -> String {
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(basePrefix) {
            return String(path.dropFirst(basePrefix.count))
        }
        return path
    }

    // MARK: - Shim content

    private static func combineShim() -> String {
        """
        // CombineShim.swift — generated by PortingTools.generate_framework_shim.
        //
        // Minimal Combine shim for non-Apple platforms. On macOS this file
        // compiles to nothing because canImport(Combine) is true; on Windows
        // / Linux it provides no-op versions of the most-used Combine types
        // so server-side code adopting the Combine pattern still compiles.

        #if !canImport(Combine)

        import Foundation

        public protocol ObservableObject: AnyObject {}

        @propertyWrapper
        public struct Published<Value> {
            public var wrappedValue: Value
            public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
            public init(initialValue: Value) { self.wrappedValue = initialValue }
            public var projectedValue: Published<Value> { self }
        }

        public final class AnyCancellable: Hashable {
            public init() {}
            public init(_ cancel: @escaping () -> Void) {}
            public func cancel() {}
            public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }
            public static func == (l: AnyCancellable, r: AnyCancellable) -> Bool { l === r }
            public func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(self))
            }
        }

        public final class PassthroughSubject<Output, Failure> where Failure: Error {
            public init() {}
            public func send(_ v: Output) {}
            public func send(completion: Subscribers.Completion<Failure>) {}
        }

        public final class CurrentValueSubject<Output, Failure> where Failure: Error {
            public var value: Output
            public init(_ initial: Output) { self.value = initial }
            public func send(_ v: Output) { self.value = v }
        }

        public enum Subscribers {
            public enum Completion<Failure> where Failure: Error {
                case finished
                case failure(Failure)
            }
        }

        #endif
        """
    }

    private static func genericShim(framework: String) -> String {
        """
        // \(framework)Shim.swift — generated by PortingTools.generate_framework_shim.
        //
        // Empty placeholder. Compiles to nothing on platforms where
        // `\(framework)` is available. Edit this file to add no-op stubs
        // for the specific types your code needs from `\(framework)`.

        #if !canImport(\(framework))

        import Foundation

        // TODO: add stub types as compile errors point them out.

        #endif
        """
    }
}

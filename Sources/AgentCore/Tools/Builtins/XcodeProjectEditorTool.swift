//
//  XcodeProjectEditorTool.swift
//
//  Surgical edits to a `.xcodeproj/project.pbxproj` file. Currently
//  exposes a single sub-action `add_file` (with `find_xcodeproj` as a
//  read-only helper). Patches the silent failure where `write_file`
//  creates a new .swift that the build never compiles because it isn't a
//  target member.
//
//  Implementation note: pbxproj is OpenStep plist with section markers.
//  We do regex/string-based section editing rather than full plist
//  round-tripping because `PropertyListSerialization` in Swift cannot
//  write OpenStep format. This keeps edits minimal and preserves Xcode's
//  existing formatting / comments. The trade-off is fragility: very
//  unusual projects (multiple Sources phases, deeply nested groups,
//  nonstandard formatting) may not be matched. Errors are surfaced
//  clearly.
//

import Foundation

public struct XcodeProjectEditorTool: Tool {
    public static let name = "xcode_project_editor"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Edit an Xcode project (`.xcodeproj/project.pbxproj`). Actions:
          • add_file        — register an existing file with the project so \
        `xcodebuild` compiles it. Auto-locates the .xcodeproj, generates UUIDs, \
        inserts PBXFileReference + PBXBuildFile + a PBXGroup child entry, and \
        appends to the first PBXSourcesBuildPhase when the file is compilable.
          • find_xcodeproj  — locate the .xcodeproj under the given path \
        (or the project root). Read-only.
        """,
        parameters: .init(
            properties: [
                "action": .init(
                    type: "string",
                    description: "One of: add_file, find_xcodeproj.",
                    enum: ["add_file", "find_xcodeproj"]
                ),
                "file_path": .init(
                    type: "string",
                    description: "add_file: path to the file to add. Must already exist."
                ),
                "project_path": .init(
                    type: "string",
                    description: "Directory containing the .xcodeproj. Default project root."
                ),
                "target_name": .init(
                    type: "string",
                    description: "add_file: target hint surfaced in the result. Not enforced — we add to the first Sources build phase."
                )
            ],
            required: ["action"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let action = try arguments.string("action").lowercased()
        let base = context.workingDirectory
        switch action {
        case "add_file":
            return addFile(arguments: arguments, base: base)
        case "find_xcodeproj":
            return findProject(arguments: arguments, base: base)
        default:
            return ToolResult(
                content: "Unknown action '\(action)'. Use add_file or find_xcodeproj.",
                isError: true
            )
        }
    }

    // MARK: - add_file

    private func addFile(arguments: ToolArguments, base: URL) -> ToolResult {
        guard let filePath = arguments.stringOptional("file_path"), !filePath.isEmpty else {
            return ToolResult(content: "Error: `file_path` is required for add_file.", isError: true)
        }
        let resolvedFile = resolvePath(filePath, base: base).path
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            return ToolResult(
                content: "Error: file does not exist at \(resolvedFile). Create it with write_file before adding it to the project.",
                isError: true
            )
        }
        let fileName = (resolvedFile as NSString).lastPathComponent

        // 1. Locate .xcodeproj
        let baseDir = resolveBaseDir(arguments.stringOptional("project_path"), workingDirectory: base)
        guard let xcodeprojDir = Self.findXcodeproj(in: baseDir) else {
            return ToolResult(
                content: "Error: no .xcodeproj found in \(baseDir). Pass project_path explicitly if the project lives elsewhere.",
                isError: true
            )
        }
        let pbxprojPath = "\(xcodeprojDir)/project.pbxproj"

        // 2. Read pbxproj
        guard var pbxproj = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            return ToolResult(content: "Error: cannot read \(pbxprojPath).", isError: true)
        }

        // 3. Refuse duplicate adds.
        if pbxproj.range(of: "/* \(fileName) */") != nil {
            return ToolResult(
                content: "Error: a reference to \(fileName) already exists in the project. Refusing to add a duplicate.",
                isError: true
            )
        }

        // 4. Generate UUIDs and metadata
        let buildFileUUID = Self.generateXcodeUUID()
        let fileRefUUID = Self.generateXcodeUUID()
        let (fileType, isCompilable) = Self.inferFileType(fromName: fileName)

        // 5. Compute path relative to the project directory
        let projectDir = (xcodeprojDir as NSString).deletingLastPathComponent
        let relPath = Self.makeRelativePath(absolute: resolvedFile, base: projectDir) ?? fileName

        // 6. Inject PBXBuildFile (only for compilable types)
        if isCompilable {
            let buildLine = "\t\t\(buildFileUUID) /* \(fileName) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRefUUID) /* \(fileName) */; };"
            guard let updated = Self.insertBefore(pbxproj, marker: "/* End PBXBuildFile section */", line: buildLine) else {
                return ToolResult(content: "Error: could not find the PBXBuildFile section in pbxproj.", isError: true)
            }
            pbxproj = updated
        }

        // 7. Inject PBXFileReference
        let refLine = "\t\t\(fileRefUUID) /* \(fileName) */ = {isa = PBXFileReference; lastKnownFileType = \(fileType); path = \(Self.quotePbxPath(relPath)); sourceTree = \"<group>\"; };"
        guard let updatedRef = Self.insertBefore(pbxproj, marker: "/* End PBXFileReference section */", line: refLine) else {
            return ToolResult(content: "Error: could not find the PBXFileReference section in pbxproj.", isError: true)
        }
        pbxproj = updatedRef

        // 8. Add to a PBXGroup's children.
        let parentDirComponents = (relPath as NSString).deletingLastPathComponent
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
            .reversed()
        let groupChildEntry = "\t\t\t\t\(fileRefUUID) /* \(fileName) */,"
        guard let groupResult = Self.appendToGroup(
            pbxproj,
            preferGroupsNamed: Array(parentDirComponents),
            entry: groupChildEntry
        ) else {
            return ToolResult(content: "Error: could not find a PBXGroup to add the file reference to.", isError: true)
        }
        pbxproj = groupResult.updated
        let chosenGroupName = groupResult.groupName

        // 9. Add to Sources build phase (if compilable)
        if isCompilable {
            let buildPhaseEntry = "\t\t\t\t\(buildFileUUID) /* \(fileName) in Sources */,"
            guard let updatedSources = Self.appendToFirstSourcesBuildPhase(pbxproj, entry: buildPhaseEntry) else {
                return ToolResult(content: "Error: could not find a PBXSourcesBuildPhase to add the build file to.", isError: true)
            }
            pbxproj = updatedSources
        }

        // 10. Write back atomically
        do {
            try pbxproj.write(toFile: pbxprojPath, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(content: "Error writing pbxproj: \(error.localizedDescription)", isError: true)
        }

        let target = arguments.stringOptional("target_name").map { $0.isEmpty ? "(first compilable target)" : $0 }
            ?? "(first compilable target)"
        let mutatedRel = Self.makeRelativePath(absolute: pbxprojPath, base: base.path) ?? pbxprojPath
        return ToolResult(
            content: "Added \(fileName) to \(xcodeprojDir). group=\(chosenGroupName), target=\(target), fileRefUUID=\(fileRefUUID)\(isCompilable ? ", buildFileUUID=\(buildFileUUID)" : "") — run xcodebuild to verify the file compiles. If the group looks wrong in Xcode's navigator, you can drag it manually.",
            mutatedPaths: [mutatedRel]
        )
    }

    // MARK: - find_xcodeproj

    private func findProject(arguments: ToolArguments, base: URL) -> ToolResult {
        let baseDir = resolveBaseDir(arguments.stringOptional("project_path"), workingDirectory: base)
        guard let xcodeprojDir = Self.findXcodeproj(in: baseDir) else {
            return ToolResult(content: "(no .xcodeproj found in \(baseDir))", isError: false)
        }
        return ToolResult(content: xcodeprojDir)
    }

    // MARK: - Helpers

    private func resolveBaseDir(_ p: String?, workingDirectory: URL) -> String {
        guard let s = p?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return workingDirectory.path
        }
        if s.hasPrefix("/") { return (s as NSString).expandingTildeInPath }
        return workingDirectory.appendingPathComponent(s).path
    }

    // MARK: - Pbxproj manipulation

    private struct GroupInsertion {
        let updated: String
        let groupName: String
    }

    private static func insertBefore(_ source: String, marker: String, line: String) -> String? {
        guard let range = source.range(of: marker) else { return nil }
        var out = source
        out.replaceSubrange(range, with: line + "\n" + marker)
        return out
    }

    private static func appendToGroup(_ source: String,
                                      preferGroupsNamed candidates: [String],
                                      entry: String) -> GroupInsertion? {
        let groupBlockPattern = "isa = PBXGroup;[\\s\\S]*?\\}"
        guard let regex = try? NSRegularExpression(pattern: groupBlockPattern) else { return nil }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))

        for candidate in candidates where !candidate.isEmpty {
            for m in matches {
                let block = ns.substring(with: m.range)
                if block.contains("path = \(candidate);") || block.contains("path = \"\(candidate)\";") {
                    if let updated = injectIntoChildrenList(source: source, blockRange: m.range, ns: ns, entry: entry) {
                        return GroupInsertion(updated: updated, groupName: candidate)
                    }
                }
            }
        }

        for m in matches {
            let block = ns.substring(with: m.range)
            if block.contains("children = (") {
                if let updated = injectIntoChildrenList(source: source, blockRange: m.range, ns: ns, entry: entry) {
                    return GroupInsertion(updated: updated, groupName: "(main group / fallback)")
                }
            }
        }
        return nil
    }

    private static func injectIntoChildrenList(source: String, blockRange: NSRange, ns: NSString, entry: String) -> String? {
        let block = ns.substring(with: blockRange)
        guard let openRange = block.range(of: "children = (") else { return nil }
        let afterOpen = block.index(openRange.upperBound, offsetBy: 0)
        guard let closeRange = block.range(of: ");", range: afterOpen..<block.endIndex) else { return nil }
        var newBlock = block
        newBlock.replaceSubrange(closeRange, with: entry + "\n\t\t\t);")
        var out = source
        let blockStart = source.index(source.startIndex, offsetBy: blockRange.location)
        let blockEnd = source.index(blockStart, offsetBy: blockRange.length)
        out.replaceSubrange(blockStart..<blockEnd, with: newBlock)
        return out
    }

    private static func appendToFirstSourcesBuildPhase(_ source: String, entry: String) -> String? {
        let pattern = "isa = PBXSourcesBuildPhase;[\\s\\S]*?\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let m = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let block = ns.substring(with: m.range)
        guard let openRange = block.range(of: "files = (") else { return nil }
        guard let closeRange = block.range(of: ");", range: openRange.upperBound..<block.endIndex) else { return nil }
        var newBlock = block
        newBlock.replaceSubrange(closeRange, with: entry + "\n\t\t\t);")
        var out = source
        let blockStart = source.index(source.startIndex, offsetBy: m.range.location)
        let blockEnd = source.index(blockStart, offsetBy: m.range.length)
        out.replaceSubrange(blockStart..<blockEnd, with: newBlock)
        return out
    }

    private static func findXcodeproj(in dir: String) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        if let p = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return (dir as NSString).appendingPathComponent(p)
        }
        return nil
    }

    private static func generateXcodeUUID() -> String {
        let chars = "0123456789ABCDEF"
        return String((0..<24).map { _ in chars.randomElement()! })
    }

    private static func inferFileType(fromName name: String) -> (String, Bool) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":              return ("sourcecode.swift", true)
        case "m":                  return ("sourcecode.c.objc", true)
        case "mm":                 return ("sourcecode.cpp.objcpp", true)
        case "c":                  return ("sourcecode.c.c", true)
        case "cpp", "cc", "cxx":   return ("sourcecode.cpp.cpp", true)
        case "h":                  return ("sourcecode.c.h", false)
        case "hpp", "hh":          return ("sourcecode.cpp.h", false)
        case "plist":              return ("text.plist.xml", false)
        case "json":               return ("text.json", false)
        case "xib":                return ("file.xib", false)
        case "storyboard":         return ("file.storyboard", false)
        case "xcassets":           return ("folder.assetcatalog", false)
        case "md":                 return ("net.daringfireball.markdown", false)
        case "txt":                return ("text", false)
        default:                   return ("text", false)
        }
    }

    /// OpenStep plist tokens with spaces (or other non-identifier chars)
    /// must be quoted: `path = "My File.swift";`.
    private static func quotePbxPath(_ path: String) -> String {
        let unquotedOK = !path.isEmpty && path.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "/" || scalar == "-"
        }
        if unquotedOK { return path }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func makeRelativePath(absolute file: String, base: String) -> String? {
        let f = (file as NSString).standardizingPath
        let b = (base as NSString).standardizingPath
        if f.hasPrefix(b + "/") {
            return String(f.dropFirst(b.count + 1))
        }
        if f == b { return f }
        return nil
    }
}

//
//  ListDirectoryTool.swift
//
//  Lists directory entries. Output is a tab-separated VC_LIST payload
//  (path + kind/size/name/mtime) so the chat UI can render a ZCode-style
//  File | Size | Modified table. Legacy "d  name" lines are also still
//  accepted by DirectoryListing.parse.
//

import Foundation

public struct ListDirectoryTool: Tool {
    public static let name = "list_directory"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .readOnly
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: "List entries in a directory. Returns names, sizes, and modification times. Hidden files excluded by default.",
        parameters: .init(
            properties: [
                "path": .init(type: "string", description: "Directory path relative to project root, or absolute. Default '.'."),
                "includeHidden": .init(type: "boolean", description: "Include dotfiles. Default false.")
            ]
        )
    )

    /// Cap listing rows so huge directories don't blow context.
    public static let maxEntries = 200

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = arguments.stringOptional("path") ?? "."
        let includeHidden = arguments.bool("includeHidden", default: false)
        let url = resolvePath(path, base: context.workingDirectory)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(content: "Not a directory: \(url.path)", isError: true)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )

        let sorted = contents.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }

        var lines: [String] = ["VC_LIST\t\(url.path)"]
        if sorted.isEmpty {
            lines.append("empty")
            return ToolResult(content: lines.joined(separator: "\n"))
        }

        let slice = sorted.prefix(Self.maxEntries)
        for entryURL in slice {
            let values = try? entryURL.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = isDirectory ? 0 : (values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let kind = isDirectory ? "dir" : "file"
            let name = entryURL.lastPathComponent
            lines.append("\(kind)\t\(size)\t\(name)\t\(Int(mtime))")
        }
        if sorted.count > Self.maxEntries {
            let more = sorted.count - Self.maxEntries
            lines.append("more\t0\t… and \(more) more\t0")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}

//
//  NotebookTool.swift
//
//  Jupyter `.ipynb` cell editing. The notebook format is JSON; we keep the
//  rest of the document intact and only mutate the requested cell. Output
//  cells are wiped on edit (re-execution will repopulate them).
//
//  Actions: insert, replace_source, delete, set_type, read.
//

import Foundation

public struct NotebookTool: Tool {
    public static let name = "notebook"
    public static let category: ToolCategory = .filesystem
    public static let permission: ToolPermission = .mutates
    public static let availability: ToolAvailability = .core
    public static let schema = ToolSchema(
        name: name,
        description: """
        Edit a Jupyter `.ipynb` notebook by cell index. Actions:
          • read           — list cells with a short preview of each.
          • insert         — add a new cell (code/markdown/raw) at `index` (default append).
          • replace_source — overwrite the source of an existing cell; clears outputs.
          • delete         — remove a cell by index.
          • set_type       — switch a cell between code/markdown/raw.
        Cell indices are zero-based.
        """,
        parameters: .init(
            properties: [
                "path": .init(type: "string", description: "Path to the .ipynb file."),
                "action": .init(
                    type: "string",
                    description: "One of: read, insert, replace_source, delete, set_type.",
                    enum: ["read", "insert", "replace_source", "delete", "set_type"]
                ),
                "index":    .init(type: "integer", description: "0-based cell index. Required for replace_source/delete/set_type."),
                "source":   .init(type: "string",  description: "Cell source for insert/replace_source."),
                "cellType": .init(
                    type: "string",
                    description: "Cell type for insert/set_type.",
                    enum: ["code", "markdown", "raw"]
                )
            ],
            required: ["path", "action"]
        )
    )

    public init() {}

    enum Action: String {
        case insert, replace_source, delete, set_type, read
    }

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let path = try arguments.string("path")
        let actionRaw = try arguments.string("action").lowercased()
        let index = arguments.intOptional("index")
        let source = arguments.stringOptional("source")
        let cellType = arguments.stringOptional("cellType")

        let url = resolvePath(path, base: context.workingDirectory)
        if actionRaw != "read" {
            try PathConfinement.requireInsideWorkspace(path: path, resolved: url, context: context)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ToolResult(content: "Error: notebook not found at \(path).", isError: true)
        }
        guard let data = try? Data(contentsOf: url),
              var notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolResult(content: "Error: could not parse \(path) as JSON.", isError: true)
        }
        guard var cells = notebook["cells"] as? [[String: Any]] else {
            return ToolResult(content: "Error: notebook is missing the `cells` array.", isError: true)
        }
        guard let act = Action(rawValue: actionRaw) else {
            return ToolResult(
                content: "Error: unknown action \"\(actionRaw)\". Use one of: insert, replace_source, delete, set_type, read.",
                isError: true
            )
        }

        switch act {
        case .read:
            return ToolResult(content: Self.readSummary(cells))

        case .insert:
            guard let src = source else {
                return ToolResult(content: "Error: `source` is required for insert.", isError: true)
            }
            let t = (cellType ?? "code").lowercased()
            let cell = Self.newCell(type: t, source: src)
            let i = index.map { max(0, min($0, cells.count)) } ?? cells.count
            cells.insert(cell, at: i)
            notebook["cells"] = cells
            return Self.write(notebook, to: url, path: path,
                              summary: "Inserted \(t) cell at index \(i) (now \(cells.count) cells).")

        case .replace_source:
            guard let i = index, i >= 0, i < cells.count else {
                return ToolResult(content: "Error: `index` (0..\(cells.count - 1)) is required for replace_source.",
                                  isError: true)
            }
            guard let src = source else {
                return ToolResult(content: "Error: `source` is required for replace_source.", isError: true)
            }
            cells[i]["source"] = Self.splitSource(src)
            if (cells[i]["cell_type"] as? String) == "code" {
                cells[i]["outputs"] = []
                cells[i]["execution_count"] = NSNull()
            }
            notebook["cells"] = cells
            return Self.write(notebook, to: url, path: path,
                              summary: "Replaced source of cell \(i).")

        case .delete:
            guard let i = index, i >= 0, i < cells.count else {
                return ToolResult(content: "Error: `index` (0..\(cells.count - 1)) is required for delete.",
                                  isError: true)
            }
            cells.remove(at: i)
            notebook["cells"] = cells
            return Self.write(notebook, to: url, path: path,
                              summary: "Deleted cell \(i) (now \(cells.count) cells).")

        case .set_type:
            guard let i = index, i >= 0, i < cells.count else {
                return ToolResult(content: "Error: `index` (0..\(cells.count - 1)) is required for set_type.",
                                  isError: true)
            }
            let t = (cellType ?? "").lowercased()
            guard ["code", "markdown", "raw"].contains(t) else {
                return ToolResult(content: "Error: `cellType` must be one of: code, markdown, raw.",
                                  isError: true)
            }
            cells[i]["cell_type"] = t
            if t == "code" {
                if cells[i]["outputs"] == nil { cells[i]["outputs"] = [] }
                if cells[i]["execution_count"] == nil { cells[i]["execution_count"] = NSNull() }
            } else {
                cells[i].removeValue(forKey: "outputs")
                cells[i].removeValue(forKey: "execution_count")
            }
            notebook["cells"] = cells
            return Self.write(notebook, to: url, path: path,
                              summary: "Set cell \(i) type to \(t).")
        }
    }

    // MARK: - Helpers

    private static func newCell(type: String, source: String) -> [String: Any] {
        var cell: [String: Any] = [
            "cell_type": type,
            "metadata": [String: Any](),
            "source": splitSource(source)
        ]
        if type == "code" {
            cell["outputs"] = []
            cell["execution_count"] = NSNull()
        }
        return cell
    }

    /// Jupyter stores `source` as an array of lines (each terminated with \n
    /// except possibly the last). Normalising on write keeps diffs friendly
    /// for git users.
    private static func splitSource(_ s: String) -> [String] {
        let lines = s.components(separatedBy: "\n")
        return lines.enumerated().map { (i, line) in
            i < lines.count - 1 ? line + "\n" : line
        }
    }

    private static func readSummary(_ cells: [[String: Any]]) -> String {
        if cells.isEmpty { return "Notebook has 0 cells." }
        var out = "Notebook has \(cells.count) cell(s):\n"
        for (i, c) in cells.enumerated() {
            let t = (c["cell_type"] as? String) ?? "?"
            let src = (c["source"] as? [String])?.joined() ?? (c["source"] as? String) ?? ""
            let preview = src.replacingOccurrences(of: "\n", with: " ").prefix(80)
            out += "  [\(i)] \(t): \(preview)\n"
        }
        return out
    }

    private static func write(_ notebook: [String: Any],
                              to url: URL,
                              path: String,
                              summary: String) -> ToolResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: notebook,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return ToolResult(content: summary, mutatedPaths: [path])
        } catch {
            return ToolResult(content: "Error writing notebook: \(error.localizedDescription)",
                              isError: true)
        }
    }
}

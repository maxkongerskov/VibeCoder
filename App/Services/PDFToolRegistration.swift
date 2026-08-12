// PDFToolRegistration.swift
// VibeCoder — offline PDF agent tools
//
// Registers App-target PDF services (PDFKit / Vision / WKWebView) as
// ToolRegistry dynamic tools. AgentCore stays free of AppKit/PDFKit;
// the host app calls `register()` once at boot after AgentCore.bootstrap().
//
// Offline-only: no network permission on any of these tools.
//

import Foundation
import CoreGraphics
import AgentCore

/// Host-side registration of PDF tools for the agent loop.
public enum PDFToolRegistration {

    /// Names registered by this module (core + deferred).
    public static let toolNames: Set<String> = [
        "extract_pdf_text",
        "ocr_image",
        "create_pdf",
        "manipulate_pdf",
        "fill_pdf_form",
        "sign_pdf",
    ]

    /// Always-on tools (in model schema every turn).
    public static let coreToolNames: Set<String> = [
        "extract_pdf_text",
        "ocr_image",
        "create_pdf",
    ]

    /// Revealed via `tool_search` / skill.
    public static let deferredToolNames: Set<String> = [
        "manipulate_pdf",
        "fill_pdf_form",
        "sign_pdf",
    ]

    /// Register (or re-register) all PDF tools. Idempotent: replaces prior
    /// dynamic entries for the same names.
    public static func register() async {
        await registerExtractPDFText()
        await registerOCRImage()
        await registerCreatePDF()
        await registerManipulatePDF()
        await registerFillPDFForm()
        await registerSignPDF()
        Diagnostics.info("PDF tools registered (offline): \(toolNames.sorted().joined(separator: ", "))")
    }

    // MARK: - extract_pdf_text (core, readOnly)

    private static func registerExtractPDFText() async {
        let schema = ToolSchema(
            name: "extract_pdf_text",
            description: """
            Extract text from a local PDF (offline, PDFKit). Returns markdown with \
            ## Page N sections. Use for digital/text PDFs. If pages say no extractable \
            text, the PDF may be a scan — render a page to an image and call ocr_image. \
            Never use web tools or online converters for this.
            """,
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Path to the PDF file (absolute or ~)."),
                    "page_range": .init(
                        type: "string",
                        description: "Optional page range, e.g. \"1-5,7\" or \"all\". Default: all pages."
                    ),
                ],
                required: ["path"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .readOnly,
            availability: .core,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let path = try args.string("path")
            let range = args.stringOptional("page_range")
            let out = PDFToolsService.extractText(path: path, pageRange: range)
            return result(out)
        }
    }

    // MARK: - ocr_image (core, readOnly)

    private static func registerOCRImage() async {
        let schema = ToolSchema(
            name: "ocr_image",
            description: """
            On-device OCR (Apple Vision) for a raster image: PNG, JPEG, TIFF, HEIC. \
            Offline only. Use for scanned PDF pages after rendering to an image, or \
            screenshots. For text-layer PDFs prefer extract_pdf_text first.
            """,
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Path to the image file."),
                    "accurate": .init(
                        type: "boolean",
                        description: "Use accurate recognition (default true). false = faster."
                    ),
                    "languages": .init(
                        type: "array",
                        description: "Optional BCP-47 language hints, e.g. [\"en\", \"da\"]. Empty = auto.",
                        items: .init(type: "string")
                    ),
                ],
                required: ["path"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .readOnly,
            availability: .core,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let path = try args.string("path")
            let accurate = args.bool("accurate", default: true)
            let languages = args.stringArray("languages")
            let langs = languages.isEmpty ? ["en"] : languages
            let out = await OCRService.recognize(path: path, accurate: accurate, languages: langs)
            return result(out)
        }
    }

    // MARK: - create_pdf (core, mutates)

    private static func registerCreatePDF() async {
        let schema = ToolSchema(
            name: "create_pdf",
            description: """
            Create a PDF offline from markdown (file path or inline text) via local \
            HTML rendering (WKWebView). Themes: default, academic, report, resume. \
            Does not call the network. Prefer this over inventing Python/reportlab \
            unless the user requires a special layout.
            """,
            parameters: .init(
                properties: [
                    "output_path": .init(type: "string", description: "Where to write the PDF."),
                    "markdown_path": .init(
                        type: "string",
                        description: "Path to a .md source file. Provide this or markdown_text."
                    ),
                    "markdown_text": .init(
                        type: "string",
                        description: "Inline markdown body. Provide this or markdown_path."
                    ),
                    "theme": .init(
                        type: "string",
                        description: "Layout theme: default | academic | report | resume. Default: default.",
                        enum: ["default", "academic", "report", "resume"]
                    ),
                ],
                required: ["output_path"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .mutates,
            availability: .core,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let output = try args.string("output_path")
            let mdPath = args.stringOptional("markdown_path")
            let mdText = args.stringOptional("markdown_text")
            let theme = args.stringOptional("theme") ?? "default"
            let out = await DocumentRenderingService.renderMarkdownToPDF(
                markdownPath: mdPath,
                markdownText: mdText,
                outputPath: output,
                theme: theme
            )
            return result(out, mutated: successPath(out, fallback: output))
        }
    }

    // MARK: - manipulate_pdf (deferred, mutates)

    private static func registerManipulatePDF() async {
        let schema = ToolSchema(
            name: "manipulate_pdf",
            description: """
            Offline PDF structural edits via PDFKit. Actions: merge, split, \
            extract_pages, rotate, watermark. Never use online converters. \
            Unlock with tool_search if not already in the tool list.
            """,
            parameters: .init(
                properties: [
                    "action": .init(
                        type: "string",
                        description: "One of: merge | split | extract_pages | rotate | watermark",
                        enum: ["merge", "split", "extract_pages", "rotate", "watermark"]
                    ),
                    "input": .init(type: "string", description: "Source PDF path (split, extract_pages, rotate, watermark)."),
                    "inputs": .init(
                        type: "array",
                        description: "For merge: ordered list of PDF paths.",
                        items: .init(type: "string")
                    ),
                    "output": .init(type: "string", description: "Output PDF path (merge, extract_pages, rotate, watermark)."),
                    "output_dir": .init(type: "string", description: "For split: directory for one-file-per-page PDFs."),
                    "pages": .init(
                        type: "string",
                        description: "Page range for extract_pages / rotate, e.g. \"1-3,5\" or \"all\"."
                    ),
                    "angle": .init(
                        type: "integer",
                        description: "For rotate: 90, 180, 270, or -90."
                    ),
                    "text": .init(type: "string", description: "For watermark: watermark text."),
                    "opacity": .init(
                        type: "number",
                        description: "For watermark: opacity 0–1 (default 0.18)."
                    ),
                ],
                required: ["action"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .mutates,
            availability: .deferred,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let action = try args.string("action")
            let out = PDFToolsService.manipulate(action: action, args: args.raw)
            let mutated = mutationPaths(from: args.raw, message: out)
            return result(out, mutated: mutated)
        }
    }

    // MARK: - fill_pdf_form (deferred, mutates)

    private static func registerFillPDFForm() async {
        let schema = ToolSchema(
            name: "fill_pdf_form",
            description: """
            Offline AcroForm fill via PDFKit. Call once with only `input` to list \
            field names; then again with `values` and `output` to write a filled PDF. \
            No network.
            """,
            parameters: .init(
                properties: [
                    "input": .init(type: "string", description: "Path to the form PDF."),
                    "output": .init(type: "string", description: "Output path when filling (required if values provided)."),
                    "values": .init(
                        type: "object",
                        description: "Map of field name → string value. Omit or empty to list fields only."
                    ),
                ],
                required: ["input"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .mutates,
            availability: .deferred,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let input = try args.string("input")
            let output = args.stringOptional("output")
            let values = stringMap(from: args.raw["values"])
            let out = PDFToolsService.fillForm(input: input, output: output, values: values)
            return result(out, mutated: values.isEmpty ? [] : successPath(out, fallback: output))
        }
    }

    // MARK: - sign_pdf (deferred, mutates)

    private static func registerSignPDF() async {
        let schema = ToolSchema(
            name: "sign_pdf",
            description: """
            Offline: stamp a local signature image (PNG recommended) onto a PDF page. \
            Coordinates are PDF space (origin bottom-left). Does not capture a live \
            signature or call the network.
            """,
            parameters: .init(
                properties: [
                    "input": .init(type: "string", description: "Source PDF path."),
                    "output": .init(type: "string", description: "Output PDF path."),
                    "signature_path": .init(type: "string", description: "Path to signature image (PNG/JPEG)."),
                    "page": .init(type: "integer", description: "1-based page number (default 1)."),
                    "x": .init(type: "number", description: "Left edge of stamp (PDF points)."),
                    "y": .init(type: "number", description: "Bottom edge of stamp (PDF points)."),
                    "width": .init(type: "number", description: "Stamp width in points."),
                    "height": .init(type: "number", description: "Stamp height in points."),
                ],
                required: ["input", "output", "signature_path", "x", "y", "width", "height"]
            )
        )
        let meta = ToolRegistry.ToolMetadata(
            name: schema.name,
            category: .filesystem,
            permission: .mutates,
            availability: .deferred,
            schema: schema
        )
        await ToolRegistry.shared.registerDynamicTool(metadata: meta) { args, _ in
            let input = try args.string("input")
            let output = try args.string("output")
            let sig = try args.string("signature_path")
            let page = args.intOptional("page") ?? 1
            let x = number(args.raw["x"]) ?? 0
            let y = number(args.raw["y"]) ?? 0
            let w = number(args.raw["width"]) ?? 120
            let h = number(args.raw["height"]) ?? 40
            let out = PDFToolsService.signPDF(
                input: input,
                output: output,
                signaturePath: sig,
                page: page,
                x: CGFloat(x), y: CGFloat(y),
                width: CGFloat(w), height: CGFloat(h)
            )
            return result(out, mutated: successPath(out, fallback: output))
        }
    }

    // MARK: - Helpers

    private static func result(_ message: String, mutated: [String] = []) -> ToolResult {
        let isErr = message.hasPrefix("Error:") || message.hasPrefix("Error ")
        return ToolResult(content: message, isError: isErr, mutatedPaths: isErr ? [] : mutated)
    }

    private static func successPath(_ message: String, fallback: String?) -> [String] {
        guard !message.hasPrefix("Error") else { return [] }
        if let fallback, !fallback.isEmpty {
            return [(fallback as NSString).expandingTildeInPath]
        }
        return []
    }

    private static func mutationPaths(from args: [String: Any], message: String) -> [String] {
        guard !message.hasPrefix("Error") else { return [] }
        var paths: [String] = []
        if let o = args["output"] as? String, !o.isEmpty {
            paths.append((o as NSString).expandingTildeInPath)
        }
        if let d = args["output_dir"] as? String, !d.isEmpty {
            paths.append((d as NSString).expandingTildeInPath)
        }
        return paths
    }

    private static func stringMap(from any: Any?) -> [String: String] {
        guard let any else { return [:] }
        if let dict = any as? [String: String] { return dict }
        if let dict = any as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in dict {
                if let s = v as? String {
                    out[k] = s
                } else {
                    out[k] = String(describing: v)
                }
            }
            return out
        }
        if let s = any as? String,
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return stringMap(from: obj)
        }
        return [:]
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

// PDFToolsService.swift
// AgentOS — Claude Edition
//
// PDFKit-based PDF reading and manipulation. Tool entry points:
//   - extractText   → text + simple structure as markdown
//   - manipulate    → merge / split / extract_pages / rotate / watermark
//   - fillForm      → introspect or fill AcroForm fields
//   - signPDF       → stamp a pre-existing signature image
//
// App-target service: depends on PDFKit / AppKit which are out of scope for
// AgentCore.

import Foundation
import PDFKit
import AppKit

public enum PDFToolsService {

    // MARK: - extract_pdf_text

    /// Extract text from a PDF, optionally limited to a page range. Returns
    /// markdown with `## Page N` separators so the downstream model can
    /// reason about page boundaries.
    public static func extractText(path: String, pageRange: String? = nil) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: file not found at \(path)."
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open PDF (encrypted or malformed?)."
        }
        let pageCount = doc.pageCount
        let pages = parsePageRange(pageRange, max: pageCount)
        guard !pages.isEmpty else {
            return "Error: page range \"\(pageRange ?? "")\" resolved to no pages (document has \(pageCount))."
        }
        var out = "# \((expanded as NSString).lastPathComponent)\n_Total pages: \(pageCount). Showing \(pages.count) page(s)._\n\n"
        for p in pages {
            guard let page = doc.page(at: p - 1) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out += "## Page \(p)\n\n"
            out += text.isEmpty ? "_(no extractable text — may be a scan; try `OCRService.recognize` on a rendered image)_\n\n" : (text + "\n\n")
        }
        return out
    }

    // MARK: - manipulate_pdf

    /// Dispatches to the right sub-action. Each action validates its own
    /// arguments and writes to `output` (or `output_dir` for split).
    public static func manipulate(action: String, args: [String: Any]) -> String {
        switch action.lowercased() {
        case "merge":          return merge(args: args)
        case "split":          return split(args: args)
        case "extract_pages":  return extractPages(args: args)
        case "rotate":         return rotate(args: args)
        case "watermark":      return watermark(args: args)
        default:
            return "Error: unknown action \"\(action)\". Use one of: merge, split, extract_pages, rotate, watermark."
        }
    }

    // MARK: - Sub-actions

    private static func merge(args: [String: Any]) -> String {
        guard let inputs = args["inputs"] as? [String], inputs.count >= 2 else {
            return "Error: `inputs` must be an array of at least two PDF paths."
        }
        guard let output = (args["output"] as? String)?.trimmed, !output.isEmpty else {
            return "Error: `output` path is required."
        }
        let merged = PDFDocument()
        var writeIndex = 0
        for raw in inputs {
            let p = (raw as NSString).expandingTildeInPath
            guard let doc = PDFDocument(url: URL(fileURLWithPath: p)) else {
                return "Error: could not open \(raw)."
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    merged.insert(page, at: writeIndex)
                    writeIndex += 1
                }
            }
        }
        return write(merged, to: output, summary: "Merged \(inputs.count) PDFs (\(writeIndex) total pages)")
    }

    private static func split(args: [String: Any]) -> String {
        guard let input = (args["input"] as? String)?.trimmed, !input.isEmpty else {
            return "Error: `input` PDF path is required."
        }
        guard let outDir = (args["output_dir"] as? String)?.trimmed, !outDir.isEmpty else {
            return "Error: `output_dir` is required."
        }
        let expanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open \(input)."
        }
        let outDirExpanded = (outDir as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: outDirExpanded,
                                                    withIntermediateDirectories: true)
        } catch {
            return "Error creating output directory: \(error.localizedDescription)"
        }
        let base = (expanded as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "page"
        var written = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let one = PDFDocument()
            one.insert(page, at: 0)
            let dst = (outDirExpanded as NSString).appendingPathComponent("\(base)-p\(i + 1).pdf")
            if !one.write(toFile: dst) {
                return "Error: failed to write page \(i + 1)."
            }
            written += 1
        }
        return "Split into \(written) single-page PDFs in \(outDir)."
    }

    private static func extractPages(args: [String: Any]) -> String {
        guard let input = (args["input"] as? String)?.trimmed, !input.isEmpty else {
            return "Error: `input` is required."
        }
        guard let output = (args["output"] as? String)?.trimmed, !output.isEmpty else {
            return "Error: `output` is required."
        }
        guard let pagesArg = (args["pages"] as? String)?.trimmed, !pagesArg.isEmpty else {
            return "Error: `pages` is required (e.g. \"1-5,7,9-11\")."
        }
        let expanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open \(input)."
        }
        let pages = parsePageRange(pagesArg, max: doc.pageCount)
        guard !pages.isEmpty else {
            return "Error: page range \"\(pagesArg)\" resolved to no pages."
        }
        let out = PDFDocument()
        var idx = 0
        for p in pages {
            if let page = doc.page(at: p - 1) {
                out.insert(page, at: idx); idx += 1
            }
        }
        return write(out, to: output, summary: "Extracted pages \(pagesArg) → \(idx) page(s)")
    }

    private static func rotate(args: [String: Any]) -> String {
        guard let input = (args["input"] as? String)?.trimmed, !input.isEmpty else {
            return "Error: `input` is required."
        }
        guard let output = (args["output"] as? String)?.trimmed, !output.isEmpty else {
            return "Error: `output` is required."
        }
        let angleAny = args["angle"]
        guard let angle = integerExactly(angleAny), [90, 180, 270, -90].contains(angle) else {
            return "Error: `angle` must be 90, 180, 270 (or -90)."
        }
        let pagesArg = (args["pages"] as? String) ?? "all"
        let expanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open \(input)."
        }
        let targetPages = parsePageRange(pagesArg, max: doc.pageCount)

        let targetSet = Set(targetPages.map { $0 - 1 })
        for i in 0..<doc.pageCount where targetSet.contains(i) {
            if let page = doc.page(at: i) {
                let current = page.rotation
                page.rotation = (current + angle + 360) % 360
            }
        }
        return write(doc, to: output, summary: "Rotated \(targetPages.count) page(s) by \(angle)°")
    }

    private static func watermark(args: [String: Any]) -> String {
        guard let input = (args["input"] as? String)?.trimmed, !input.isEmpty else {
            return "Error: `input` is required."
        }
        guard let output = (args["output"] as? String)?.trimmed, !output.isEmpty else {
            return "Error: `output` is required."
        }
        guard let text = (args["text"] as? String)?.trimmed, !text.isEmpty else {
            return "Error: `text` is required."
        }
        let expanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open \(input)."
        }
        let opacity: CGFloat = CGFloat((args["opacity"] as? Double) ?? 0.18)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let watermarkPage = WatermarkOverlayPage(originalPage: page,
                                                     text: text,
                                                     opacity: opacity,
                                                     pageBounds: bounds)
            doc.removePage(at: i)
            doc.insert(watermarkPage, at: i)
        }
        return write(doc, to: output, summary: "Watermarked \(doc.pageCount) page(s) with \"\(text)\"")
    }

    // MARK: - build_pdf_form (fill an existing AcroForm)
    //
    // With no `values` supplied, returns the list of field names so the
    // agent can introspect the form first.

    public static func fillForm(input: String,
                                output: String?,
                                values: [String: String]) -> String {
        let expanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: expanded)) else {
            return "Error: could not open \(input)."
        }

        // Introspection mode: caller passed no values.
        if values.isEmpty {
            var fields: [(page: Int, name: String, type: String, value: String)] = []
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p) else { continue }
                for ann in page.annotations where isFormWidget(ann) {
                    let name = ann.fieldName ?? "(unnamed)"
                    let type = ann.widgetFieldType.rawValue
                    let current = ann.widgetStringValue ?? ""
                    fields.append((p + 1, name, type, current))
                }
            }
            if fields.isEmpty { return "No form fields detected in \(input)." }
            var out = "Fields detected (\(fields.count)) in \(input):\n"
            for f in fields {
                out += "  · Page \(f.page) · \(f.name) [\(f.type)]" +
                       (f.value.isEmpty ? "" : " = \"\(f.value)\"") + "\n"
            }
            out += "\nCall again with `values` to fill, and `output` to save the filled PDF."
            return out
        }

        // Fill mode.
        guard let output = output?.trimmed, !output.isEmpty else {
            return "Error: `output` path is required when filling form values."
        }
        var setCount = 0
        var knownNames = Set<String>()
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            for ann in page.annotations where isFormWidget(ann) {
                if let name = ann.fieldName {
                    knownNames.insert(name)
                    if let value = values[name] {
                        ann.widgetStringValue = value
                        setCount += 1
                    }
                }
            }
        }
        let unknown = values.keys.filter { !knownNames.contains($0) }.sorted()
        var msg = "Filled \(setCount) field(s)"
        if !unknown.isEmpty { msg += " (unmatched: \(unknown.joined(separator: ", ")))" }
        return write(doc, to: output, summary: msg)
    }

    private static func isFormWidget(_ a: PDFAnnotation) -> Bool {
        // A non-nil fieldName is a reliable proxy for "this is a form widget".
        return a.fieldName != nil
    }

    // MARK: - sign_pdf (stamp a pre-existing signature image)
    //
    // Headless — does not capture a live signature. Takes a signature PNG
    // (transparent background recommended) and overlays it as a stamp
    // annotation at the given page/position/size. PDF coordinates: origin
    // is bottom-left of the page.

    public static func signPDF(input: String,
                               output: String,
                               signaturePath: String,
                               page: Int,
                               x: CGFloat, y: CGFloat,
                               width: CGFloat, height: CGFloat) -> String {
        let inExpanded = (input as NSString).expandingTildeInPath
        guard let doc = PDFDocument(url: URL(fileURLWithPath: inExpanded)) else {
            return "Error: could not open \(input)."
        }
        let pageIdx = max(1, page) - 1
        guard pageIdx < doc.pageCount, let target = doc.page(at: pageIdx) else {
            return "Error: page \(page) is out of range (document has \(doc.pageCount))."
        }
        let sigExpanded = (signaturePath as NSString).expandingTildeInPath
        guard let nsImage = NSImage(contentsOfFile: sigExpanded),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Error: could not read signature image at \(signaturePath)."
        }

        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let stamp = SignatureStampAnnotation(bounds: bounds, cgImage: cgImage)
        stamp.shouldDisplay = true
        target.addAnnotation(stamp)

        let outExpanded = (output as NSString).expandingTildeInPath
        if doc.write(toFile: outExpanded) {
            return "Stamped signature on page \(page) at (\(Int(x)), \(Int(y))) size \(Int(width))×\(Int(height)). Wrote \(output)."
        }
        return "Error: failed to write \(output)."
    }

    // MARK: - Shared helpers

    private static func write(_ doc: PDFDocument, to path: String, summary: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if doc.write(toFile: expanded) {
            return "\(summary). Wrote \(path)."
        } else {
            return "Error: failed to write \(path)."
        }
    }

    /// Parse "1-5,7,9-11" into [1,2,3,4,5,7,9,10,11]. Out-of-range values
    /// are dropped silently. Empty/nil/"all" = full range. Never builds
    /// an inverted ClosedRange (empty PDF / "4-10" on a 3-page doc).
    static func parsePageRange(_ s: String?, max: Int) -> [Int] {
        guard max >= 1 else { return [] }
        let full = Array(1...max)
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return full
        }
        if s.lowercased() == "all" { return full }
        var pages: [Int] = []
        for chunk in s.split(separator: ",") {
            let t = chunk.trimmingCharacters(in: .whitespaces)
            if t.contains("-") {
                let parts = t.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, parts[0] >= 1, parts[1] >= parts[0] {
                    pages.append(contentsOf: clampedClosedRange(from: parts[0], to: parts[1], max: max))
                }
            } else if let p = Int(t), p >= 1, p <= max {
                pages.append(p)
            }
        }
        // de-dupe but keep order
        var seen = Set<Int>(); var out: [Int] = []
        for p in pages where !seen.contains(p) { seen.insert(p); out.append(p) }
        return out
    }

    /// Intersection of `from...to` with `1...max`. Empty when they don't overlap.
    private static func clampedClosedRange(from: Int, to: Int, max: Int) -> [Int] {
        let lo = from
        let hi = min(to, max)
        guard lo <= hi else { return [] }
        return Array(lo...hi)
    }

    /// Int conversion that refuses out-of-range Doubles (e.g. 1e20) instead of trapping.
    private static func integerExactly(_ any: Any?) -> Int? {
        if let n = any as? NSNumber {
            return Int(exactly: n.doubleValue)
        }
        if let d = any as? Double {
            return Int(exactly: d)
        }
        if let i = any as? Int {
            return i
        }
        if let s = any as? String {
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

// MARK: - Watermark overlay page

/// Wraps an existing PDFPage and draws a diagonal text watermark on top
/// while preserving the original content.
private final class WatermarkOverlayPage: PDFPage {
    private let originalPage: PDFPage
    private let watermarkText: String
    private let watermarkOpacity: CGFloat
    private let pageBounds: CGRect

    init(originalPage: PDFPage, text: String, opacity: CGFloat, pageBounds: CGRect) {
        self.originalPage = originalPage
        self.watermarkText = text
        self.watermarkOpacity = opacity
        self.pageBounds = pageBounds
        super.init()
    }

    override func bounds(for box: PDFDisplayBox) -> CGRect {
        return originalPage.bounds(for: box)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        // Draw the original page first.
        originalPage.draw(with: box, to: context)

        // Diagonal text watermark, centered.
        context.saveGState()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black.withAlphaComponent(watermarkOpacity)
        ]
        let attr = NSAttributedString(string: watermarkText, attributes: attrs)
        let size = attr.size()
        let cx = pageBounds.midX
        let cy = pageBounds.midY
        context.translateBy(x: cx, y: cy)
        context.rotate(by: .pi / 4)
        attr.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        context.restoreGState()
    }
}

// MARK: - Signature stamp annotation

/// Custom PDF stamp annotation that draws an image at the annotation's
/// bounds. PDFKit's `.stamp` annotation type allows custom drawing via
/// `draw(with:in:)` — we use it to render the signature image.
private final class SignatureStampAnnotation: PDFAnnotation {
    private let cgImage: CGImage

    init(bounds: CGRect, cgImage: CGImage) {
        self.cgImage = cgImage
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

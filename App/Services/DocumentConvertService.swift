// DocumentConvertService.swift
// AgentOS — Claude Edition
//
// Universal text-format converter. Resolution order:
//   1. Pandoc (if installed) — covers ~40 formats.
//   2. macOS `textutil` — RTF / DOCX / HTML / TXT round-trips, no install.
//   3. NSAttributedString — last-resort native fallback.
//
// App-target service: shells out via Process and uses AppKit's
// NSAttributedString document importers. Not portable to AgentCore.

import Foundation
import AppKit

public enum DocumentConvertService {

    /// Convert a source document to a target format.
    /// - Parameters:
    ///   - input: Path to source file (tilde-expanded).
    ///   - output: Path to write the converted file (tilde-expanded).
    ///   - from: Source format string (md, markdown, html, docx, rtf, odt,
    ///           epub, pdf, txt, …). When `nil` / empty, the source
    ///           extension is used.
    ///   - to: Target format string. When `nil` / empty, the target
    ///         extension is used.
    public static func convert(input: String,
                               output: String,
                               from: String? = nil,
                               to: String? = nil) -> String {
        guard !input.isEmpty, !output.isEmpty else {
            return "Error: `input` and `output` are required."
        }
        let inExpanded = (input as NSString).expandingTildeInPath
        let outExpanded = (output as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: inExpanded) else {
            return "Error: input file not found at \(input)."
        }

        let fromFmt = normalize(from?.isEmpty == false ? from! : (inExpanded as NSString).pathExtension)
        let toFmt   = normalize(to?.isEmpty == false ? to! : (outExpanded as NSString).pathExtension)
        guard !fromFmt.isEmpty, !toFmt.isEmpty else {
            return "Error: could not infer source/target format. Provide `from` and `to`."
        }
        if fromFmt == toFmt {
            // Same path + same format: do not delete the only copy.
            let inURL = URL(fileURLWithPath: inExpanded).standardizedFileURL
            let outURL = URL(fileURLWithPath: outExpanded).standardizedFileURL
            if inURL.path == outURL.path {
                return "Source and target format identical — already at \(output)."
            }
            do {
                if FileManager.default.fileExists(atPath: outExpanded) {
                    try FileManager.default.removeItem(atPath: outExpanded)
                }
                try FileManager.default.copyItem(atPath: inExpanded, toPath: outExpanded)
                return "Source and target format identical — copied to \(output)."
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }

        // 1. Pandoc
        if let pandoc = locatePandoc() {
            if let result = runPandoc(pandoc, input: inExpanded, output: outExpanded,
                                      fromFmt: fromFmt, toFmt: toFmt) {
                return result
            }
        }

        // 2. textutil — only covers the macOS office quartet
        if let result = runTextutil(input: inExpanded, output: outExpanded,
                                    fromFmt: fromFmt, toFmt: toFmt) {
            return result
        }

        // 3. NSAttributedString last-resort
        if let result = runAttributedString(input: inExpanded, output: outExpanded,
                                            fromFmt: fromFmt, toFmt: toFmt) {
            return result
        }

        return """
        Error: no available converter can do \(fromFmt) → \(toFmt). \
        Install Pandoc for full coverage (`brew install pandoc`). \
        Without Pandoc, supported targets are limited to txt/rtf/html/docx via textutil.
        """
    }

    // MARK: - Pandoc

    private static func locatePandoc() -> String? {
        for path in ["/opt/homebrew/bin/pandoc",
                     "/usr/local/bin/pandoc",
                     "/usr/bin/pandoc"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Try PATH lookup via /usr/bin/which.
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["pandoc"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        } catch { /* fall through */ }
        return nil
    }

    private static func runPandoc(_ pandoc: String,
                                  input: String, output: String,
                                  fromFmt: String, toFmt: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pandoc)
        let pFrom = pandocFormat(fromFmt)
        let pTo   = pandocFormat(toFmt)
        task.arguments = ["-f", pFrom, "-t", pTo, "-o", output, input]
        // Standalone for formats that need it (PDF/EPUB/DOCX always benefit).
        if ["pdf", "epub", "docx", "odt", "html"].contains(toFmt) {
            task.arguments?.append("--standalone")
        }
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0,
               FileManager.default.fileExists(atPath: output) {
                let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
                return "Converted via Pandoc: \(fromFmt) → \(toFmt) (\(size) bytes)."
            }
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "unknown error"
            return "Error: Pandoc failed (exit \(task.terminationStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return nil // Let the next fallback try.
        }
    }

    private static func pandocFormat(_ f: String) -> String {
        switch f {
        case "md", "markdown": return "markdown"
        case "txt", "text":    return "plain"
        case "html", "htm":    return "html"
        case "docx":           return "docx"
        case "odt":            return "odt"
        case "rtf":            return "rtf"
        case "epub":           return "epub"
        case "latex", "tex":   return "latex"
        case "rst":            return "rst"
        case "org":            return "org"
        case "pdf":            return "pdf"
        default:               return f
        }
    }

    // MARK: - textutil

    private static let textutilFormats: Set<String> = ["rtf", "rtfd", "html", "doc", "docx", "txt", "webarchive"]

    private static func runTextutil(input: String, output: String,
                                    fromFmt: String, toFmt: String) -> String? {
        guard textutilFormats.contains(fromFmt) && textutilFormats.contains(toFmt) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        task.arguments = ["-convert", toFmt, "-output", output, input]
        let errPipe = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0,
               FileManager.default.fileExists(atPath: output) {
                return "Converted via textutil: \(fromFmt) → \(toFmt)."
            }
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "unknown error"
            return "Error: textutil failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return nil
        }
    }

    // MARK: - NSAttributedString native fallback

    private static func runAttributedString(input: String, output: String,
                                            fromFmt: String, toFmt: String) -> String? {
        let inURL = URL(fileURLWithPath: input)
        let docType: NSAttributedString.DocumentType?
        switch fromFmt {
        case "rtf":           docType = .rtf
        case "html", "htm":   docType = .html
        case "txt", "text":   docType = .plain
        case "doc":           docType = .docFormat
        case "docx":          docType = .officeOpenXML
        default:              docType = nil
        }
        guard let dt = docType,
              let attr = try? NSAttributedString(url: inURL,
                                                 options: [.documentType: dt],
                                                 documentAttributes: nil) else { return nil }
        let outType: NSAttributedString.DocumentType?
        switch toFmt {
        case "rtf":         outType = .rtf
        case "html", "htm": outType = .html
        case "txt", "text": outType = .plain
        case "docx":        outType = .officeOpenXML
        default:            outType = nil
        }
        guard let ot = outType else { return nil }
        do {
            let data: Data
            if ot == .plain {
                data = (attr.string).data(using: .utf8) ?? Data()
            } else {
                data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                     documentAttributes: [.documentType: ot])
            }
            try data.write(to: URL(fileURLWithPath: output))
            return "Converted via NSAttributedString: \(fromFmt) → \(toFmt)."
        } catch {
            return "Error: native fallback failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix(".") { t.removeFirst() }
        if t == "markdown" { return "md" }
        if t == "text"     { return "txt" }
        return t
    }
}

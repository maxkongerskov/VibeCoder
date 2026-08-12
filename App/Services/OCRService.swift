// OCRService.swift
// AgentOS — Claude Edition
//
// Apple Vision-based text recognition. Wraps `VNRecognizeTextRequest` in an
// async API and returns the recognized text in reading order (top-to-bottom,
// left-to-right).
//
// App-target service: depends on AppKit/Vision/CoreImage which can't go in
// AgentCore (cross-platform Swift package).

import Foundation
import AppKit
@preconcurrency import Vision
import CoreImage

public enum OCRService {

    /// Recognize text in a single image file (PNG/JPEG/TIFF/HEIC/etc.) or a
    /// single PDF page rendered as an image. For text PDFs use
    /// `PDFToolsService.extractText` — this is for scans and screenshots.
    ///
    /// - Parameters:
    ///   - path: Path to the image (tilde-expanded).
    ///   - accurate: `true` → `.accurate` recognition + language correction.
    ///               `false` → `.fast`.
    ///   - languages: BCP-47 language hints (e.g. `["en", "es"]`). Pass an
    ///                empty array to let Vision auto-detect. Default is
    ///                `["en"]` since AppSettings does not (yet) carry an
    ///                `ocrLanguages` field in Claude Edition.
    public static func recognize(path: String,
                                 accurate: Bool = true,
                                 languages: [String] = ["en"]) async -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: file not found at \(path)."
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Error: could not decode image at \(path). Vision requires a raster image (PNG, JPEG, TIFF, HEIC)."
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    continuation.resume(returning: "Error: \(err.localizedDescription)")
                    return
                }
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Sort by reading order: top→bottom (y descending in Vision's
                // bottom-left origin) then left→right.
                let sorted = obs.sorted {
                    if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
                        return $0.boundingBox.midY > $1.boundingBox.midY
                    }
                    return $0.boundingBox.midX < $1.boundingBox.midX
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                if lines.isEmpty {
                    continuation.resume(returning: "_No text detected._")
                } else {
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
            }
            request.recognitionLevel = accurate ? .accurate : .fast
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }
            request.usesLanguageCorrection = accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "Error: Vision failed — \(error.localizedDescription)")
                }
            }
        }
    }
}

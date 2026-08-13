//
//  ContextAttachmentFormatter.swift
//
//  Serializes composer attachments into the user message the agent reads.
//
//  Wave C W13: include file **contents** (UTF-8, size-capped) so @-mentions
//  are useful without a follow-up read_file. Paths alone left the model
//  blind to what the user attached.
//
//  Vision: image attachments are encoded as `ChatImagePayload` (base64)
//  and sent as multimodal `image_url` parts — not as binary-omitted notes.
//

import Foundation

public enum ContextAttachmentFormatter {

    /// Per-file content budget (bytes of UTF-8 string). Larger files are
    /// truncated with a marker; binary / unreadable files get a note.
    public static let defaultMaxBytesPerFile = 32_768

    /// Text + vision images produced from composer attachments.
    public struct MultimodalCompose: Sendable, Equatable {
        public var text: String
        public var images: [ChatImagePayload]
        public init(text: String, images: [ChatImagePayload] = []) {
            self.text = text
            self.images = images
        }

        /// True when there is nothing to send (no text and no images).
        public var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        }
    }

    public static func attachmentPrefix(
        for attachments: [ContextAttachment],
        maxBytesPerFile: Int = defaultMaxBytesPerFile,
        fileManager: FileManager = .default,
        encodedImagePaths: Set<String> = []
    ) -> String {
        // Keep non-images plus any image that failed to encode so missing/
        // corrupt shots still appear in the prompt (not dropped from both
        // `images` and this prefix).
        let included = attachments.filter { attachment in
            if !VisionImageEncoder.isImagePath(attachment.path) { return true }
            let expanded = (attachment.path as NSString).expandingTildeInPath
            return !encodedImagePaths.contains(expanded) && !encodedImagePaths.contains(attachment.path)
        }
        guard !included.isEmpty else { return "" }
        var lines = ["[Attached context files]"]
        for attachment in included {
            var line = "- @\(attachment.displayName) (\(attachment.path))"
            if let size = attachment.byteSize {
                line += " — \(formatBytes(size))"
            }
            lines.append(line)
            lines.append(contentsOf: contentBlock(
                path: attachment.path,
                maxBytes: maxBytesPerFile,
                fileManager: fileManager))
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    public static func composeUserMessage(
        text: String,
        attachments: [ContextAttachment],
        maxBytesPerFile: Int = defaultMaxBytesPerFile,
        fileManager: FileManager = .default
    ) -> String {
        composeMultimodal(
            text: text,
            attachments: attachments,
            maxBytesPerFile: maxBytesPerFile,
            fileManager: fileManager
        ).text
    }

    /// Compose text (with non-image attachment contents) + vision payloads
    /// for image attachments. Prefer this over `composeUserMessage` when
    /// the caller can pass images into `AgentLoop` / the wire encoder.
    public static func composeMultimodal(
        text: String,
        attachments: [ContextAttachment],
        maxBytesPerFile: Int = defaultMaxBytesPerFile,
        fileManager: FileManager = .default
    ) -> MultimodalCompose {
        let images = VisionImageEncoder.payloads(
            fromPaths: attachments.map { ($0.path, $0.displayName) }
        )
        var textOut = text
        if !images.isEmpty {
            let names = images.map { $0.displayName ?? "image" }.joined(separator: ", ")
            let note = "[Attached images for vision: \(names)]\n\n"
            textOut = note + textOut
        }
        var encodedImagePaths = Set<String>()
        for image in images {
            if let source = image.sourcePath { encodedImagePaths.insert(source) }
        }
        let prefix = attachmentPrefix(
            for: attachments,
            maxBytesPerFile: maxBytesPerFile,
            fileManager: fileManager,
            encodedImagePaths: encodedImagePaths)
        if !prefix.isEmpty {
            textOut = prefix + textOut
        }
        return MultimodalCompose(text: textOut, images: images)
    }

    // MARK: - Internals

    private static func contentBlock(
        path: String,
        maxBytes: Int,
        fileManager: FileManager
    ) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: expanded) else {
            return ["  (file missing on disk — agent should use read_file if needed)"]
        }
        // Images that reach this path failed vision encode (missing ones
        // already returned above). Keep a prompt-visible note.
        if VisionImageEncoder.isImagePath(expanded) {
            return ["  (image missing or unreadable — not sent as vision attachment)"]
        }
        guard let data = fileManager.contents(atPath: expanded) else {
            return ["  (could not read file — agent should use read_file)"]
        }
        // Reject obvious binary (NUL in first 8k).
        let probe = data.prefix(8192)
        if probe.contains(0) {
            return ["  (binary file omitted; use read_file / specialized tools)"]
        }
        guard var text = String(data: data, encoding: .utf8) else {
            return ["  (non-UTF-8 file omitted; use read_file if needed)"]
        }
        var truncated = false
        if text.utf8.count > maxBytes {
            text = truncateToValidUTF8(text, maxBytes: maxBytes)
            truncated = true
        }
        var block = ["```", text, "```"]
        if truncated {
            block.append("  …[truncated at \(formatBytes(maxBytes))]")
        }
        return block
    }

    /// Byte-cap `text` without splitting a multi-byte scalar. Backs up from
    /// `maxBytes` to a valid UTF-8 boundary instead of falling back to the
    /// full string when `String(bytes:encoding:)` fails mid-character.
    private static func truncateToValidUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var data = Data(text.utf8.prefix(maxBytes))
        while !data.isEmpty {
            if let sliced = String(data: data, encoding: .utf8) {
                return sliced
            }
            data.removeLast()
        }
        return ""
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

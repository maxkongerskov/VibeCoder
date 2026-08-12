//
//  ChatImagePayload.swift
//
//  Multimodal image bytes carried on a ChatMessage so vision models
//  (Gemma 4, Qwen-VL, GPT-4o, …) receive real pixels on the wire —
//  not just a file path in prose.
//

import Foundation

/// One image attached to a chat message for vision-capable models.
///
/// Wire form is an OpenAI-compatible data URL:
/// `data:<mimeType>;base64,<base64Data>`.
public struct ChatImagePayload: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// MIME type, e.g. `image/png`, `image/jpeg`.
    public var mimeType: String
    /// Raw base64 (no `data:` prefix).
    public var base64Data: String
    /// Optional original path (for UI / re-attach notes).
    public var sourcePath: String?
    /// Optional display name (file name).
    public var displayName: String?

    public init(
        id: UUID = UUID(),
        mimeType: String,
        base64Data: String,
        sourcePath: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.sourcePath = sourcePath
        self.displayName = displayName
    }

    /// OpenAI / Ollama / LM Studio `image_url.url` value.
    public var dataURL: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    /// Rough decoded byte size (for budgeting).
    public var approxDecodedBytes: Int {
        // base64 expands ~4/3; this underestimates slightly with padding.
        (base64Data.utf8.count * 3) / 4
    }
}

//
//  ArtifactFilePreviewView.swift
//

import SwiftUI

struct ArtifactFilePreviewView: View {
    let content: String
    let path: String
    var fontSize: CGFloat = 13

    private var language: String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md", "markdown": return "markdown"
        case "json": return "json"
        case "py": return "python"
        case "sh": return "bash"
        default: return ext.isEmpty ? nil : ext
        }
    }

    var body: some View {
        CodeBlockView(language: language, code: content, fontSize: fontSize)
    }
}
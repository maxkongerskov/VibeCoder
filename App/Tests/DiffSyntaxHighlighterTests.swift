//
//  DiffSyntaxHighlighterTests.swift
//

import XCTest
import AppKit
@testable import VibeCoderApp

@MainActor
final class DiffSyntaxHighlighterTests: XCTestCase {

    // Use NSColor for comparisons — avoids non-Sendable key path
    // issues with SwiftUI's Color in Swift 6 strict concurrency.
    private let keywordColor = NSColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1)
    private let addColor = NSColor(red: 0.20, green: 0.62, blue: 0.32, alpha: 1)

    func testSwiftKeywordsHighlightedOnAddedDiffLines() {
        let attr = DiffSyntaxHighlighter.attributedString(
            from: "+    func greet() {}",
            languageHint: "swift"
        )
        XCTAssertEqual(String(attr.characters), "+    func greet() {}")

        // Convert to NSAttributedString to check attributes via
        // string-based keys (avoids non-Sendable key path formation).
        let nsAttr = NSMutableAttributedString(attr)
        var sawKeyword = false
        var sawAddTint = false

        nsAttr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: nsAttr.length)) { value, _, _ in
            if let color = value as? NSColor {
                if self.colorMatch(color, self.keywordColor) { sawKeyword = true }
                if self.colorMatch(color, self.addColor) { sawAddTint = true }
            }
        }

        XCTAssertTrue(sawKeyword)
        XCTAssertTrue(sawAddTint)
    }

    func testRemovedDiffLinesKeepSwiftKeywordHighlighting() {
        let attr = DiffSyntaxHighlighter.attributedString(
            from: "-    let value = 1",
            languageHint: "swift"
        )

        let nsAttr = NSMutableAttributedString(attr)
        var sawKeyword = false

        nsAttr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: nsAttr.length)) { value, _, _ in
            if let color = value as? NSColor {
                if self.colorMatch(color, self.keywordColor) { sawKeyword = true }
            }
        }

        XCTAssertTrue(sawKeyword)
    }

    // Compare NSColor values by RGBA components (ignoring color space
    // differences that can arise from dynamic system colors).
    private func colorMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        let a = a.usingColorSpace(.sRGB) ?? a
        let b = b.usingColorSpace(.sRGB) ?? b
        return a.redComponent == b.redComponent &&
               a.greenComponent == b.greenComponent &&
               a.blueComponent == b.blueComponent
    }
}
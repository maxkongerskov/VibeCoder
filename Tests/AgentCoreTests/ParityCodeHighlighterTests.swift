//
//  ParityCodeHighlighterTests.swift
//  Wave U1 `hl` — chat code-block tokenizer.
//

import XCTest
@testable import AgentCore

final class ParityCodeHighlighterTests: XCTestCase {

    func testUnknownAndNilLanguageReturnEmpty() {
        XCTAssertTrue(CodeHighlighter.tokens(for: "func x() {}", language: nil).isEmpty)
        XCTAssertTrue(CodeHighlighter.tokens(for: "func x() {}", language: "").isEmpty)
        XCTAssertTrue(CodeHighlighter.tokens(for: "func x() {}", language: "mermaid").isEmpty)
        XCTAssertTrue(CodeHighlighter.tokens(for: "func x() {}", language: "objective-c").isEmpty)
    }

    func testKnownLanguagesIncludeCoreSet() {
        let known = Set(CodeHighlighter.knownLanguages())
        for id in ["swift", "python", "javascript", "typescript", "json", "yaml",
                   "bash", "go", "rust", "c", "cpp", "sql", "html", "xml"] {
            XCTAssertTrue(known.contains(id), "missing \(id)")
        }
    }

    func testSwiftFuncLetAndNumber() {
        let code = "func greet() { let x = 1 }"
        let tokens = CodeHighlighter.tokens(for: code, language: "swift")
        XCTAssertEqual(count(tokens, .keyword), 2)
        XCTAssertEqual(texts(code, tokens, .keyword), ["func", "let"])
        XCTAssertEqual(count(tokens, .number), 1)
        XCTAssertEqual(texts(code, tokens, .number), ["1"])
        XCTAssertEqual(texts(code, tokens, .typeable), ["greet", "x"])
    }

    func testPythonDefAndString() {
        let code = "def hello():\n    s = \"world\""
        let tokens = CodeHighlighter.tokens(for: code, language: "py")
        XCTAssertEqual(texts(code, tokens, .keyword), ["def"])
        XCTAssertEqual(texts(code, tokens, .string), ["\"world\""])
        XCTAssertEqual(texts(code, tokens, .typeable), ["hello"])
    }

    func testJSBacktickString() {
        let code = "const msg = `hello ${name}`"
        let tokens = CodeHighlighter.tokens(for: code, language: "js")
        XCTAssertEqual(texts(code, tokens, .keyword), ["const"])
        XCTAssertEqual(texts(code, tokens, .string), ["`hello ${name}`"])
        XCTAssertEqual(texts(code, tokens, .typeable), ["msg"])
    }

    func testJSONKeysVsStrings() {
        let code = "{\"name\": \"Ada\", \"n\": 1}"
        let tokens = CodeHighlighter.tokens(for: code, language: "json")
        XCTAssertEqual(texts(code, tokens, .typeable), ["\"name\"", "\"n\""])
        XCTAssertEqual(texts(code, tokens, .string), ["\"Ada\""])
        XCTAssertEqual(texts(code, tokens, .number), ["1"])
    }

    func testSQLComment() {
        let code = "select id from t -- only active"
        let tokens = CodeHighlighter.tokens(for: code, language: "sql")
        XCTAssertEqual(texts(code, tokens, .commentLine), ["-- only active"])
        XCTAssertEqual(texts(code, tokens, .keyword), ["select", "from"])
    }

    func testEscapesDoNotBreakStringPairing() {
        let code = #"let a = "foo\"bar"; let b = "z""#
        let tokens = CodeHighlighter.tokens(for: code, language: "swift")
        let strings = texts(code, tokens, .string)
        XCTAssertEqual(strings.count, 2, "escaped quote must not swallow the next string")
        XCTAssertEqual(strings[0], #" "foo\"bar" "#.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(strings[1], "\"z\"")
        XCTAssertEqual(texts(code, tokens, .keyword), ["let", "let"])
    }

    func testEscapedBackslashThenQuoteCloses() {
        let code = #"let a = "foo\\"; let b = "ok""#
        let strings = texts(code, CodeHighlighter.tokens(for: code, language: "swift"), .string)
        XCTAssertEqual(strings.count, 2)
        XCTAssertEqual(strings[1], "\"ok\"")
    }

    func testTenKCharSingleLineNoCrashAndFast() {
        let piece = "let x = \"ab\"; "
        let code = String(repeating: piece, count: 800)
        XCTAssertGreaterThanOrEqual(code.count, 10_000)
        XCTAssertFalse(code.contains("\n"))

        let start = DispatchTime.now()
        let tokens = CodeHighlighter.tokens(for: code, language: "swift")
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(elapsedMs, 200, "10k-char scan took \(elapsedMs)ms")
        XCTAssertEqual(count(tokens, .keyword), 800)
        XCTAssertEqual(count(tokens, .string), 800)

        let blob = String(repeating: "x", count: 10_000)
        let blobTokens = CodeHighlighter.tokens(for: blob, language: "javascript")
        XCTAssertTrue(blobTokens.filter { $0.kind != .plain }.isEmpty)
    }

    func testLanguageAliasesAndHeaderCase() {
        XCTAssertFalse(CodeHighlighter.tokens(for: "fn x() {}", language: "RS").isEmpty)
        XCTAssertFalse(CodeHighlighter.tokens(for: "package main", language: "Go").isEmpty)
        XCTAssertFalse(CodeHighlighter.tokens(for: "int main() {}", language: "h").isEmpty)
    }

    func testHTMLCommentAndTag() {
        let code = "<!-- n --><div class=\"x\">hi</div>"
        let tokens = CodeHighlighter.tokens(for: code, language: "html")
        XCTAssertEqual(texts(code, tokens, .commentBlock), ["<!-- n -->"])
        XCTAssertEqual(texts(code, tokens, .keyword), ["div", "div"])
        XCTAssertEqual(texts(code, tokens, .typeable), ["class"])
        XCTAssertEqual(texts(code, tokens, .string), ["\"x\""])
    }

    // MARK: - Helpers

    private func count(_ tokens: [CodeToken], _ kind: CodeTokenKind) -> Int {
        tokens.filter { $0.kind == kind }.count
    }

    private func texts(_ code: String, _ tokens: [CodeToken], _ kind: CodeTokenKind) -> [String] {
        tokens.filter { $0.kind == kind }.map { String(code[$0.range]) }
    }
}

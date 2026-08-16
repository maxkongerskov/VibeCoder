//
//  CodeHighlighter.swift
//  AgentCore
//
//  Single-pass O(n) keyword highlighter for chat fenced code blocks.
//  No regex, no UI imports. Unknown / nil language → no tokens (plain).
//

import Foundation

public enum CodeTokenKind: String, Equatable, Sendable {
    case keyword
    case string
    case commentLine
    case commentBlock
    case number
    case typeable
    case plain
}

/// Highlighted span. `range` is a `String.Index` range into the exact `code`
/// string passed to `CodeHighlighter.tokens(for:language:)`.
/// Only non-`plain` tokens are emitted, in source order, non-overlapping.
/// Gaps (and an empty array) are unstyled / plain.
public struct CodeToken: Equatable, Sendable {
    public let range: Range<String.Index>
    public let kind: CodeTokenKind

    public init(range: Range<String.Index>, kind: CodeTokenKind) {
        self.range = range
        self.kind = kind
    }
}

public enum CodeHighlighter: Sendable {

    /// Canonical ids (aliases are accepted by `tokens` but not listed here).
    public static func knownLanguages() -> [String] {
        [
            "bash", "c", "cpp", "go", "html", "javascript", "json",
            "python", "rust", "sql", "swift", "typescript", "xml", "yaml",
        ]
    }

    public static func tokens(for code: String, language: String?) -> [CodeToken] {
        guard let id = canonicalLanguage(language) else { return [] }
        switch id {
        case "json":
            return JSONScan.run(code)
        case "html", "xml":
            return MarkupScan.run(code)
        default:
            guard let spec = spec(for: id) else { return [] }
            return GenericScan.run(code, spec: spec)
        }
    }

    // MARK: - Language map

    /// Lowercased fence tag / alias → canonical id. Unknown → nil.
    private static func canonicalLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        var head = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        if let space = head.firstIndex(where: \.isWhitespace) {
            head = String(head[..<space])
        }
        if head.hasPrefix(".") { head.removeFirst() }
        return aliasMap[head.lowercased()]
    }

    private static let aliasMap: [String: String] = [
        "swift": "swift",
        "python": "python", "py": "python",
        "javascript": "javascript", "js": "javascript", "jsx": "javascript",
        "typescript": "typescript", "ts": "typescript", "tsx": "typescript",
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "bash": "bash", "sh": "bash", "zsh": "bash", "shell": "bash",
        "go": "go", "golang": "go",
        "rust": "rust", "rs": "rust",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hh": "cpp",
        "hpp": "cpp", "c++": "cpp",
        "sql": "sql",
        "html": "html", "htm": "html", "xhtml": "html",
        "xml": "xml", "svg": "xml",
    ]

    private static func spec(for id: String) -> Spec? {
        switch id {
        case "swift": return .swift
        case "python": return .python
        case "javascript": return .javascript
        case "typescript": return .typescript
        case "yaml": return .yaml
        case "bash": return .bash
        case "go": return .go
        case "rust": return .rust
        case "c": return .c
        case "cpp": return .cpp
        case "sql": return .sql
        default: return nil
        }
    }
}

// MARK: - Language spec

private struct Spec: Sendable {
    var keywords: Set<String>
    var declarators: Set<String>
    var builtinTypes: Set<String>
    var lineComment: String?
    var blockOpen: String?
    var blockClose: String?
    var doubleQuote: Bool
    var singleQuote: Bool
    var backtick: Bool
    /// Python `"""` / `'''` → commentBlock (docstrings).
    var tripleAsBlockComment: Bool
    var escape: StringEscape
    var typeableUppercase: Bool
    var yamlKeys: Bool
    var swiftBacktickIdent: Bool
    var rustLifetime: Bool

    enum StringEscape: Sendable {
        case backslash
        case doubledQuote
    }

    static let swift = Spec(
        keywords: [
            "func", "struct", "class", "enum", "protocol", "actor", "extension",
            "import", "let", "var", "return", "if", "else", "guard", "switch",
            "case", "default", "for", "while", "repeat", "break", "continue",
            "defer", "throw", "throws", "rethrows", "try", "catch", "as", "is",
            "in", "where", "self", "Self", "nil", "true", "false", "some", "any",
            "async", "await", "static", "public", "private", "internal",
            "fileprivate", "open", "final", "override", "required", "lazy",
            "weak", "unowned", "init", "deinit", "get", "set", "inout",
            "associatedtype", "typealias", "operator", "consuming", "borrowing",
        ],
        declarators: [
            "func", "struct", "class", "enum", "protocol", "actor", "extension",
            "typealias", "associatedtype", "let", "var", "import",
        ],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: false,
        backtick: false,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: true,
        rustLifetime: false
    )

    static let python = Spec(
        keywords: [
            "def", "class", "return", "if", "elif", "else", "for", "while",
            "break", "continue", "pass", "import", "from", "as", "in", "not",
            "and", "or", "is", "None", "True", "False", "try", "except",
            "finally", "raise", "with", "yield", "lambda", "global", "nonlocal",
            "assert", "async", "await", "del",
        ],
        declarators: ["def", "class"],
        builtinTypes: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes"],
        lineComment: "#",
        blockOpen: nil,
        blockClose: nil,
        doubleQuote: true,
        singleQuote: true,
        backtick: false,
        tripleAsBlockComment: true,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let javascript = Spec(
        keywords: [
            "function", "return", "if", "else", "for", "while", "do", "break",
            "continue", "switch", "case", "default", "var", "let", "const",
            "class", "extends", "super", "this", "new", "typeof", "instanceof",
            "in", "of", "try", "catch", "finally", "throw", "async", "await",
            "import", "export", "from", "true", "false", "null", "undefined",
            "yield", "delete", "void", "static", "get", "set", "constructor",
        ],
        declarators: ["function", "class", "const", "let", "var"],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: true,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let typescript = Spec(
        keywords: javascript.keywords.union([
            "interface", "type", "enum", "implements", "namespace", "declare",
            "abstract", "readonly", "public", "private", "protected",
            "satisfies", "keyof", "infer", "never", "unknown", "any",
        ]),
        declarators: [
            "function", "class", "const", "let", "var", "interface", "type",
            "enum", "namespace",
        ],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: true,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let yaml = Spec(
        keywords: [
            "true", "false", "null", "True", "False", "Null",
            "yes", "no", "on", "off",
        ],
        declarators: [],
        builtinTypes: [],
        lineComment: "#",
        blockOpen: nil,
        blockClose: nil,
        doubleQuote: true,
        singleQuote: true,
        backtick: false,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: false,
        yamlKeys: true,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let bash = Spec(
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
            "done", "case", "esac", "function", "return", "in", "select",
            "break", "continue", "exit", "export", "local", "readonly",
            "declare", "unset", "shift", "eval", "source",
        ],
        declarators: ["function"],
        builtinTypes: [],
        lineComment: "#",
        blockOpen: nil,
        blockClose: nil,
        doubleQuote: true,
        singleQuote: true,
        backtick: true,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: false,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let go = Spec(
        keywords: [
            "func", "package", "import", "return", "if", "else", "for", "range",
            "switch", "case", "default", "break", "continue", "goto", "go",
            "defer", "select", "chan", "map", "struct", "interface", "type",
            "var", "const", "true", "false", "nil", "fallthrough",
        ],
        declarators: ["func", "type", "var", "const", "package"],
        builtinTypes: [
            "int", "int8", "int16", "int32", "int64", "uint", "uint8", "string",
            "bool", "byte", "rune", "error", "float32", "float64",
        ],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: true,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let rust = Spec(
        keywords: [
            "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
            "impl", "type", "pub", "use", "mod", "crate", "self", "super",
            "return", "if", "else", "match", "loop", "while", "for", "in",
            "break", "continue", "async", "await", "move", "ref", "where",
            "as", "true", "false", "unsafe", "extern", "dyn", "Self",
        ],
        declarators: [
            "fn", "struct", "enum", "trait", "type", "let", "const", "mod",
            "impl", "use",
        ],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: false,
        backtick: false,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: true
    )

    static let c = Spec(
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "float", "for", "goto",
            "if", "inline", "int", "long", "register", "restrict", "return",
            "short", "signed", "sizeof", "static", "struct", "switch",
            "typedef", "union", "unsigned", "void", "volatile", "while",
        ],
        declarators: ["struct", "enum", "union", "typedef"],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: false,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let cpp = Spec(
        keywords: c.keywords.union([
            "class", "namespace", "template", "typename", "public", "private",
            "protected", "virtual", "override", "final", "new", "delete",
            "this", "try", "catch", "throw", "using", "constexpr", "nullptr",
            "bool", "true", "false", "operator", "friend", "explicit",
            "noexcept", "decltype", "concept", "requires",
        ]),
        declarators: [
            "struct", "enum", "union", "typedef", "class", "namespace",
            "using", "concept",
        ],
        builtinTypes: [],
        lineComment: "//",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: false,
        tripleAsBlockComment: false,
        escape: .backslash,
        typeableUppercase: true,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )

    static let sql = Spec(
        keywords: sqlKeywordSet(),
        declarators: [],
        builtinTypes: [],
        lineComment: "--",
        blockOpen: "/*",
        blockClose: "*/",
        doubleQuote: true,
        singleQuote: true,
        backtick: true,
        tripleAsBlockComment: false,
        escape: .doubledQuote,
        typeableUppercase: false,
        yamlKeys: false,
        swiftBacktickIdent: false,
        rustLifetime: false
    )
}

private func sqlKeywordSet() -> Set<String> {
    let lower = [
        "select", "from", "where", "and", "or", "not", "insert", "into",
        "values", "update", "set", "delete", "create", "table", "drop",
        "alter", "join", "left", "right", "inner", "outer", "on", "as",
        "in", "is", "null", "like", "order", "by", "group", "having",
        "limit", "offset", "union", "all", "distinct", "case", "when",
        "then", "else", "end", "between", "exists",
    ]
    var set = Set(lower)
    for word in lower { set.insert(word.uppercased()) }
    return set
}

// MARK: - Cursor

private struct Cursor {
    let source: String
    var i: String.Index
    let end: String.Index
    var tokens: [CodeToken] = []

    init(_ source: String) {
        self.source = source
        self.i = source.startIndex
        self.end = source.endIndex
    }

    var atEnd: Bool { i >= end }

    func peek(_ offset: Int = 0) -> Character? {
        var idx = i
        var n = 0
        while n < offset {
            guard idx < end else { return nil }
            source.formIndex(after: &idx)
            n += 1
        }
        return idx < end ? source[idx] : nil
    }

    func hasPrefix(_ needle: String) -> Bool {
        var idx = i
        for ch in needle {
            guard idx < end, source[idx] == ch else { return false }
            source.formIndex(after: &idx)
        }
        return true
    }

    mutating func advance() {
        guard i < end else { return }
        source.formIndex(after: &i)
    }

    mutating func advance(_ count: Int) {
        var n = 0
        while n < count, i < end {
            source.formIndex(after: &i)
            n += 1
        }
    }

    mutating func emit(from start: String.Index, kind: CodeTokenKind) {
        guard start < i else { return }
        tokens.append(CodeToken(range: start..<i, kind: kind))
    }
}

private func isIdentStart(_ ch: Character) -> Bool {
    ch.isLetter || ch == "_" || ch == "$" || ch == "@"
}

private func isIdentContinue(_ ch: Character) -> Bool {
    ch.isLetter || ch.isNumber || ch == "_" || ch == "$"
}

private func isHexDigit(_ ch: Character) -> Bool {
    ch.isHexDigit
}

private func isBinDigit(_ ch: Character) -> Bool {
    ch == "0" || ch == "1"
}

private func isOctDigit(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else { return false }
    return ascii >= 48 && ascii <= 55
}

private func startsUppercase(_ ident: String) -> Bool {
    guard let first = ident.first else { return false }
    return first.isUppercase
}

// MARK: - Shared scanners

private extension Cursor {
    mutating func scanLineComment(marker: String) {
        let start = i
        advance(marker.count)
        while let ch = peek(), ch != "\n", ch != "\r" {
            advance()
        }
        emit(from: start, kind: .commentLine)
    }

    mutating func scanBlockComment(open: String, close: String) {
        let start = i
        advance(open.count)
        while !atEnd {
            if hasPrefix(close) {
                advance(close.count)
                break
            }
            advance()
        }
        emit(from: start, kind: .commentBlock)
    }

    mutating func scanQuoted(
        delimiter: Character,
        escape: Spec.StringEscape,
        kind: CodeTokenKind,
        allowNewline: Bool = false
    ) {
        let start = i
        advance()
        while let ch = peek() {
            if ch == "\\" && escape == .backslash {
                advance()
                if !atEnd { advance() }
                continue
            }
            if ch == delimiter {
                if escape == .doubledQuote, peek(1) == delimiter {
                    advance()
                    advance()
                    continue
                }
                advance()
                break
            }
            if !allowNewline && (ch == "\n" || ch == "\r") {
                // Unclosed single-line string: stop before the newline so
                // pairing of later quotes on following lines still works.
                break
            }
            advance()
        }
        emit(from: start, kind: kind)
    }

    /// Triple-quoted span (`"""` / `'''`). Newlines stay inside the token.
    mutating func scanTriple(marker: String, kind: CodeTokenKind) {
        let start = i
        advance(marker.count)
        while !atEnd {
            if hasPrefix(marker) {
                advance(marker.count)
                break
            }
            if peek() == "\\" {
                advance()
                if !atEnd { advance() }
                continue
            }
            advance()
        }
        emit(from: start, kind: kind)
    }

    mutating func scanNumber() {
        let start = i
        let first = peek()
        if first == "0", let tag = peek(1) {
            let digits: ((Character) -> Bool)?
            switch tag {
            case "x", "X": digits = isHexDigit
            case "b", "B": digits = isBinDigit
            case "o", "O": digits = isOctDigit
            default: digits = nil
            }
            if let digits, let third = peek(2), digits(third) {
                advance()
                advance()
                while let ch = peek(), digits(ch) || ch == "_" {
                    advance()
                }
                emit(from: start, kind: .number)
                return
            }
        }

        while let ch = peek(), ch.isNumber || ch == "_" {
            advance()
        }
        if peek() == ".", let next = peek(1), next.isNumber {
            advance()
            while let ch = peek(), ch.isNumber || ch == "_" {
                advance()
            }
        }
        if let exp = peek(), exp == "e" || exp == "E" {
            let signOrDigit = peek(1)
            let digit: Character?
            if signOrDigit == "+" || signOrDigit == "-" {
                digit = peek(2)
            } else {
                digit = signOrDigit
            }
            if let digit, digit.isNumber {
                advance()
                if let s = peek(), s == "+" || s == "-" { advance() }
                while let ch = peek(), ch.isNumber || ch == "_" {
                    advance()
                }
            }
        }
        emit(from: start, kind: .number)
    }

    mutating func scanIdent() -> String {
        let start = i
        if !atEnd { advance() }
        while let ch = peek(), isIdentContinue(ch) {
            advance()
        }
        return String(source[start..<i])
    }
}

// MARK: - Generic scan

private enum GenericScan {
    static func run(_ source: String, spec: Spec) -> [CodeToken] {
        var c = Cursor(source)
        var expectDeclaredName = false

        while !c.atEnd {
            guard let ch = c.peek() else { break }

            if ch.isWhitespace {
                c.advance()
                continue
            }

            if spec.tripleAsBlockComment {
                if c.hasPrefix("\"\"\"") {
                    c.scanTriple(marker: "\"\"\"", kind: .commentBlock)
                    expectDeclaredName = false
                    continue
                }
                if c.hasPrefix("'''") {
                    c.scanTriple(marker: "'''", kind: .commentBlock)
                    expectDeclaredName = false
                    continue
                }
            } else if spec.doubleQuote, c.hasPrefix("\"\"\"") {
                c.scanTriple(marker: "\"\"\"", kind: .string)
                expectDeclaredName = false
                continue
            }

            if let open = spec.blockOpen, let close = spec.blockClose, c.hasPrefix(open) {
                c.scanBlockComment(open: open, close: close)
                expectDeclaredName = false
                continue
            }

            if let marker = spec.lineComment, c.hasPrefix(marker) {
                c.scanLineComment(marker: marker)
                expectDeclaredName = false
                continue
            }

            if spec.swiftBacktickIdent, ch == "`" {
                let start = c.i
                c.advance()
                while let q = c.peek(), q != "`" {
                    c.advance()
                }
                if c.peek() == "`" { c.advance() }
                c.emit(from: start, kind: .typeable)
                expectDeclaredName = false
                continue
            }

            if spec.rustLifetime, ch == "'", let next = c.peek(1), isIdentStart(next) {
                let start = c.i
                c.advance()
                _ = c.scanIdent()
                c.emit(from: start, kind: .typeable)
                expectDeclaredName = false
                continue
            }

            if spec.doubleQuote, ch == "\"" {
                let start = c.i
                c.scanQuoted(delimiter: "\"", escape: spec.escape, kind: .string)
                if spec.yamlKeys {
                    retagYAMLKeyIfNeeded(&c, start: start)
                }
                expectDeclaredName = false
                continue
            }
            if spec.singleQuote, ch == "'" {
                let start = c.i
                c.scanQuoted(delimiter: "'", escape: spec.escape, kind: .string)
                if spec.yamlKeys {
                    retagYAMLKeyIfNeeded(&c, start: start)
                }
                expectDeclaredName = false
                continue
            }
            if spec.backtick, ch == "`" {
                c.scanQuoted(delimiter: "`", escape: spec.escape, kind: .string, allowNewline: true)
                expectDeclaredName = false
                continue
            }

            if ch.isNumber {
                c.scanNumber()
                expectDeclaredName = false
                continue
            }

            if isIdentStart(ch) {
                let start = c.i
                let ident = c.scanIdent()
                if spec.keywords.contains(ident) {
                    c.emit(from: start, kind: .keyword)
                    expectDeclaredName = spec.declarators.contains(ident)
                } else if spec.builtinTypes.contains(ident)
                            || expectDeclaredName
                            || (spec.typeableUppercase && startsUppercase(ident)) {
                    c.emit(from: start, kind: .typeable)
                    expectDeclaredName = false
                } else if spec.yamlKeys, followsColon(c) {
                    c.emit(from: start, kind: .typeable)
                    expectDeclaredName = false
                } else {
                    expectDeclaredName = false
                }
                continue
            }

            c.advance()
            expectDeclaredName = false
        }

        return c.tokens
    }

    /// After a quoted YAML scalar, retag as `typeable` if a `:` follows.
    static func retagYAMLKeyIfNeeded(_ c: inout Cursor, start: String.Index) {
        guard followsColon(c), let last = c.tokens.indices.last else { return }
        c.tokens[last] = CodeToken(range: start..<c.i, kind: .typeable)
    }

    static func followsColon(_ c: Cursor) -> Bool {
        var idx = c.i
        while idx < c.end {
            let ch = c.source[idx]
            if ch == " " || ch == "\t" {
                c.source.formIndex(after: &idx)
                continue
            }
            return ch == ":"
        }
        return false
    }
}

// MARK: - JSON (keys vs string values)

private enum JSONScan {
    enum Ctx {
        case objectKey
        case objectAfterKey
        case objectValue
        case arrayValue
    }

    static func run(_ source: String) -> [CodeToken] {
        var c = Cursor(source)
        var stack: [Ctx] = []

        while !c.atEnd {
            guard let ch = c.peek() else { break }
            if ch.isWhitespace {
                c.advance()
                continue
            }

            switch ch {
            case "{":
                stack.append(.objectKey)
                c.advance()
            case "[":
                stack.append(.arrayValue)
                c.advance()
            case "}":
                if !stack.isEmpty { stack.removeLast() }
                c.advance()
            case "]":
                if !stack.isEmpty { stack.removeLast() }
                c.advance()
            case ":":
                if let last = stack.last, last == .objectAfterKey {
                    stack[stack.count - 1] = .objectValue
                }
                c.advance()
            case ",":
                if let last = stack.last {
                    switch last {
                    case .objectValue, .objectAfterKey, .objectKey:
                        stack[stack.count - 1] = .objectKey
                    case .arrayValue:
                        break
                    }
                }
                c.advance()
            case "\"":
                let asKey = stack.last == .objectKey
                c.scanQuoted(delimiter: "\"", escape: .backslash, kind: asKey ? .typeable : .string)
                if asKey, let last = stack.indices.last {
                    stack[last] = .objectAfterKey
                }
            default:
                if ch.isNumber || (ch == "-" && c.peek(1)?.isNumber == true) {
                    let start = c.i
                    if ch == "-" { c.advance() }
                    c.scanNumber()
                    if let last = c.tokens.indices.last, c.tokens[last].kind == .number {
                        c.tokens[last] = CodeToken(range: start..<c.i, kind: .number)
                    }
                } else if isIdentStart(ch) {
                    let start = c.i
                    let ident = c.scanIdent()
                    if ident == "true" || ident == "false" || ident == "null" {
                        c.emit(from: start, kind: .keyword)
                    }
                } else {
                    c.advance()
                }
            }
        }

        return c.tokens
    }
}

// MARK: - HTML / XML

private enum MarkupScan {
    static func run(_ source: String) -> [CodeToken] {
        var c = Cursor(source)

        while !c.atEnd {
            guard let ch = c.peek() else { break }

            if c.hasPrefix("<!--") {
                c.scanBlockComment(open: "<!--", close: "-->")
                continue
            }

            if ch == "<" {
                c.advance()
                if c.peek() == "/" || c.peek() == "!" || c.peek() == "?" {
                    c.advance()
                }
                if let n = c.peek(), isIdentStart(n) {
                    let start = c.i
                    _ = c.scanIdent()
                    // Tag names may contain '-' / ':' (xml namespaces).
                    while let extra = c.peek(), extra == "-" || extra == ":" || extra == "." {
                        c.advance()
                        while let cont = c.peek(), isIdentContinue(cont) {
                            c.advance()
                        }
                    }
                    c.emit(from: start, kind: .keyword)
                }
                while !c.atEnd {
                    guard let t = c.peek() else { break }
                    if t == ">" {
                        c.advance()
                        break
                    }
                    if t == "/" && c.peek(1) == ">" {
                        c.advance()
                        c.advance()
                        break
                    }
                    if t == "\"" || t == "'" {
                        c.scanQuoted(delimiter: t, escape: .backslash, kind: .string)
                        continue
                    }
                    if t.isWhitespace {
                        c.advance()
                        continue
                    }
                    if isIdentStart(t) {
                        let start = c.i
                        _ = c.scanIdent()
                        while let extra = c.peek(), extra == "-" || extra == ":" {
                            c.advance()
                            while let cont = c.peek(), isIdentContinue(cont) {
                                c.advance()
                            }
                        }
                        c.emit(from: start, kind: .typeable)
                        continue
                    }
                    c.advance()
                }
                continue
            }

            c.advance()
        }

        return c.tokens
    }
}

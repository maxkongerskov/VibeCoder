//
//  SkillDiscovery.swift
//
//  SKILL.md filesystem discovery (Grok Build / Claude Code behavioral port).
//  Layout: <root>/skills/<name>/SKILL.md under .vibecoder, .grok, .claude,
//  .cursor (project + user home). Project wins over user; disk wins over bundled.
//
//  Index path uses metadata-only parse (frontmatter / first bytes) so large skill
//  bodies are not held until `load_skill` / byName materializes them.
//

import Foundation

/// One discovered skill package.
public struct DiscoveredSkill: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    /// Full markdown body (frontmatter stripped). Empty when `metadataOnly`.
    public var body: String
    public var fileURL: URL?
    public var source: Source
    /// When true, skill must not appear in the model-facing index and must
    /// not be loadable via the `load_skill` tool (Grok/Claude
    /// `disable-model-invocation`). User slash invocation may still resolve
    /// the skill via `byName` + `formatSkillMessage` outside the tool path.
    public var disableModelInvocation: Bool
    /// Whether the skill is intended as a user slash command. Defaults true.
    /// (Slash registration is a separate surface; this flag is parsed for
    /// control-plane parity and future `/skill` wiring.)
    public var userInvocable: Bool
    /// Optional tool allowlist from frontmatter (`allowed-tools`). Stored for
    /// later gating; not enforced by discovery/load today.
    public var allowedTools: [String]
    /// When true, only name/description/path were loaded; call
    /// `SkillDiscovery.ensureBody` (or `byName`) before using `body`.
    public var metadataOnly: Bool

    public enum Source: String, Sendable, Equatable {
        case project
        case user
        case bundled
    }

    /// Skills the model may see and load via `load_skill`.
    public var isModelInvocable: Bool { !disableModelInvocation }

    public init(
        name: String,
        description: String,
        body: String,
        fileURL: URL? = nil,
        source: Source = .project,
        disableModelInvocation: Bool = false,
        userInvocable: Bool = true,
        allowedTools: [String] = [],
        metadataOnly: Bool = false
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.fileURL = fileURL
        self.source = source
        self.disableModelInvocation = disableModelInvocation
        self.userInvocable = userInvocable
        self.allowedTools = allowedTools
        self.metadataOnly = metadataOnly
    }
}

public enum SkillDiscovery {

    public static let maxDescriptionLen = 1024
    public static let maxNameLen = 64
    public static let maxWalkDepth = 5
    /// Cap index size so small local models keep headroom.
    public static let maxIndexEntries = 40
    public static let maxIndexDescriptionChars = 160
    /// Bytes read when scanning frontmatter for the index (lazy metadata).
    public static let metadataReadLimit = 8_192

    /// Product + peer skill roots relative to a config base (project root or home).
    public static let skillRootSegments: [[String]] = [
        [".vibecoder", "skills"],
        [".grok", "skills"],
        [".claude", "skills"],
        [".cursor", "skills"],
    ]

    // MARK: - Discovery

    /// Discover skills. Precedence:
    /// worktree roots → project roots (segment order) → user home → bundled.
    /// First name wins (case-insensitive).
    ///
    /// Both `projectRoot` and `worktreeRoot` are scanned when distinct so
    /// worktree sessions still load repo-level `.vibecoder/skills` and the
    /// prompt index matches `load_skill` resolution.
    ///
    /// - Parameter metadataOnly: When true (default for index), only name +
    ///   description + path are loaded — skill bodies stay on disk until
    ///   `byName` / `ensureBody`. Bundled skills still carry full body (tiny).
    public static func discover(
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        includeBundled: Bool = true,
        home: URL? = nil,
        metadataOnly: Bool = false
    ) -> [DiscoveredSkill] {
        var found: [DiscoveredSkill] = []
        var seen = Set<String>()

        func absorb(_ skill: DiscoveredSkill) {
            let key = skill.name.lowercased()
            guard seen.insert(key).inserted else { return }
            found.append(skill)
        }

        for root in sessionSkillRoots(projectRoot: projectRoot, worktreeRoot: worktreeRoot) {
            for segments in skillRootSegments {
                let dir = segments.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                for skill in scanSkillsDir(dir, source: .project, metadataOnly: metadataOnly) {
                    absorb(skill)
                }
            }
        }

        let homeURL = home ?? FileManager.default.homeDirectoryForCurrentUser
        for segments in skillRootSegments {
            let dir = segments.reduce(homeURL) { $0.appendingPathComponent($1, isDirectory: true) }
            for skill in scanSkillsDir(dir, source: .user, metadataOnly: metadataOnly) {
                absorb(skill)
            }
        }

        if includeBundled {
            for skill in bundledSkills() {
                absorb(skill)
            }
        }

        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func byName(
        _ name: String,
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        includeBundled: Bool = true,
        home: URL? = nil
    ) -> DiscoveredSkill? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        // Metadata walk to locate the winning skill, then load full body once.
        guard let hit = discover(
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            includeBundled: includeBundled,
            home: home,
            metadataOnly: true
        )
        .first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame })
        else { return nil }
        return ensureBody(hit)
    }

    /// Materialize full body when discovery was metadata-only.
    public static func ensureBody(_ skill: DiscoveredSkill) -> DiscoveredSkill {
        guard skill.metadataOnly else { return skill }
        if let url = skill.fileURL, let full = parse(file: url, source: skill.source) {
            return full
        }
        // Bundled or body already present under another path.
        if !skill.body.isEmpty {
            var copy = skill
            copy.metadataOnly = false
            return copy
        }
        return skill
    }

    /// Ordered unique roots: worktree first (session cwd), then project.
    public static func sessionSkillRoots(projectRoot: URL?, worktreeRoot: URL?) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url else { return }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            roots.append(url)
        }
        add(worktreeRoot)
        add(projectRoot)
        return roots
    }

    // MARK: - Parse

    public static func parse(file: URL, source: DiscoveredSkill.Source = .project) -> DiscoveredSkill? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let defaultName = file.deletingLastPathComponent().lastPathComponent
        // skills/foo/SKILL.md → name foo; skills/SKILL.md → parent folder name
        let fallback = defaultName.caseInsensitiveCompare("skills") == .orderedSame
            ? (file.deletingPathExtension().lastPathComponent)
            : defaultName
        return parse(markdown: text, fileURL: file, defaultName: fallback, source: source)
    }

    /// Frontmatter-only parse for index walks. Reads at most `metadataReadLimit`
    /// bytes when the file is larger (avoids loading multi-KB skill bodies into
    /// the catalog path).
    public static func parseMetadata(
        file: URL,
        source: DiscoveredSkill.Source = .project
    ) -> DiscoveredSkill? {
        let defaultName = file.deletingLastPathComponent().lastPathComponent
        let fallback = defaultName.caseInsensitiveCompare("skills") == .orderedSame
            ? (file.deletingPathExtension().lastPathComponent)
            : defaultName

        guard let text = readPrefix(of: file, maxBytes: metadataReadLimit) else { return nil }
        return parse(
            markdown: text,
            fileURL: file,
            defaultName: fallback,
            source: source,
            metadataOnly: true,
            allowEmptyBody: true
        )
    }

    public static func parse(
        markdown: String,
        fileURL: URL? = nil,
        defaultName: String = "skill",
        source: DiscoveredSkill.Source = .project,
        metadataOnly: Bool = false,
        allowEmptyBody: Bool = false
    ) -> DiscoveredSkill? {
        var name = sanitizeName(defaultName)
        var description = ""
        // Strip UTF-8 BOM so frontmatter detection is reliable.
        var body = markdown
        if body.hasPrefix("\u{FEFF}") {
            body.removeFirst()
        }
        // Normalize Windows newlines for frontmatter detection.
        if body.contains("\r\n") {
            body = body.replacingOccurrences(of: "\r\n", with: "\n")
        } else if body.contains("\r") {
            body = body.replacingOccurrences(of: "\r", with: "\n")
        }

        var disableModelInvocation = false
        var userInvocable = true
        var allowedTools: [String] = []

        if body.hasPrefix("---") {
            let parts = body.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
            // ["", frontmatter, body...]
            if parts.count >= 3 {
                let fm = String(parts[1])
                body = parts.dropFirst(2).joined(separator: "---")
                let fields = parseFrontmatterFields(fm)
                // Known control-plane keys; all other frontmatter keys are
                // ignored gracefully (left in `fields` only during parse).
                if let n = fields["name"] {
                    name = sanitizeName(n)
                }
                if let d = fields["description"] {
                    description = String(d.prefix(maxDescriptionLen))
                }
                if let flag = boolishFrontmatterValue(
                    fields,
                    keys: ["disable-model-invocation", "disable_model_invocation"]
                ) {
                    disableModelInvocation = flag
                }
                if let flag = boolishFrontmatterValue(
                    fields,
                    keys: ["user-invocable", "user_invocable"]
                ) {
                    userInvocable = flag
                }
                if let toolsRaw = firstFrontmatterValue(
                    fields,
                    keys: ["allowed-tools", "allowed_tools"]
                ) {
                    allowedTools = parseAllowedTools(toolsRaw)
                }
            }
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if metadataOnly {
            // Do not retain body for the index path.
            if description.isEmpty, !body.isEmpty {
                description = deriveDescription(from: body)
            }
            guard !name.isEmpty else { return nil }
            // Require either a description, a non-empty body prefix, or a file on disk
            // so empty stubs do not pollute the catalog.
            if description.isEmpty && body.isEmpty && !allowEmptyBody { return nil }
            if description.isEmpty && body.isEmpty && fileURL == nil { return nil }
            return DiscoveredSkill(
                name: name,
                description: description,
                body: "",
                fileURL: fileURL,
                source: source,
                disableModelInvocation: disableModelInvocation,
                userInvocable: userInvocable,
                allowedTools: allowedTools,
                metadataOnly: true
            )
        }

        guard !body.isEmpty, !name.isEmpty else { return nil }

        // If frontmatter omitted description, derive a short one from the first line.
        if description.isEmpty {
            description = deriveDescription(from: body)
        }

        return DiscoveredSkill(
            name: name,
            description: description,
            body: body,
            fileURL: fileURL,
            source: source,
            disableModelInvocation: disableModelInvocation,
            userInvocable: userInvocable,
            allowedTools: allowedTools,
            metadataOnly: false
        )
    }

    // MARK: - Prompt index

    /// Skills eligible for the model-facing catalog and `load_skill` tool.
    public static func modelInvocableSkills(_ skills: [DiscoveredSkill]) -> [DiscoveredSkill] {
        skills.filter(\.isModelInvocable)
    }

    /// Token-budgeted skill catalog for the system prompt. Nil when empty.
    ///
    /// Skills with `disable-model-invocation: true` are **excluded** so the
    /// model cannot discover or invent them. User-only skills remain
    /// resolvable via `byName` for slash / UI injection.
    public static func indexBlock(
        skills: [DiscoveredSkill],
        maxEntries: Int = maxIndexEntries,
        maxDescriptionChars: Int = maxIndexDescriptionChars
    ) -> String? {
        let invocable = modelInvocableSkills(skills)
        guard !invocable.isEmpty else { return nil }
        let slice = invocable.prefix(maxEntries)
        var lines: [String] = [
            "# Available skills",
            "Reusable procedures live as SKILL.md packages. When a skill matches the task, call `load_skill` with its name to inject full instructions for this turn. Do not invent skill names that are not listed.",
            "",
        ]
        for skill in slice {
            let desc = skill.description
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = desc.count > maxDescriptionChars
                ? String(desc.prefix(maxDescriptionChars - 1)) + "…"
                : desc
            if clipped.isEmpty {
                lines.append("- `\(skill.name)`")
            } else {
                lines.append("- `\(skill.name)`: \(clipped)")
            }
        }
        if invocable.count > maxEntries {
            lines.append("")
            lines.append("(+\(invocable.count - maxEntries) more on disk — load by exact name if known.)")
        }
        return lines.joined(separator: "\n")
    }

    /// Index for a session (metadata-only discover). Convenience for AgentLoop.
    public static func indexBlock(
        projectRoot: URL?,
        worktreeRoot: URL? = nil,
        includeBundled: Bool = true
    ) -> String? {
        indexBlock(skills: discover(
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot,
            includeBundled: includeBundled,
            metadataOnly: true
        ))
    }

    // MARK: - Format for model

    /// Grok-style skill envelope returned by `load_skill`.
    /// Also used by user/slash injection paths for disabled-for-model skills.
    public static func formatSkillMessage(_ skill: DiscoveredSkill, args: String? = nil) -> String {
        let loaded = ensureBody(skill)
        let path = loaded.fileURL?.path ?? "bundled:\(loaded.name)"
        var header = "<skill name=\"\(loaded.name)\" description=\"\(escapeAttr(loaded.description))\" path=\"\(escapeAttr(path))\""
        if let args, !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            header += " args=\"\(escapeAttr(args))\""
        }
        header += ">"
        return """
        \(header)
        \(loaded.body)
        </skill>
        """
    }

    // MARK: - Bundled

    /// Always-available example skills (no marketplace). Disk skills with the
    /// same name override these entries.
    public static func bundledSkills() -> [DiscoveredSkill] {
        let packages: [String] = [
            """
            ---
            name: verify
            description: After edits, verify correctness with targeted re-reads, git diff, and builds — not open-ended polish.
            ---
            # Verify skill

            Use this procedure after mutating code:

            1. Re-read only the sections you changed (`read_file` with offset/limit when large).
            2. Run `git_diff` (or equivalent) and confirm the diff matches intent — no accidental deletions.
            3. Prefer project build tools (`xcode_build`, package build via `run_shell`) over vague "it should work" claims.
            4. If BuildGuard or a system reminder reports build failure, fix before declaring done.
            5. Summarize: what changed, how you verified, residual risks.

            Do not invent verification that was not run.
            """,
            """
            ---
            name: commit
            description: Create a focused git commit with a clear message from the current diff.
            ---
            # Commit skill

            Use this when the user asks to commit (or when finishing a discrete unit of work):

            1. Run `git_status` and `git_diff` (staged + unstaged as needed). Do not commit secrets (`.env`, keys, credentials).
            2. Stage only the files that belong in this commit — avoid unrelated dirty work.
            3. Write a concise message: why the change, not a file list. Prefer imperative mood.
            4. Commit via `run_shell` / git tools as the environment allows; never force-push or amend published history unless the user explicitly asked.
            5. Report the commit summary (hash if available) and what was left unstaged.
            """,
            """
            ---
            name: pdf
            description: Offline PDF read, OCR, create, merge/split, form fill, and signature stamp — local tools only, never online converters.
            ---
            # PDF skill (offline only)

            All PDF work stays on this Mac. Prefer the dedicated tools below. **Do not** use `web_search`, `fetch_url`, cloud converters, or invent online workflows.

            ## Tools

            | Goal | Tool | Notes |
            |------|------|--------|
            | Text from digital PDF | `extract_pdf_text` | Core. Optional `page_range` like `1-5,7`. |
            | Scanned page / screenshot | `ocr_image` | Core. Vision OCR on a PNG/JPEG path. |
            | Create PDF from markdown | `create_pdf` | Core. Themes: default, academic, report, resume. |
            | Merge / split / pages / rotate / watermark | `manipulate_pdf` | Deferred — call `tool_search` with query `pdf` if missing. |
            | AcroForm fields | `fill_pdf_form` | Deferred. List fields first (no `values`), then fill + `output`. |
            | Stamp signature image | `sign_pdf` | Deferred. Local image path; PDF coords origin bottom-left. |

            ## Decision tree

            1. **Read text PDF** → `extract_pdf_text`. If pages say no extractable text → treat as scan.
            2. **Scan / image** → obtain a page image (user file or local render), then `ocr_image`.
            3. **Author a document** → write markdown (file or inline) → `create_pdf` with `output_path`.
            4. **Structural edit** → `tool_search` query `pdf` if needed → `manipulate_pdf` with the right `action`.
            5. **Forms** → `fill_pdf_form` with only `input` → map values → call again with `values` + `output`.
            6. **Sign** → `sign_pdf` with a local signature PNG and page/x/y/width/height.

            ## Rules

            - Never claim a PDF was processed online.
            - Prefer these tools over `run_shell` + Python/pdftotext unless a tool fails and a **local** CLI is available.
            - After mutating, report the output path; re-extract if content correctness matters.
            - Stay offline: no CDNs, no remote OCR, no upload-to-convert.
            """,
        ]
        return packages.compactMap { parse(markdown: $0, defaultName: "skill", source: .bundled) }
    }

    // MARK: - Internals

    private static func deriveDescription(from body: String) -> String {
        let first = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stripped = first.hasPrefix("#")
            ? first.drop(while: { $0 == "#" || $0.isWhitespace })
            : Substring(first)
        return String(String(stripped).prefix(maxIndexDescriptionChars))
    }

    /// Read up to `maxBytes` of UTF-8 text for metadata scans.
    private static func readPrefix(of file: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            guard let chunk = try? handle.read(upToCount: maxBytes) else { return nil }
            data = chunk
        } else {
            data = handle.readData(ofLength: maxBytes)
        }
        guard !data.isEmpty else { return nil }
        // Drop incomplete trailing multi-byte sequence if we truncated mid-character.
        var bytes = [UInt8](data)
        if bytes.count == maxBytes {
            while let last = bytes.last, last & 0xC0 == 0x80 {
                bytes.removeLast()
            }
            if let last = bytes.last, last & 0x80 != 0, last & 0xC0 != 0xC0 {
                bytes.removeLast()
            }
        }
        return String(bytes: bytes, encoding: .utf8)
            ?? String(decoding: Data(bytes), as: UTF8.self)
    }

    private static func scanSkillsDir(
        _ dir: URL,
        source: DiscoveredSkill.Source,
        metadataOnly: Bool
    ) -> [DiscoveredSkill] {
        var out: [DiscoveredSkill] = []
        walkForSkillMD(dir, depth: 0, source: source, metadataOnly: metadataOnly, into: &out)
        return out
    }

    private static func walkForSkillMD(
        _ dir: URL,
        depth: Int,
        source: DiscoveredSkill.Source,
        metadataOnly: Bool,
        into out: inout [DiscoveredSkill]
    ) {
        guard depth <= maxWalkDepth else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                // Nested skill package: .../skills/foo/SKILL.md
                let skillFile = entry.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillFile.path) {
                    if let skill = metadataOnly
                        ? parseMetadata(file: skillFile, source: source)
                        : parse(file: skillFile, source: source) {
                        out.append(skill)
                    }
                } else {
                    walkForSkillMD(
                        entry, depth: depth + 1, source: source,
                        metadataOnly: metadataOnly, into: &out)
                }
            } else if values?.isRegularFile == true,
                      entry.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                if let skill = metadataOnly
                    ? parseMetadata(file: entry, source: source)
                    : parse(file: entry, source: source) {
                    out.append(skill)
                }
            }
        }
    }

    private static func sanitizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(maxNameLen))
        // Keep simple token names for tool args / index.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let filtered = clipped.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        // Spaces → hyphens for stable tool names.
        let dashed = String(filtered)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
        let name = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return name.isEmpty ? "skill" : name
    }

    /// First non-empty frontmatter value among alias keys (kebab or snake).
    static func firstFrontmatterValue(_ fields: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let v = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// Parse YAML-ish boolean scalars used by Grok/Claude skill frontmatter.
    /// Accepts true/false, yes/no, on/off, 1/0 (case-insensitive). Nil if missing/unknown.
    static func parseBoolish(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    static func boolishFrontmatterValue(_ fields: [String: String], keys: [String]) -> Bool? {
        guard let raw = firstFrontmatterValue(fields, keys: keys) else { return nil }
        return parseBoolish(raw)
    }

    /// `allowed-tools` as YAML-ish list or comma/space-separated string.
    static func parseAllowedTools(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Inline YAML list: [a, b] or - a\n- b (block already joined with \n).
        var text = trimmed
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { part -> String in
                var out = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.hasPrefix("-") {
                    out = String(out.drop(while: { $0 == "-" || $0.isWhitespace }))
                }
                if (out.hasPrefix("\"") && out.hasSuffix("\"") && out.count >= 2)
                    || (out.hasPrefix("'") && out.hasSuffix("'") && out.count >= 2) {
                    out = String(out.dropFirst().dropLast())
                }
                return out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// Parse simple YAML-ish frontmatter: `key: value`, plus block scalars
    /// `key: |` / `key: >` with indented continuation lines (closes O-W11-01).
    /// Unknown keys are retained in the returned map but ignored by `parse`
    /// (forward-compatible with Grok `metadata.*` and future fields).
    static func parseFrontmatterFields(_ frontmatter: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let l = rawLine.trimmingCharacters(in: .whitespaces)
            i += 1
            if l.isEmpty || l.hasPrefix("#") { continue }
            guard let colon = l.firstIndex(of: ":") else { continue }
            let key = String(l[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var value = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Block scalar: description: | or >
            if value == "|" || value == ">" || value == "|-" || value == ">-"
                || value == "|+" || value == ">+" {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while i < lines.count {
                    let cont = lines[i]
                    // Continuation must be indented (or blank inside block).
                    if cont.trimmingCharacters(in: .whitespaces).isEmpty {
                        block.append("")
                        i += 1
                        continue
                    }
                    let leading = cont.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if leading == 0 { break }
                    let stripped = cont.drop(while: { $0 == " " || $0 == "\t" })
                    block.append(String(stripped))
                    i += 1
                }
                // Drop trailing empty lines
                while block.last?.isEmpty == true { block.removeLast() }
                value = folded
                    ? block.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
                    : block.joined(separator: "\n")
            } else {
                // Strip optional surrounding quotes on single-line values.
                if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                    || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                    value = String(value.dropFirst().dropLast())
                }
            }
            out[key] = value
        }
        return out
    }

    private static func escapeAttr(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

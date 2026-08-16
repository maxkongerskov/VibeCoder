//
//  SafeBash.swift
//
//  Read-only shell segment recognition + dangerous-command detection.
//  Used by the tool authorization pipeline so Full mode still cannot
//  "remember-approve" destructive commands, and Plan mode can allow
//  inspect-only shell.
//
//  Wave B S10b (v2): Grok-class word-boundary dangerous prefixes, builds
//  no longer classified as RO, quote-aware segment split + tokenize, light
//  wrapper peel (env/nohup/…).
//

import Foundation

public enum SafeBash: Sendable {

    /// Primary commands treated as read-only when they appear as the
    /// first token of a shell segment (word-boundary match).
    public static let readOnlyPrimaries: Set<String> = [
        "ls", "cat", "pwd", "date", "whoami", "hostname", "uptime", "ps",
        "head", "tail", "wc", "sort", "uniq", "tr", "cut", "echo", "printf",
        "file", "stat", "du", "df", "which", "type", "env", "printenv",
        "grep", "rg", "find", "tree",
        "swift", // only with subcommands in readOnlySwiftSubs
        "cargo",
        "kubectl",
        "git",
    ]

    /// Shell prefixes to union into Plan/Ask auto-SafeMode allow-lists so the
    /// system prompt matches inspect tools Plan mode advertises (W07 S10a).
    /// Sorted for stable prompts/tests. W13 may tighten RO classification;
    /// this list tracks `readOnlyPrimaries`.
    public static var safeModeInspectShellPrefixes: [String] {
        readOnlyPrimaries.sorted()
    }

    /// Inspect-only git subcommands (no push/commit/reset/clean).
    /// Note: bare `remote` / `tag` are *not* RO — they accept mutating
    /// actions (`remote add`, `tag -d`). Use the inspect subsets below.
    private static let readOnlyGitSubs: Set<String> = [
        "status", "branch", "log", "diff", "ls-files", "show", "rev-parse",
        "describe", "stash", "blame", "shortlog",
    ]

    /// `git remote` actions that only inspect (no add/remove/set-url).
    private static let readOnlyGitRemoteActions: Set<String> = [
        "show", "get-url", "v", "-v",
    ]

    /// `git tag` actions that only inspect (no create/delete).
    private static let readOnlyGitTagActions: Set<String> = [
        "-l", "--list", "-n", "-n1", "-n2", "-n3",
    ]

    /// `find` primaries that mutate or run arbitrary commands — never RO.
    private static let findMutatingFlags: Set<String> = [
        "-delete", "-exec", "-execdir", "-ok", "-okdir",
        "-fprint", "-fprint0", "-fls", "-fprintf",
    ]

    /// Swift package inspection only — `swift build` / `swift test` write
    /// `.build/` and must not auto-approve as RO (Wave B S10b).
    private static let readOnlySwiftSubs: Set<String> = [
        "package",
    ]

    /// Inspect-only `swift package` subcommands. `update` / `add-dependency`
    /// / `reset` mutate the graph and must not auto-approve as RO.
    private static let readOnlySwiftPackageActions: Set<String> = [
        "describe", "show", "dump-package", "dump-symbol-graph",
        "completion", "show-dependencies", "tools-version",
    ]

    /// Cargo check/clippy only — `build` / `test` write `target/`.
    private static let readOnlyCargoSubs: Set<String> = ["check", "clippy"]

    private static let readOnlyKubectlSubs: Set<String> = ["get", "logs", "describe", "top"]

    /// Prefixes that never use remembered grants (Grok `is_dangerous_command_words`).
    /// Matched as command prefixes with a word boundary after the last token.
    public static let dangerousCommandPrefixes: [String] = [
        "rm",
        "chmod",
        "chown",
        "chgrp",
        "chattr",
        "pkill",
        "kill",
        "killall",
        "git push",
        "eval",
        "source",
        ".", // source builtin (`. ./script`, `. script`)
    ]

    /// Light wrappers peeled before RO / dangerous classification so
    /// `env rm -rf x` still counts as dangerous and `nohup ls` stays RO.
    private static let wrapperPrimaries: Set<String> = [
        "env", "nice", "nohup", "time", "command", "builtin", "stdbuf",
        "timeout", "ionice", "chrt", "xargs",
    ]

    private static let shellInterpreters: Set<String> = [
        "bash", "sh", "zsh", "dash", "/bin/bash", "/bin/sh", "/bin/zsh",
    ]

    /// Language runtimes that take `-c 'script'` (never RO; payload checked
    /// for dangerous content when present).
    private static let scriptInterpreters: Set<String> = [
        "python", "python3", "python2", "node", "nodejs", "ruby", "perl", "php",
    ]

    // MARK: - Dangerous

    /// True when any chained segment is a known-dangerous command.
    /// Dangerous commands never use remembered grants.
    public static func isDangerous(_ command: String) -> Bool {
        let segs = segments(of: command)
        guard !segs.isEmpty else { return false }
        return segs.contains { isDangerousSegment($0) }
    }

    /// Classify a single shell segment (already split on chain operators).
    public static func isDangerousSegment(_ segment: String) -> Bool {
        // `echo $(rm …)` / `echo \`rm …\`` — treat substitution payloads
        // like `bash -c` (fail closed if the inner command is dangerous).
        if commandSubstitutionPayloads(in: segment).contains(where: { isDangerous($0) }) {
            return true
        }

        var tokens = peelWrappers(tokenize(segment))
        tokens = peelGitGlobalOptions(tokens)
        guard !tokens.isEmpty else { return false }

        // Nested interpreter scripts: `bash -c 'rm -rf /'`, `python -c '…'`.
        // Classify the `-c` payload (fail closed if payload itself is dangerous).
        if let nested = nestedShellScript(from: tokens), isDangerous(nested) {
            return true
        }
        if let nested = nestedScriptInterpreterPayload(from: tokens),
           payloadLooksDangerous(nested) {
            return true
        }

        let joined = tokens.joined(separator: " ").lowercased()

        for prefix in dangerousCommandPrefixes {
            if matchesCommandPrefix(joined, prefix: prefix) {
                return true
            }
        }

        // High-signal patterns that are not single-command prefixes.
        let c = segment.lowercased()
        let patterns = [
            "mkfs", "dd if=", "dd of=",
            "git reset --hard",
            "git clean -fd", "git clean -f",
            "> /dev/", "curl | sh", "curl|sh", "wget | sh", "wget|sh",
            "curl | bash", "curl|bash", "wget | bash", "wget|bash",
            ":(){", "fork bomb",
            "diskutil erase", "nvram ",
            "sudo ", "doas ",
            // Shell builtins that execute arbitrary text.
            "eval ", "source ", ". /",
        ]
        if patterns.contains(where: { c.contains($0) }) { return true }

        // Recursive rm flag forms already covered by bare `rm` prefix above;
        // keep legacy regex as belt for exotic spacing after peel failures.
        if c.range(of: #"\brm\b.*\s-[a-z]*r"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Word-boundary command prefix (Grok `matches_command_prefix`).
    /// `"rm"` matches `"rm -rf /"` but not `"rmdir"`; `"git push"` matches
    /// `"git push origin"` but not `"git status"` or `"git pushx"`.
    public static func matchesCommandPrefix(_ command: String, prefix: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return false }
        if c == p { return true }
        guard c.hasPrefix(p) else { return false }
        let next = c[c.index(c.startIndex, offsetBy: p.count)]
        // Require a word break so `rm` ≠ `rmdir` and `git push` ≠ `git pushx`.
        return next.isWhitespace || next == ";" || next == "|" || next == "&"
    }

    // MARK: - Segments

    /// Split on shell chain operators (`&&`, `||`, `;`, `|`, newline) with
    /// basic single/double-quote awareness so `echo "a && b" && ls` yields
    /// two segments, not three.
    public static func segments(of command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = command.startIndex
        var inSingle = false
        var inDouble = false
        var escape = false

        while i < command.endIndex {
            let ch = command[i]

            if escape {
                current.append(ch)
                escape = false
                i = command.index(after: i)
                continue
            }

            if ch == "\\" && (inSingle || inDouble) {
                // Keep backslash + next char inside quotes for tokenize fidelity.
                current.append(ch)
                escape = true
                i = command.index(after: i)
                continue
            }

            if ch == "'" && !inDouble {
                inSingle.toggle()
                current.append(ch)
                i = command.index(after: i)
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                current.append(ch)
                i = command.index(after: i)
                continue
            }

            if !inSingle && !inDouble {
                let rest = command[i...]
                if rest.hasPrefix("&&") || rest.hasPrefix("||") {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                    i = command.index(i, offsetBy: 2)
                    continue
                }
                if ch == ";" || ch == "|" || ch == "\n" {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                    i = command.index(after: i)
                    continue
                }
            }

            current.append(ch)
            i = command.index(after: i)
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.isEmpty
            ? [command.trimmingCharacters(in: .whitespacesAndNewlines)]
            : parts
    }

    // MARK: - Read-only

    /// True when every segment is recognized as read-only.
    public static func isReadOnlyCommand(_ command: String) -> Bool {
        let segs = segments(of: command)
        guard !segs.isEmpty else { return false }
        // Never treat a dangerous segment as RO (defense in depth).
        if segs.contains(where: { isDangerousSegment($0) }) { return false }
        return segs.allSatisfy { isReadOnlySegment($0) }
    }

    public static func isReadOnlySegment(_ segment: String) -> Bool {
        let tokens = peelWrappers(tokenize(segment))
        guard let primary = tokens.first else { return false }

        // Nested shells / -c scripts are never inspect-only (payload may mutate).
        if nestedShellScript(from: tokens) != nil { return false }
        if nestedScriptInterpreterPayload(from: tokens) != nil { return false }

        // Reject redirects / substitutions in a segment
        if segment.contains("`") || segment.contains("$(")
            || segment.contains(">") || segment.contains("<") {
            return false
        }

        // `find -delete` / `-exec` / `-ok` / print-to-file are not inspect-only.
        if primary == "find" {
            for t in tokens.dropFirst() {
                if findMutatingFlags.contains(t) { return false }
                // Combined forms: -exec rm {} +
                if t.hasPrefix("-exec") || t.hasPrefix("-ok") { return false }
            }
        }
        if primary == "rg" || primary == "grep" {
            if tokens.contains(where: { $0 == "--pre" || $0.hasPrefix("--pre=") }) {
                return false
            }
        }
        // `sort -o FILE` writes; bare sort of stdin is RO.
        if primary == "sort", tokens.contains("-o") || tokens.contains(where: { $0.hasPrefix("--output") }) {
            return false
        }
        // `tee` always writes (stdout + files).
        if primary == "tee" { return false }

        switch primary {
        case "git":
            guard tokens.count >= 2 else { return false }
            // `git stash` without sub is ambiguous (push vs list); allow list-ish only
            // when second token is a known RO sub. `stash` alone stays RO for
            // `git stash list` style when third is list — keep simple: stash is RO
            // only as listed (historical); mutating `git stash push` still has
            // "stash" as tokens[1]. Tighten: only pure inspect subs.
            let sub = tokens[1]
            if sub == "stash" {
                // Bare `git stash` is stash push (mutates). Only list/show/… are RO.
                if tokens.count < 3 { return false }
                let action = tokens[2]
                let inspect = ["list", "show", "top"]
                return inspect.contains(action)
            }
            if sub == "branch" {
                // Bare `git branch` lists; create/delete/rename/force mutate.
                if tokens.count == 2 { return true }
                let action = tokens[2]
                // Common list flags only.
                if action == "-v" || action == "-vv" || action == "--list"
                    || action.hasPrefix("--list") || action == "-a" || action == "-r" {
                    return true
                }
                return false
            }
            if sub == "remote" {
                // Bare `git remote` / `git remote -v` inspect; add/remove/set-url mutate.
                if tokens.count == 2 { return true }
                let action = tokens[2]
                if action == "-v" || action == "--verbose" { return true }
                return readOnlyGitRemoteActions.contains(action)
            }
            if sub == "tag" {
                // Bare `git tag` lists tags. Create/delete mutate.
                if tokens.count == 2 { return true }
                let action = tokens[2]
                if readOnlyGitTagActions.contains(action) { return true }
                if action.hasPrefix("-l") || action.hasPrefix("--list") { return true }
                // Any other third token (name, -d, -a, …) is create/delete/annotate.
                return false
            }
            return readOnlyGitSubs.contains(sub)
        case "swift":
            guard tokens.count >= 2 else { return false }
            guard readOnlySwiftSubs.contains(tokens[1]) else { return false }
            // Bare `swift package` is inspect (prints help). Mutating
            // actions need a third token that is not on the inspect list.
            if tokens.count < 3 { return true }
            let action = tokens[2]
            if action.hasPrefix("-") { return true } // flags / help
            return readOnlySwiftPackageActions.contains(action)
        case "cargo":
            guard tokens.count >= 2 else { return false }
            return readOnlyCargoSubs.contains(tokens[1])
        case "kubectl":
            guard tokens.count >= 2 else { return false }
            return readOnlyKubectlSubs.contains(tokens[1])
        default:
            return readOnlyPrimaries.contains(primary)
        }
    }

    // MARK: - Tokenize

    /// Quote-aware tokenizer: splits on whitespace outside quotes; strips
    /// matching single/double quotes from tokens.
    public static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        var i = segment.startIndex

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        while i < segment.endIndex {
            let ch = segment[i]

            if escape {
                current.append(ch)
                escape = false
                i = segment.index(after: i)
                continue
            }

            if ch == "\\" && (inSingle || inDouble) {
                escape = true
                i = segment.index(after: i)
                continue
            }

            if ch == "'" && !inDouble {
                inSingle.toggle()
                i = segment.index(after: i)
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                i = segment.index(after: i)
                continue
            }

            if !inSingle && !inDouble && ch.isWhitespace {
                flush()
                i = segment.index(after: i)
                continue
            }

            current.append(ch)
            i = segment.index(after: i)
        }
        flush()
        return tokens
    }

    /// Drop leading wrappers (`env`, `nohup`, `time`, `timeout`, …) and their
    /// flags / `VAR=value` assignments so classification sees the real primary.
    /// Bare wrappers with no following command (`env`, `time`) are left intact
    /// so they can still match `readOnlyPrimaries`.
    public static func peelWrappers(_ tokens: [String]) -> [String] {
        var t = basenamePrimary(dropLeadingAssignments(tokens))
        while let first = t.first.map({ $0.lowercased() }),
              wrapperPrimaries.contains(first) {
            var probe = Array(t.dropFirst())
            // `timeout [options] DURATION command…` — skip flags then one duration.
            if first == "timeout" {
                while let head = probe.first, head.hasPrefix("-") {
                    // timeout -v / --verbose / -k SECS (skip value if next is not option)
                    if head == "-k" || head == "--kill-after" || head.hasPrefix("--kill-after=") {
                        probe.removeFirst()
                        if head == "-k" || head == "--kill-after", !probe.isEmpty, !probe[0].hasPrefix("-") {
                            probe.removeFirst()
                        }
                        continue
                    }
                    probe.removeFirst()
                }
                // Duration operand (required).
                if !probe.isEmpty, !probe[0].hasPrefix("-") {
                    probe.removeFirst()
                }
            } else if first == "xargs" {
                // `xargs [options] [command [initial-arguments]]`
                while let head = probe.first, head.hasPrefix("-") {
                    // Options that take a separate value: -n N, -P N, -s N, -I repl, -i, -E eof, -e
                    let needsValue: Set<String> = ["-n", "-P", "-s", "-I", "-E", "-e", "-L", "-l"]
                    probe.removeFirst()
                    if needsValue.contains(head), !probe.isEmpty, !probe[0].hasPrefix("-") {
                        probe.removeFirst()
                    } else if head.hasPrefix("-n") || head.hasPrefix("-P") || head.hasPrefix("-s"),
                              head.count > 2 {
                        // Combined form -n2 etc. — already consumed.
                    }
                }
            } else if first == "nice" {
                // `nice [-n N | --adjustment=N] command…`
                while let head = probe.first {
                    if head == "-n" || head == "--adjustment" {
                        probe.removeFirst()
                        if !probe.isEmpty, !probe[0].hasPrefix("-") {
                            probe.removeFirst()
                        }
                        continue
                    }
                    if head.hasPrefix("--adjustment=") {
                        probe.removeFirst()
                        continue
                    }
                    if head.hasPrefix("-n"), head.count > 2 {
                        probe.removeFirst()
                        continue
                    }
                    if head.hasPrefix("-") {
                        probe.removeFirst()
                        continue
                    }
                    break
                }
            } else {
                while let head = probe.first {
                    if head.hasPrefix("-") {
                        probe.removeFirst()
                        continue
                    }
                    if head.contains("=") && !head.hasPrefix("-") {
                        probe.removeFirst()
                        continue
                    }
                    break
                }
            }
            guard !probe.isEmpty else { break }
            t = basenamePrimary(dropLeadingAssignments(probe))
        }
        return t
    }

    /// `VAR=value` tokens that precede a command (`FOO=1 rm …`).
    private static func isAssignmentToken(_ token: String) -> Bool {
        guard !token.hasPrefix("-"),
              let eq = token.firstIndex(of: "="),
              eq > token.startIndex else { return false }
        return true
    }

    private static func dropLeadingAssignments(_ tokens: [String]) -> [String] {
        var t = tokens
        while let first = t.first, isAssignmentToken(first) {
            t.removeFirst()
        }
        return t
    }

    /// Classify `/bin/rm` / `/usr/bin/chmod` by basename, not only the prefix.
    private static func basenamePrimary(_ tokens: [String]) -> [String] {
        guard let first = tokens.first else { return tokens }
        let base = (first as NSString).lastPathComponent
        guard !base.isEmpty, base != first else { return tokens }
        var out = tokens
        out[0] = base
        return out
    }

    /// Drop `git -C <dir>` / `--git-dir=` / other globals so `git push` is visible.
    static func peelGitGlobalOptions(_ tokens: [String]) -> [String] {
        guard let first = tokens.first?.lowercased(), first == "git" else { return tokens }
        var i = 1
        let takesValue: Set<String> = [
            "-c", "-C",
            "--git-dir", "--work-tree", "--namespace",
            "--config-env", "--exec-path",
        ]
        let boolFlags: Set<String> = [
            "-p", "-P", "--paginate", "--no-pager",
            "--bare", "--help", "--version",
            "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks",
            "--literal-pathspecs", "--glob-pathspecs",
            "--noglob-pathspecs", "--icase-pathspecs",
        ]
        while i < tokens.count {
            let t = tokens[i]
            let lower = t.lowercased()
            if takesValue.contains(t) || takesValue.contains(lower) {
                i += 2
                continue
            }
            if lower.hasPrefix("--git-dir=") || lower.hasPrefix("--work-tree=")
                || lower.hasPrefix("--namespace=") || lower.hasPrefix("--config-env=")
                || lower.hasPrefix("--exec-path=") {
                i += 1
                continue
            }
            if boolFlags.contains(t) || boolFlags.contains(lower) {
                i += 1
                continue
            }
            break
        }
        guard i > 1, i <= tokens.count else { return tokens }
        if i >= tokens.count { return ["git"] }
        return ["git"] + Array(tokens[i...])
    }

    /// `$(…)` and backtick payloads outside single quotes.
    public static func commandSubstitutionPayloads(in command: String) -> [String] {
        var payloads: [String] = []
        var i = command.startIndex
        var inSingle = false
        var inDouble = false
        var escape = false
        while i < command.endIndex {
            let ch = command[i]
            if escape {
                escape = false
                i = command.index(after: i)
                continue
            }
            if ch == "\\" {
                escape = true
                i = command.index(after: i)
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                i = command.index(after: i)
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                i = command.index(after: i)
                continue
            }
            if inSingle {
                i = command.index(after: i)
                continue
            }
            if ch == "$" {
                let next = command.index(after: i)
                if next < command.endIndex, command[next] == "(" {
                    let (payload, end) = extractBalancedParenPayload(command, openParen: next)
                    payloads.append(payload)
                    i = end
                    continue
                }
            }
            if ch == "`" {
                let (payload, end) = extractBacktickPayload(command, openTick: i)
                payloads.append(payload)
                i = end
                continue
            }
            i = command.index(after: i)
        }
        return payloads
    }

    /// Unclosed `$(` fails closed: remaining text is the payload.
    private static func extractBalancedParenPayload(
        _ s: String, openParen: String.Index
    ) -> (String, String.Index) {
        var depth = 1
        var i = s.index(after: openParen)
        var inSingle = false
        var inDouble = false
        var escape = false
        while i < s.endIndex {
            let ch = s[i]
            if escape {
                escape = false
                i = s.index(after: i)
                continue
            }
            if ch == "\\" {
                escape = true
                i = s.index(after: i)
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                i = s.index(after: i)
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                i = s.index(after: i)
                continue
            }
            if !inSingle && !inDouble {
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        let payload = String(s[s.index(after: openParen)..<i])
                        return (payload, s.index(after: i))
                    }
                }
            }
            i = s.index(after: i)
        }
        return (String(s[s.index(after: openParen)...]), s.endIndex)
    }

    private static func extractBacktickPayload(
        _ s: String, openTick: String.Index
    ) -> (String, String.Index) {
        var i = s.index(after: openTick)
        var escape = false
        while i < s.endIndex {
            let ch = s[i]
            if escape {
                escape = false
                i = s.index(after: i)
                continue
            }
            if ch == "\\" {
                escape = true
                i = s.index(after: i)
                continue
            }
            if ch == "`" {
                let payload = String(s[s.index(after: openTick)..<i])
                return (payload, s.index(after: i))
            }
            i = s.index(after: i)
        }
        return (String(s[s.index(after: openTick)...]), s.endIndex)
    }

    /// Extract `bash -c 'script'` / `sh -lc 'script'` payload when present.
    public static func nestedShellScript(from tokens: [String]) -> String? {
        guard let primary = tokens.first?.lowercased() else { return nil }
        let base = (primary as NSString).lastPathComponent
        guard shellInterpreters.contains(primary) || shellInterpreters.contains(base) else {
            return nil
        }
        return extractDashCPayload(from: tokens)
    }

    /// Extract `python -c '…'` / `node -e '…'` style payloads.
    public static func nestedScriptInterpreterPayload(from tokens: [String]) -> String? {
        guard let primary = tokens.first?.lowercased() else { return nil }
        let base = (primary as NSString).lastPathComponent
        guard scriptInterpreters.contains(primary) || scriptInterpreters.contains(base) else {
            return nil
        }
        // python/node: -c CODE; node also -e CODE
        var i = 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "-c" || t == "-e" || t == "--command" || t.hasPrefix("-c") && t.count > 2 {
                if t == "-c" || t == "-e" || t == "--command" {
                    guard i + 1 < tokens.count else { return nil }
                    return tokens[i + 1]
                }
            }
            if t.hasPrefix("-") {
                i += 1
                continue
            }
            break
        }
        return extractDashCPayload(from: tokens)
    }

    private static func extractDashCPayload(from tokens: [String]) -> String? {
        var i = 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "-c" || t == "--command" {
                guard i + 1 < tokens.count else { return nil }
                return tokens[i + 1]
            }
            // `-lc`, `-ic`, etc. take the next arg as script.
            if t.hasPrefix("-"), !t.hasPrefix("--"), t.contains("c"), t != "-c" {
                guard i + 1 < tokens.count else { return nil }
                return tokens[i + 1]
            }
            if t.hasPrefix("-") {
                i += 1
                continue
            }
            break
        }
        return nil
    }

    /// Heuristic for language `-c` payloads (not full shell parsing).
    private static func payloadLooksDangerous(_ code: String) -> Bool {
        let c = code.lowercased()
        let needles = [
            "rm -", "rmdir", "shutil.rmtree", "os.remove", "os.unlink",
            "unlink(", "rmtree", "subprocess", "os.system", "popen(",
            "chmod", "chown", "kill(", "os.kill", "git push", "mkfs",
            "dd if=", "dd of=", "/dev/", "eval(", "exec(",
        ]
        return needles.contains(where: { c.contains($0) })
    }

    // MARK: - Seatbelt / sandbox-exec (PB8)

    /// When seatbelt is enabled but `/usr/bin/sandbox-exec` is missing or
    /// cannot be launched:
    /// - `.open` (default): run the shell **without** a sandbox and note it.
    /// - `.closed`: refuse to run the command (error tool result).
    public enum SeatbeltFailMode: String, Sendable, Equatable {
        case open
        case closed
    }

    /// Resolved process launch for `run_shell` (sandboxed or bare).
    public struct ShellLaunch: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        /// True when the launch uses `sandbox-exec`.
        public let sandboxed: Bool
        /// Seatbelt SBPL profile when sandboxed; empty otherwise.
        public let profile: String
        /// Human note for tool output (e.g. fail-open fallback).
        public let note: String?

        public init(executable: String,
                    arguments: [String],
                    sandboxed: Bool,
                    profile: String = "",
                    note: String? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.sandboxed = sandboxed
            self.profile = profile
            self.note = note
        }
    }

    /// Env keys (first match wins): `VIBECODER_SHELL_SEATBELT`, `AGENTOS_SHELL_SEATBELT`.
    /// Values: `1`/`true`/`on`/`yes` → on; `0`/`false`/`off`/`no` → off.
    /// When unset: **on for Auto (`ExecutionMode.edit`)**, off for plan/ask/yolo.
    public static func isSeatbeltEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executionMode: ExecutionMode? = nil
    ) -> Bool {
        if let raw = environment["VIBECODER_SHELL_SEATBELT"]
            ?? environment["AGENTOS_SHELL_SEATBELT"] {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "on", "yes": return true
            case "0", "false", "off", "no": return false
            default: break
            }
        }
        // Default: seatbelt for Auto (edit) only — Full/yolo stays unrestricted
        // unless the user opts in via env.
        return executionMode == .edit
    }

    /// `VIBECODER_SHELL_SEATBELT_FAIL` / `AGENTOS_SHELL_SEATBELT_FAIL`:
    /// `closed` | `open` (default **open**).
    public static func seatbeltFailMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SeatbeltFailMode {
        let raw = (environment["VIBECODER_SHELL_SEATBELT_FAIL"]
            ?? environment["AGENTOS_SHELL_SEATBELT_FAIL"]
            ?? "open")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "closed" ? .closed : .open
    }

    /// Build a seatbelt (SBPL) profile that allows the default set of
    /// operations but **denies file writes** outside `writableRoots` plus
    /// system temp directories. Read / exec / network remain under
    /// `(allow default)` — this is a write fence for agent shells, not a
    /// full App Sandbox.
    ///
    /// Honesty: `sandbox-exec` is **deprecated** by Apple (prefer App Sandbox
    /// entitlements for product apps). We still use it as an optional
    /// child-process fence for local agent tools; profiles are best-effort
    /// and do not replace Safe Mode / authorization.
    public static func makeSeatbeltProfile(writableRoots: [String]) -> String {
        var roots = writableRoots
            .map { ($0 as NSString).standardizingPath }
            .filter { !$0.isEmpty }
        // Always allow system temp areas used by shells and package tools.
        let temps = [
            "/tmp",
            "/private/tmp",
            "/private/var/folders",
            "/var/folders",
            NSTemporaryDirectory(),
        ]
        for t in temps {
            let p = (t as NSString).standardizingPath
            if !p.isEmpty { roots.append(p) }
        }
        // De-dupe while preserving order.
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0).inserted }

        var lines: [String] = [
            "(version 1)",
            ";; VibeCoder SafeBash seatbelt — write fence for run_shell children",
            ";; (allow default) keeps read/exec/network; file-write* re-allowed per root.",
            "(allow default)",
            "(deny file-write*)",
            "(deny file-write-create)",
        ]
        if !roots.isEmpty {
            lines.append("(allow file-write*")
            for root in roots {
                lines.append("  (subpath \(sbplString(root)))")
            }
            lines.append(")")
            lines.append("(allow file-write-create")
            for root in roots {
                lines.append("  (subpath \(sbplString(root)))")
            }
            lines.append(")")
        }
        // Common device nodes tools expect to write to.
        lines.append("(allow file-write-data")
        lines.append("  (literal \"/dev/null\")")
        lines.append("  (literal \"/dev/zero\")")
        lines.append("  (literal \"/dev/dtracehelper\")")
        lines.append("  (literal \"/dev/tty\")")
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quote a path/string for SBPL string literals.
    public static func sbplString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Collect absolute writable roots for a tool context (project, worktree, cwd).
    ///
    /// When a **worktree** is active, only the worktree (plus cwd if it is
    /// already under that worktree) is writable — never the main project
    /// checkout. Otherwise isolation is a lie via shell seatbelt.
    public static func writableRoots(
        workingDirectory: URL?,
        projectRoot: URL?,
        worktreeRoot: URL?
    ) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url else { return }
            let p = (url.path as NSString).standardizingPath
            guard !p.isEmpty, seen.insert(p).inserted else { return }
            roots.append(p)
        }
        if let worktreeRoot {
            // Isolation: seatbelt must not allow writes to the main tree.
            add(worktreeRoot)
            if let workingDirectory {
                let wt = (worktreeRoot.path as NSString).standardizingPath
                let cwd = (workingDirectory.path as NSString).standardizingPath
                if cwd == wt || cwd.hasPrefix(wt + "/") {
                    add(workingDirectory)
                }
            }
            return roots
        }
        add(projectRoot)
        add(workingDirectory)
        return roots
    }

    /// Build a sandboxed launch (`sandbox-exec -p PROFILE shell -c command`).
    /// Returns `nil` when the profile would have no writable roots (caller
    /// should treat as misconfiguration).
    public static func seatbeltInvocation(
        command: String,
        writableRoots: [String],
        shellPath: String = "/bin/zsh",
        sandboxExecPath: String = "/usr/bin/sandbox-exec"
    ) -> ShellLaunch? {
        guard !writableRoots.isEmpty else { return nil }
        let profile = makeSeatbeltProfile(writableRoots: writableRoots)
        return ShellLaunch(
            executable: sandboxExecPath,
            arguments: ["-p", profile, shellPath, "-c", command],
            sandboxed: true,
            profile: profile,
            note: nil
        )
    }

    /// Resolve foreground (or background-wrapped) shell launch for `run_shell`.
    ///
    /// - When seatbelt is **disabled**: bare `/bin/zsh -c command`.
    /// - When **enabled** and `sandbox-exec` exists: wrap with seatbelt profile.
    /// - When **enabled** and binary missing: fail-open → bare shell + note, or
    ///   fail-closed → `sandboxed: false` with a blocking note (caller errors).
    public static func resolveShellLaunch(
        command: String,
        workingDirectory: URL?,
        projectRoot: URL?,
        worktreeRoot: URL?,
        executionMode: ExecutionMode?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String = "/bin/zsh",
        sandboxExecPath: String = "/usr/bin/sandbox-exec",
        fileManager: FileManager = .default
    ) -> ShellLaunch {
        let bare = ShellLaunch(
            executable: shellPath,
            arguments: ["-c", command],
            sandboxed: false,
            profile: "",
            note: nil
        )

        guard isSeatbeltEnabled(environment: environment, executionMode: executionMode) else {
            return bare
        }

        let roots = writableRoots(
            workingDirectory: workingDirectory,
            projectRoot: projectRoot,
            worktreeRoot: worktreeRoot
        )
        guard !roots.isEmpty else {
            let fail = seatbeltFailMode(environment: environment)
            if fail == .closed {
                return ShellLaunch(
                    executable: shellPath,
                    arguments: ["-c", command],
                    sandboxed: false,
                    note: "seatbelt: refused — no writable project/worktree root (fail-closed)"
                )
            }
            return ShellLaunch(
                executable: shellPath,
                arguments: ["-c", command],
                sandboxed: false,
                note: "seatbelt: skipped — no writable roots (fail-open)"
            )
        }

        let binaryOK = fileManager.isExecutableFile(atPath: sandboxExecPath)
        guard binaryOK else {
            if seatbeltFailMode(environment: environment) == .closed {
                return ShellLaunch(
                    executable: shellPath,
                    arguments: ["-c", command],
                    sandboxed: false,
                    note: "seatbelt: refused — sandbox-exec not found at \(sandboxExecPath) (fail-closed)"
                )
            }
            return ShellLaunch(
                executable: shellPath,
                arguments: ["-c", command],
                sandboxed: false,
                note: "seatbelt: skipped — sandbox-exec not found (fail-open)"
            )
        }

        guard let boxed = seatbeltInvocation(
            command: command,
            writableRoots: roots,
            shellPath: shellPath,
            sandboxExecPath: sandboxExecPath
        ) else {
            return bare
        }
        return boxed
    }

    /// True when a launch note indicates fail-closed refusal (do not run).
    public static func isSeatbeltRefusal(_ launch: ShellLaunch) -> Bool {
        guard let note = launch.note else { return false }
        return note.contains("refused")
    }
}

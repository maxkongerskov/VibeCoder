//
//  StopDetector.swift
//
//  Heuristic stop-detector for premature "give up" turn endings, ported
//  from Grok Build's `xai-grok-shell/src/session/goal_stop_detector.rs`.
//
//  The model is judged to be bailing out when the LAST non-empty
//  paragraph of its turn-final text starts with one of the patterns
//  commonly used as a bail / hand-off / verdict signal. On a hit, the
//  agent loop renders a bail-specific continuation nudge (instead of the
//  generic one) to defeat the premature stop and keep the goal running.
//
//  This is a DEFENSE against premature stops, not a kill switch. The
//  only real stops are: goal achieved (verifier), cap exhaustion, stall
//  detection (no progress), explicit blocked status, budget exceeded,
//  infrastructure failure, or user cancellation. This detector catches
//  the model bailing out *before* those conditions are met and pushes it
//  back on track.
//
//  DESIGN (matches Grok Build):
//    - Regexes are ^-anchored so mid-sentence mentions don't fire.
//      "I can't continue without your input" in the MIDDLE of a paragraph
//      is ignored; "I can't proceed" at the START of the last line fires.
//    - The CHECK_BACK_LATER pattern has a two-stage form: broad first
//      regex + user-pronoun post-filter, because Swift's NSRegex doesn't
//      support negative lookaheads and we need to reject "I'll check back
//      when you're ready" (deferral to user) while catching "I'll check
//      back in 5 minutes" (self-bail).
//    - Patterns are evaluated in declaration order; first match wins.
//

import Foundation

/// A premature-stop pattern label, stable across telemetry/log boundaries.
///
/// These are the same labels Grok Build emits in `Event::GoalPrematureStopDetected.pattern`,
/// so dashboards auditing precision/recall see consistent values.
public enum StopPattern: String, Sendable, CaseIterable {
    case unableToProceed
    case givingUp
    case stoppingHere
    case agentsInFlight
    case checkBackLater
    case verdictLine
    case commitPushPr
    case readyForReview
    case pleaseDeflection

    /// Human-readable description of what this pattern detects, for the
    /// continuation nudge and for diagnostics.
    public var description: String {
        switch self {
        case .unableToProceed:   return "claims inability to proceed/continue"
        case .givingUp:          return "explicitly giving up or task not actionable"
        case .stoppingHere:      return "stopping/parking/pausing the branch here"
        case .agentsInFlight:    return "deferring to background agents/cron/loops"
        case .checkBackLater:    return "checking back / retrying later (self-bail)"
        case .verdictLine:       return "self-signing off with VERDICT: PASS|FAIL"
        case .commitPushPr:      return "handing off after commit/push/PR-opened"
        case .readyForReview:    return "marking ready for review/merge/ship"
        case .pleaseDeflection:  return "deflecting to the user with 'Please <verb> X for me'"
        }
    }

    /// The source regex string this label is locked to (for audit).
    public var regexSource: String {
        switch self {
        case .unableToProceed:   return #"^I (?:can(?:'?t|not)|am unable to) (?:proceed|continue|make (?:any )?progress|complete|fix this)\b"#
        case .givingUp:          return #"^(?:Giving up|I(?:'m| am) giving up|The task is not actionable)\b"#
        case .stoppingHere:      return #"^(?:Stopping here|I've stopped here|Parked (?:the|this) branch|Paused here)(?:\.|,|;|$| for | —| -| until| pending| since| because)"#
        case .agentsInFlight:    return #"^(?:(?:\*\*)?[1-9]\d* (?:agent|cron|task|fork|job|worker|PR|check)s? (?:in flight|remaining|active|still (?:running|working)|pending|running|launched)\b|(?:Continuous )?(?:[Ll]oop|[Cc]rons?|[Bb]abysit) (?:active|healthy|continuing|running|will keep|continues)\b|Waiting for (?:the )?(?:agent|cron|task|fork|worker|job|remaining|them)s?\b|Agents? will report back\b|Waiting\.?$)"#
        case .checkBackLater:    return #"^(?:I will|I'll|Will) (?:check back|re-?check|poll|look again|retry|re-?run|try again) (?:in\b|again\b|(?:when|once|after|until)\s+(\S+))"#
        case .verdictLine:       return #"^VERDICT: (?:PASS|FAIL)\b"#
        case .commitPushPr:      return #"^(?:Pushed (?:to `|`[0-9a-f]{7,})|Committed as `?[0-9a-f]{7,}\b|Commit: `?[0-9a-f]{7,}\b|(?:Opened|Created) PR #?\d)"#
        case .readyForReview:    return #"^Ready (?:for review|to (?:upload|merge|ship|land))\b"#
        case .pleaseDeflection:  return #"^Please (?:start|run|provide|grant|export|add|install|configure|give me|paste|point me|set (?:the |up |`?[A-Z][A-Z0-9_]+\b))"#
        }
    }
}

/// Pure-function stop-pattern detector. No I/O, no state — give it the
/// model's turn-final text and it returns the first matching pattern (or nil).
///
/// Usage from the agent loop:
/// ```swift
/// if let pattern = StopDetector.matchedStopPattern(assistantText) {
///     // Model is bailing out — inject a continuation nudge to defeat it.
///     let nudge = StopDetector.continuationNudge(for: pattern)
/// }
/// ```
public enum StopDetector {

    /// Returns the first matched stop pattern when the LAST non-empty
    /// paragraph of `text` contains a line that triggers any reference
    /// stop pattern. Patterns are evaluated in declaration order; first
    /// match wins (matching Grok Build's `matched_stop_pattern`).
    ///
    /// **Paragraph extraction**: the text is split on blank lines; we take
    /// the last non-empty paragraph. Within it, each line is tested against
    /// all patterns in order. This means "I can't proceed" on the LAST line
    /// of the response triggers, but the same phrase buried mid-paragraph
    /// in an earlier paragraph does not.
    public static func matchedStopPattern(_ text: String) -> StopPattern? {
        // Normalize line endings (CRLF → LF), then split into paragraphs.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")

        // Find the last non-empty paragraph. Trailing whitespace-only lines
        // are skipped so a response that ends with "I'm done.\n\n  \n" still
        // evaluates the "I'm done." paragraph.
        guard let lastParagraph = paragraphs.reversed().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }

        // Test each non-empty line in the last paragraph, in order.
        for line in lastParagraph.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            for pattern in StopPattern.allCases {
                if matches(pattern: pattern, line: trimmed) {
                    return pattern
                }
            }
        }
        return nil
    }

    /// Convenience: does the text match ANY stop pattern? (For callers
    /// that don't need to know which one.)
    public static func looksLikePrematureStop(_ text: String) -> Bool {
        matchedStopPattern(text) != nil
    }

    /// The continuation nudge injected when a premature stop is detected.
    ///
    /// This DEFEATS the bail: instead of letting the model end the turn,
    /// we re-inject a directive that says "you appear to be stopping, but
    /// the goal is NOT complete — continue working." The goal stays Active.
    public static func continuationNudge(for pattern: StopPattern) -> String {
        """
        # Course-correction (premature stop detected)

        You appear to be stopping (\(pattern.description)), but the goal is NOT complete.
        Do not hand off, defer to background tasks, or wait for external input.

        Before your next action:
        1. Re-read the goal and your current progress. What concrete step is next?
        2. If a tool failed, read the error literally and change your approach.
        3. Do not say "I can't" or "stopping here" — if you're stuck, describe the
           specific blocker and what you'd need to get past it.
        4. Continue working until the goal is achieved or genuinely blocked by an
           external dependency you cannot resolve yourself.
        """
    }

    // MARK: - Pattern matching

    /// Test one line against one pattern. Returns true if the line matches.
    ///
    /// Most patterns are a single regex test. The `checkBackLater` pattern
    /// has a two-stage form: broad first regex + user-pronoun post-filter.
    /// The filter rejects "I'll check back when you're ready" (deferral to
    /// user) while catching "I'll check back in 5 minutes" (self-bail).
    static func matches(pattern: StopPattern, line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern.regexSource, options: []) else {
            return false
        }
        let range = NSRange(line.startIndex..., in: line)
        guard regex.firstMatch(in: line, options: [], range: range) != nil else {
            return false
        }

        // CHECK_BACK_LATER post-filter: if the broad regex captured a trailing
        // token after when/once/after/until, reject user-pronoun targets.
        if pattern == .checkBackLater {
            return !isUserPronounDeferral(line, regex)
        }
        return true
    }

    /// For the CHECK_BACK_LATER pattern: does `line` end with a deferral
    /// to the user (you/your) rather than a self-bail?
    ///
    /// "I'll check back when you're ready" → deferral to user → reject.
    /// "I'll check back in 5 minutes" → self-bail → accept.
    ///
    /// We extract the trailing token from the capture group (if any) and
    /// check if it starts with `you` or `your` followed by a non-word
    /// character. This mirrors Grok Build's `is_user_pronoun`.
    static func isUserPronounDeferral(_ line: String, _ broadRegex: NSRegularExpression) -> Bool {
        // Find the captured group (the token after when/once/after/until).
        let range = NSRange(line.startIndex..., in: line)
        guard let match = broadRegex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: line) else {
            // No capture (in/again branches have no group) → always a bail.
            return false
        }

        let token = String(line[captureRange]).lowercased()
        for stem in ["your", "you"] {
            if token.hasPrefix(stem) {
                let rest = String(token.dropFirst(stem.count))
                // Next char must be non-word (or end of string) to match.
                if rest.isEmpty { return true }
                let firstChar = rest.first!
                if !firstChar.isLetter && firstChar != "_" { return true }
            }
        }
        return false
    }

    /// True iff `token` starts with `you` or `your` followed by a
    /// non-word boundary (end-of-string, space, punctuation). Mirrors
    /// Grok Build's `is_user_pronoun`.
    static func isUserPronoun(_ token: String) -> Bool {
        let lower = token.lowercased()
        for stem in ["your", "you"] {
            if lower.hasPrefix(stem) {
                let rest = String(lower.dropFirst(stem.count))
                if rest.isEmpty { return true }
                guard let firstChar = rest.first else { return true }
                if !firstChar.isLetter && firstChar != "_" { return true }
            }
        }
        return false
    }
}
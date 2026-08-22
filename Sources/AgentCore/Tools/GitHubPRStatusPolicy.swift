//
//  GitHubPRStatusPolicy.swift
//
//  Harness-speed cut: models waste turns on web_search + curl/python
//  against api.github.com, then misread compare as unmerged. Prefer `gh`,
//  and when merged=true / MERGED, say so in one line so the loop stops.
//

import Foundation

public enum GitHubPRStatusPolicy: Sendable {

    public static let preferGhMessage = """
        Refused: do not curl or python the GitHub REST API for pull-request or compare status. \
        Use `gh pr view <N> --json state,mergedAt,title,url` or \
        `gh api repos/<owner>/<repo>/pulls/<N>`. \
        If the result has merged=true or state MERGED, stop — do not probe compare or search again.
        """

    public static let mergedBanner =
        "PR_STATUS: MERGED (merged=true). This pull request is already merged. Do not call compare, curl, python, or web_search again — answer from this result."

    /// Curl/python hitting api.github.com for PR/compare → fail closed with gh guidance.
    /// Leaves non-GitHub curl and `gh` itself alone.
    public static func preferGhDenial(forShellCommand command: String) -> String? {
        let c = command.lowercased()
        if isGhClient(c) { return nil }
        guard hitsGitHubAPI(c) else { return nil }
        guard isCurlOrPython(c) else { return nil }
        guard isPROrComparePath(c) else { return nil }
        return preferGhMessage
    }

    /// fetch_url of the REST PR/compare endpoints — same guidance.
    public static func preferGhDenial(forFetchURL url: String) -> String? {
        let u = url.lowercased()
        guard hitsGitHubAPI(u) else { return nil }
        guard isPROrComparePath(u) else { return nil }
        return preferGhMessage
    }

    public static func shouldAnnotateShellCommand(_ command: String) -> Bool {
        let c = command.lowercased()
        return isGhClient(c) || hitsGitHubAPI(c) || c.contains("github.com")
    }

    public static func decorateIfMerged(_ content: String) -> String {
        guard looksMerged(content) else { return content }
        if content.hasPrefix("PR_STATUS: MERGED") { return content }
        return mergedBanner + "\n\n" + content
    }

    public static func looksMerged(_ content: String) -> Bool {
        if content.range(
            of: #"["']?merged["']?\s*[:=]\s*true"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if content.range(of: #"\bMERGED\b"#, options: .regularExpression) != nil {
            return true
        }
        if content.range(
            of: #""mergedAt"\s*:\s*"20"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return false
    }


    /// Terminal answer already in the tool result — stop more probes.
    public static func shouldStopAfterMerged(_ content: String?) -> Bool {
        guard let content, !content.isEmpty else { return false }
        if content.hasPrefix("PR_STATUS: MERGED") { return true }
        return looksMerged(content)
    }

    private static func isGhClient(_ c: String) -> Bool {
        let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "gh" || t.hasPrefix("gh ") { return true }
        if t.hasPrefix("/usr/bin/gh ") || t.hasPrefix("/opt/homebrew/bin/gh ") { return true }
        if t.contains(" gh pr ") || t.contains(" gh api ") { return true }
        return false
    }

    private static func hitsGitHubAPI(_ c: String) -> Bool {
        c.contains("api.github.com")
    }

    private static func isCurlOrPython(_ c: String) -> Bool {
        c.contains("curl")
            || c.contains("python")
            || c.contains("urllib")
            || c.contains("http.client")
            || c.contains("requests.")
            || c.contains("import requests")
    }

    private static func isPROrComparePath(_ c: String) -> Bool {
        c.contains("/pulls")
            || c.contains("/pull/")
            || c.contains("/compare")
            || c.contains("pullrequest")
    }
}

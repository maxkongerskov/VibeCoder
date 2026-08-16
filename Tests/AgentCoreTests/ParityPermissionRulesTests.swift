//
//  ParityPermissionRulesTests.swift
//
//  ZCode-parity command-prefix + host rules + suggested permission updates.
//

import XCTest
@testable import AgentCore

final class ParityPermissionRulesTests: XCTestCase {

    private func ctx(
        root: URL = FileManager.default.temporaryDirectory,
        mode: ExecutionMode = .edit,
        auth: AuthorizationConfig = .empty
    ) -> ToolContext {
        ToolContext(
            projectRoot: root,
            conversationID: UUID(),
            executionMode: mode,
            authorization: auth
        )
    }

    // MARK: - Prefix match / non-match

    func testPrefixMatchGitStatusAndColonStar() {
        let bare = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "git status")
        let starred = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "git status:*")

        XCTAssertTrue(bare.matches(tool: "run_shell", command: "git status"))
        XCTAssertTrue(bare.matches(tool: "run_shell", command: "git status -sb"))
        XCTAssertTrue(bare.matches(tool: "run_shell", command: "git status\t-sb"))
        XCTAssertTrue(starred.matches(tool: "run_shell", command: "git status"))
        XCTAssertTrue(starred.matches(tool: "run_shell", command: "git status -sb"))
    }

    func testPrefixMatchNpmRun() {
        let rule = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "npm run")
        XCTAssertTrue(rule.matches(tool: "run_shell", command: "npm run"))
        XCTAssertTrue(rule.matches(tool: "run_shell", command: "npm run build"))
        XCTAssertTrue(rule.matches(tool: "run_shell", command: "npm run test -- --watch"))
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "npm install"))
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "npm-run-all"))
    }

    func testPrefixNonMatch() {
        let rule = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "git status")
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "git commit"))
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "git statusx"))
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "echo git status"))
        XCTAssertFalse(rule.matches(tool: "run_shell", command: "git"))
        XCTAssertFalse(rule.matches(tool: "write_file", command: "git status"))
    }

    func testPrefixAllowDoesNotCoverChainedOtherCommand() {
        let rule = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "git status")
        let auth = AuthorizationConfig(rules: [rule], useInlineRememberedOnly: true)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: [
                "command": "git status && npm install left-pad"
            ]),
            context: ctx(mode: .edit, auth: auth),
            config: auth
        )
        guard case .ask = outcome else {
            return XCTFail("chain must not ride git status allow, got \(outcome)")
        }
    }

    func testPrefixAllowEvaluatesInAskMode() {
        let rule = AuthorizationRule(
            kind: .allow, toolName: "run_shell", ruleContent: "npm run")
        let auth = AuthorizationConfig(rules: [rule], useInlineRememberedOnly: true)
        let outcome = ToolAuthorization.evaluate(
            toolName: "run_shell",
            permission: .executes,
            arguments: ToolArguments(dictionary: ["command": "npm run build"]),
            context: ctx(mode: .edit, auth: auth),
            config: auth
        )
        guard case .allow = outcome else {
            return XCTFail("allow prefix npm run should skip Auto ask, got \(outcome)")
        }
    }

    // MARK: - Glob host

    func testGlobHostSuffix() {
        let rule = AuthorizationRule(
            kind: .deny, toolName: "fetch_url", ruleContent: "*.example.com")
        XCTAssertTrue(rule.matches(
            tool: "fetch_url", command: nil, url: "https://foo.example.com/x"))
        XCTAssertTrue(rule.matches(
            tool: "fetch_url", command: nil, url: "https://a.b.example.com/"))
        XCTAssertTrue(rule.matches(
            tool: "fetch_url", command: nil, url: "https://example.com/path"))
        XCTAssertFalse(rule.matches(
            tool: "fetch_url", command: nil, url: "https://evil.com/"))
        XCTAssertFalse(rule.matches(
            tool: "fetch_url", command: nil, url: "https://example.com.evil.test/"))
    }

    func testWebSearchSiteQueryHost() {
        let rule = AuthorizationRule(
            kind: .allow, toolName: "web_search", ruleContent: "*.example.com")
        XCTAssertTrue(rule.matches(
            tool: "web_search", command: nil, url: nil,
            query: "site:docs.example.com swift concurrency"))
        XCTAssertFalse(rule.matches(
            tool: "web_search", command: nil, url: nil,
            query: "site:other.test swift"))
    }

    func testDomainDenyEvaluates() {
        let rule = AuthorizationRule(
            kind: .deny, toolName: "fetch_url", ruleContent: "*.evil.com")
        let auth = AuthorizationConfig(rules: [rule], useInlineRememberedOnly: true)
        let blocked = ToolAuthorization.evaluate(
            toolName: "fetch_url",
            permission: .network,
            arguments: ToolArguments(dictionary: ["url": "https://a.evil.com/secret"]),
            context: ctx(mode: .yolo, auth: auth),
            config: auth
        )
        guard case .deny = blocked else {
            return XCTFail("glob host deny must block, got \(blocked)")
        }
        let allowed = ToolAuthorization.evaluate(
            toolName: "fetch_url",
            permission: .network,
            arguments: ToolArguments(dictionary: ["url": "https://example.com/ok"]),
            context: ctx(mode: .yolo, auth: auth),
            config: auth
        )
        guard case .allow = allowed else {
            return XCTFail("unrelated host should still allow, got \(allowed)")
        }
    }

    // MARK: - Suggestions

    func testSuggestionsForGitStatusDashSb() {
        let suggestions = ToolAuthorization.suggestions(forShellCommand: "git status -sb")
        XCTAssertTrue(
            suggestions.contains {
                $0.toolName == "run_shell"
                    && $0.ruleContent == "git status"
                    && $0.behavior == .allow
            },
            "suggestions=\(suggestions)"
        )
        XCTAssertEqual(suggestions.first?.approvalLabel, "Always allow git status")
        XCTAssertEqual(
            CommandPrefixNormalizer.prefix(for: "git status -sb"),
            "git status"
        )
        XCTAssertEqual(
            CommandPrefixNormalizer.prefix(for: "npm run build -- --watch"),
            "npm run"
        )
        XCTAssertEqual(
            CommandPrefixNormalizer.prefix(for: "docker compose up -d"),
            "docker compose"
        )
        XCTAssertEqual(
            CommandPrefixNormalizer.prefix(for: "kubectl get pods"),
            "kubectl get"
        )
    }

    func testSuggestionsSkipDangerous() {
        XCTAssertTrue(
            ToolAuthorization.suggestions(forShellCommand: "rm -rf /tmp/x").isEmpty
        )
    }

    func testParseRuleContentJSON() {
        let snap = PermissionRules.parsePermissionsJSON(string: """
        {
          "rules": [
            { "kind": "allow", "tool": "run_shell", "ruleContent": "git status" },
            { "kind": "deny", "tool": "fetch_url", "host": "*.evil.com" }
          ]
        }
        """, projectKey: "/p")
        XCTAssertEqual(snap.rules.count, 2)
        XCTAssertEqual(snap.rules[0].ruleContent, "git status")
        XCTAssertEqual(snap.rules[1].ruleContent, "*.evil.com")
        XCTAssertTrue(snap.rules[0].matches(tool: "run_shell", command: "git status -sb"))
    }

    func testClaudeBashKeepsCommandContainsAndPrefix() {
        let rules = PermissionRules.rulesFromClaudeStyleEntry(
            "Bash(git status)", kind: .allow)
        XCTAssertEqual(rules[0].toolName, "run_shell")
        XCTAssertEqual(rules[0].commandContains, "git status")
        XCTAssertEqual(rules[0].ruleContent, "git status")
        XCTAssertTrue(rules[0].matches(tool: "run_shell", command: "git status -sb"))

        let fetch = PermissionRules.rulesFromClaudeStyleEntry(
            "WebFetch(*.example.com)", kind: .deny)
        XCTAssertEqual(fetch[0].toolName, "fetch_url")
        XCTAssertEqual(fetch[0].ruleContent, "*.example.com")
        XCTAssertTrue(fetch[0].matches(
            tool: "fetch_url", command: nil, url: "https://api.example.com/v1"))
    }
}

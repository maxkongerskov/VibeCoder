//
//  ProjectRulesTests.swift
//  Wave B S8: hierarchy always-on + CLAUDE / Cursor multi-convention.
//

import XCTest
@testable import AgentCore

final class ProjectRulesTests: XCTestCase {

    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testHierarchyNearerWinsAndCap() throws {
        let root = try tempRoot("rules")
        let child = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Root rules\nAlways use tabs.\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# Child rules\nAlways use spaces.\n"
            .write(to: child.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: child, maxChars: 6_000)
        XCTAssertEqual(snap.files.count, 2)
        XCTAssertTrue(snap.injectedText.contains("Root rules"))
        XCTAssertTrue(snap.injectedText.contains("Child rules"))
        // Child appears after root (higher precedence / nearer last)
        let rootIdx = snap.injectedText.range(of: "Root rules")!.lowerBound
        let childIdx = snap.injectedText.range(of: "Child rules")!.lowerBound
        XCTAssertTrue(childIdx > rootIdx)

        let tiny = ProjectRules.load(projectRoot: root, cwd: child, maxChars: 80)
        XCTAssertTrue(tiny.truncated || tiny.injectedText.count <= 120)
    }

    func testDirectoryChain() {
        let root = URL(fileURLWithPath: "/tmp/proj")
        let cwd = URL(fileURLWithPath: "/tmp/proj/a/b")
        let chain = ProjectRules.directoryChain(from: root, to: cwd)
        XCTAssertEqual(chain.map(\.path), ["/tmp/proj", "/tmp/proj/a", "/tmp/proj/a/b"])
    }

    /// Wave C: worktree sibling (cwd outside project root) must still load root rules.
    func testDirectoryChainOutsideRootKeepsProjectRoot() {
        let root = URL(fileURLWithPath: "/Users/me/proj")
        let worktree = URL(fileURLWithPath: "/Users/me/.agentcore/worktrees/proj-abc")
        let chain = ProjectRules.directoryChain(from: root, to: worktree)
        XCTAssertEqual(chain.map(\.path), [root.path, worktree.path])
    }

    func testWorktreeSiblingStillLoadsRootAgents() throws {
        let root = try tempRoot("rules-wt-root")
        let worktree = try tempRoot("rules-wt-sibling")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: worktree)
        }
        try "# Root AGENTS\nROOT_RULES_MARKER\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# Worktree only\nWT_RULES_MARKER\n"
            .write(to: worktree.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: worktree)
        XCTAssertTrue(snap.injectedText.contains("ROOT_RULES_MARKER"),
                      "root AGENTS must survive outside-root cwd: \(snap.injectedText.prefix(300))")
        XCTAssertTrue(snap.injectedText.contains("WT_RULES_MARKER"))
    }

    func testComposerInjectsRules() {
        let root = try! tempRoot("rules-compose")
        defer { try? FileManager.default.removeItem(at: root) }
        try! "# Project AGENTS\nPrefer edit_file.\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        var convo = Conversation(title: "t")
        convo.projectRoot = root
        let (prompt, _) = AgentSystemPromptComposer.compose(
            .init(
                conversation: convo,
                config: .init(),
                model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
                nudges: [],
                messages: [],
                cachedAgentsMd: nil))
        XCTAssertTrue(prompt.contains("Prefer edit_file") || prompt.contains("Project rules")
                      || prompt.contains("AGENTS"), prompt.prefix(500).description)
    }

    func testComposerSkipsEmptySystemPromptOverride() {
        var convo = Conversation(title: "t")
        convo.systemPromptOverride = "   \n  "
        let (prompt, _) = AgentSystemPromptComposer.compose(
            .init(
                conversation: convo,
                config: .init(),
                model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
                nudges: [],
                messages: []))
        // Should still have baseline harness text, not only whitespace override noise
        XCTAssertTrue(prompt.contains("local-first") || prompt.contains("edit_file")
                      || prompt.count > 50, prompt.prefix(200).description)
    }

    func testComposerInjectsCLAUDEmdViaFallback() throws {
        let root = try tempRoot("rules-composer-claude")
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Claude\nCLAUDE_COMPOSER_MARKER\n"
            .write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        var convo = Conversation(title: "t")
        convo.projectRoot = root
        let (prompt, _) = AgentSystemPromptComposer.compose(
            .init(
                conversation: convo,
                config: .init(),
                model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
                nudges: [],
                messages: [],
                cachedAgentsMd: nil))
        XCTAssertTrue(prompt.contains("CLAUDE_COMPOSER_MARKER"), prompt.prefix(600).description)
    }

    /// C2: home rules dirs load with includeHomeRules (hermetic fake home via FileManager is hard;
    /// exercise the flag path under a temp project with an empty includeHome=false control).
    func testIncludeHomeRulesFlagDoesNotBreakProjectLoad() throws {
        let root = try tempRoot("rules-home-flag")
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Project\nHOME_FLAG_PROJECT_MARKER\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let withHome = ProjectRules.load(
            projectRoot: root, cwd: root, includeHomeRules: true)
        let noHome = ProjectRules.load(
            projectRoot: root, cwd: root, includeHomeRules: false)
        XCTAssertTrue(withHome.injectedText.contains("HOME_FLAG_PROJECT_MARKER"))
        XCTAssertTrue(noHome.injectedText.contains("HOME_FLAG_PROJECT_MARKER"))
        // With home may load more files; without must still have project AGENTS.
        XCTAssertGreaterThanOrEqual(withHome.files.count, noHome.files.count)
    }

    /// Live-path regression: root AGENTS must NOT shadow nested AGENTS when
    /// cache is preloaded via ProjectRules (AgentLoop Wave B S8 shape).
    func testLivePathCacheIncludesNestedAgentsWhenRootExists() throws {
        let root = try tempRoot("rules-live")
        let child = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Root AGENTS\nUse tabs.\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# Nested AGENTS\nUse spaces in pkg.\n"
            .write(to: child.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        // Production preload shape (AgentLoop)
        let snap = ProjectRules.load(projectRoot: root, cwd: child)
        XCTAssertFalse(snap.injectedText.isEmpty)
        XCTAssertTrue(snap.injectedText.contains("Use tabs"))
        XCTAssertTrue(snap.injectedText.contains("Use spaces in pkg"),
                      "nested AGENTS must load even when root AGENTS exists")

        var convo = Conversation(title: "t")
        convo.projectRoot = root
        // worktreeRootURL is get-only; cwd via projectRoot
        // was: child worktree
        let (prompt, _) = AgentSystemPromptComposer.compose(
            .init(
                conversation: convo,
                config: .init(),
                model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
                nudges: [],
                messages: [],
                cachedAgentsMd: snap.injectedText))
        XCTAssertTrue(prompt.contains("Use spaces in pkg"), prompt.prefix(800).description)
        XCTAssertTrue(prompt.contains("Use tabs"), prompt.prefix(800).description)
    }

    func testDiscoversCLAUDEmd() throws {
        let root = try tempRoot("rules-claude")
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Claude instructions\nPrefer TypeScript.\n"
            .write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: root)
        XCTAssertEqual(snap.files.count, 1)
        XCTAssertTrue(snap.injectedText.contains("Prefer TypeScript"))
        XCTAssertTrue(snap.injectedText.contains("CLAUDE.md") || snap.files[0].path.hasSuffix("CLAUDE.md"))
    }

    func testDiscoversClaudeLocalAndNestedClaudeDir() throws {
        let root = try tempRoot("rules-claude-nested")
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Local only\nDo not commit secrets.\n"
            .write(to: root.appendingPathComponent("CLAUDE.local.md"), atomically: true, encoding: .utf8)
        let claudeDir = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "# Project Claude\nUse pnpm.\n"
            .write(to: claudeDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: root)
        XCTAssertTrue(snap.injectedText.contains("Do not commit secrets"))
        XCTAssertTrue(snap.injectedText.contains("Use pnpm"))
    }

    func testDiscoversClaudeAndCursorRulesDirs() throws {
        let root = try tempRoot("rules-dirs")
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeRules = root.appendingPathComponent(".claude/rules", isDirectory: true)
        let cursorRules = root.appendingPathComponent(".cursor/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorRules, withIntermediateDirectories: true)

        try """
        ---
        description: style
        ---
        # Claude rule
        Use 2-space indent.
        """.write(to: claudeRules.appendingPathComponent("style.md"), atomically: true, encoding: .utf8)

        try "# Cursor rule\nPrefer functional components.\n"
            .write(to: cursorRules.appendingPathComponent("react.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: root)
        XCTAssertTrue(snap.injectedText.contains("Use 2-space indent"),
                      "frontmatter-stripped body expected: \(snap.injectedText.prefix(400))")
        XCTAssertFalse(snap.injectedText.contains("description: style"),
                       "YAML frontmatter should be stripped from rules dirs")
        XCTAssertTrue(snap.injectedText.contains("Prefer functional components"))
    }

    func testCursorrulesFile() throws {
        let root = try tempRoot("rules-cursorrules")
        defer { try? FileManager.default.removeItem(at: root) }

        try "Always run tests after edits.\n"
            .write(to: root.appendingPathComponent(".cursorrules"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: root)
        XCTAssertTrue(snap.injectedText.contains("Always run tests after edits"))
    }

    func testLoadAgentsMdDelegatesToHierarchy() throws {
        let root = try tempRoot("rules-loadAgents")
        let child = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Root\nroot-marker-xyz\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# Child\nchild-marker-xyz\n"
            .write(to: child.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let rootOnly = ChatLoop.loadAgentsMd(projectRoot: root)
        XCTAssertNotNil(rootOnly)
        XCTAssertTrue(rootOnly!.contains("root-marker-xyz"))
        // Without cwd=child, nested file is not in chain (cwd defaults to root)
        XCTAssertFalse(rootOnly!.contains("child-marker-xyz"))

        let withCwd = ChatLoop.loadAgentsMd(projectRoot: root, cwd: child)
        XCTAssertNotNil(withCwd)
        XCTAssertTrue(withCwd!.contains("root-marker-xyz"))
        XCTAssertTrue(withCwd!.contains("child-marker-xyz"))
    }

    func testStripYAMLFrontmatter() {
        let with = """
        ---
        paths:
          - src/**
        ---
        Body text
        """
        let stripped = ProjectRules.stripYAMLFrontmatter(with)
        XCTAssertTrue(stripped.contains("Body text"))
        XCTAssertFalse(stripped.contains("paths:"))

        let plain = "Just content\n"
        XCTAssertEqual(ProjectRules.stripYAMLFrontmatter(plain), plain)
    }

    func testBothAgentsAndClaudeInSameDir() throws {
        let root = try tempRoot("rules-both")
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Agents\nagents-only-marker\n"
            .write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# Claude\nclaude-only-marker\n"
            .write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let snap = ProjectRules.load(projectRoot: root, cwd: root)
        // Both should load (multi-convention, not first-match-only)
        XCTAssertTrue(snap.injectedText.contains("agents-only-marker"))
        XCTAssertTrue(snap.injectedText.contains("claude-only-marker"))
        XCTAssertGreaterThanOrEqual(snap.files.count, 2)
    }
}

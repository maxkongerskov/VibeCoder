//
//  ParityPromptComposerTests.swift
//
//  ZCode-parity prompt composer: git-status snapshot injection and
//  the four verbatim behavior sections.
//

import XCTest
@testable import AgentCore

final class ParityPromptComposerTests: XCTestCase {

    // MARK: - Composer: git snapshot

    func testComposerIncludesProvidedGitSnapshot() {
        let fake = """
            gitStatus: FAKE_PARITY_SNAPSHOT
            Current branch: feature/parity
            """
        let (prompt, _) = AgentSystemPromptComposer.compose(makeInput(gitStatusSnapshot: fake))
        XCTAssertTrue(prompt.contains("FAKE_PARITY_SNAPSHOT"), prompt)
        XCTAssertTrue(prompt.contains("Current branch: feature/parity"), prompt)
    }

    func testComposerOmitsEmptyGitSnapshot() {
        let (prompt, _) = AgentSystemPromptComposer.compose(makeInput(gitStatusSnapshot: ""))
        XCTAssertFalse(prompt.contains("gitStatus:"), prompt)
        XCTAssertFalse(prompt.contains("FAKE_PARITY_SNAPSHOT"), prompt)
    }

    func testComposerOmitsWhitespaceOnlyGitSnapshot() {
        let (prompt, _) = AgentSystemPromptComposer.compose(makeInput(gitStatusSnapshot: "  \n\t  "))
        XCTAssertFalse(prompt.contains("gitStatus:"), prompt)
    }

    // MARK: - Composer: behavior sections

    func testComposerIncludesFourBehaviorSectionHeadings() {
        let (prompt, _) = AgentSystemPromptComposer.compose(makeInput(gitStatusSnapshot: ""))
        for heading in ZCodeBehaviorPrompt.sectionHeadings {
            XCTAssertTrue(prompt.contains(heading), "missing heading \(heading)")
        }
        XCTAssertTrue(prompt.contains("final text message of your turn"))
        XCTAssertTrue(prompt.contains("Lead with the outcome"))
        XCTAssertTrue(prompt.contains("You are operating autonomously"))
        XCTAssertTrue(prompt.contains("don't need to wrap up early"))
        XCTAssertTrue(prompt.contains("Before ending your turn, check your last paragraph"))
    }

    func testChatModeOmitsBehaviorAndSnapshot() {
        let fake = "gitStatus: FAKE_PARITY_SNAPSHOT"
        let (prompt, tokens) = AgentSystemPromptComposer.compose(
            makeInput(gitStatusSnapshot: fake, rawMode: true))
        XCTAssertEqual(prompt, "")
        XCTAssertEqual(tokens, 0)
        for heading in ZCodeBehaviorPrompt.sectionHeadings {
            XCTAssertFalse(prompt.contains(heading))
        }
    }

    // MARK: - GitStatusSnapshot format / parse

    func testFormatSnapshotMatchesZCodeShape() {
        let text = GitStatusSnapshot.formatSnapshot(
            currentBranch: "feature/x",
            mainBranch: "main",
            gitUser: "Ada",
            porcelain: " M Sources/Foo.swift\n?? new.txt\n",
            recentCommits: "abc1234 hello\ndef5678 world\n")
        XCTAssertTrue(text.contains(GitStatusSnapshot.preamble))
        XCTAssertTrue(text.contains("will not update"))
        XCTAssertTrue(text.contains("Current branch: feature/x"))
        XCTAssertTrue(text.contains("Main branch (you will usually use this for PRs): main"))
        XCTAssertTrue(text.contains("Git user: Ada"))
        XCTAssertTrue(text.contains("Status:"))
        XCTAssertTrue(text.contains(" M Sources/Foo.swift"))
        XCTAssertTrue(text.contains("?? new.txt"))
        XCTAssertTrue(text.contains("Recent commits:"))
        XCTAssertTrue(text.contains("abc1234 hello"))
    }

    func testFormatSnapshotOmitsOptionalFields() {
        let text = GitStatusSnapshot.formatSnapshot(
            currentBranch: "main",
            mainBranch: nil,
            gitUser: nil,
            porcelain: "",
            recentCommits: "")
        XCTAssertTrue(text.contains("Current branch: main"))
        XCTAssertFalse(text.contains("Main branch"))
        XCTAssertFalse(text.contains("Git user:"))
        XCTAssertTrue(text.contains("Status:"))
        XCTAssertFalse(text.contains("Recent commits:"))
    }

    func testCapPorcelainLines() {
        let many = (0..<50).map { " M file\($0).swift" }.joined(separator: "\n")
        let capped = GitStatusSnapshot.capLines(many, limit: 40)
        XCTAssertEqual(capped.split(whereSeparator: \.isNewline).count, 40)
        let formatted = GitStatusSnapshot.formatSnapshot(
            currentBranch: "main",
            mainBranch: "main",
            gitUser: "A",
            porcelain: many,
            recentCommits: "abc hi",
            porcelainLineCap: 40)
        XCTAssertTrue(formatted.contains(" M file0.swift"))
        XCTAssertTrue(formatted.contains(" M file39.swift"))
        XCTAssertFalse(formatted.contains(" M file40.swift"))
    }

    func testParseOriginHead() {
        XCTAssertEqual(GitStatusSnapshot.parseOriginHead("refs/remotes/origin/main\n"), "main")
        XCTAssertEqual(GitStatusSnapshot.parseOriginHead("origin/master"), "master")
        XCTAssertEqual(GitStatusSnapshot.parseOriginHead("develop"), "develop")
        XCTAssertNil(GitStatusSnapshot.parseOriginHead(""))
        XCTAssertNil(GitStatusSnapshot.parseOriginHead("refs/remotes/origin/HEAD"))
    }

    func testIsInsideWorkTree() {
        XCTAssertTrue(GitStatusSnapshot.isInsideWorkTree(stdout: "true\n", exitCode: 0))
        XCTAssertFalse(GitStatusSnapshot.isInsideWorkTree(stdout: "true", exitCode: 128))
        XCTAssertFalse(GitStatusSnapshot.isInsideWorkTree(stdout: "", exitCode: 0))
        XCTAssertFalse(GitStatusSnapshot.isInsideWorkTree(stdout: "false\n", exitCode: 0))
    }

    // MARK: - GitStatusSnapshot runner

    func testCaptureReturnsNilWhenNotARepo() {
        let runner: GitStatusSnapshot.Runner = { _, _, _ in
            GitStatusSnapshot.CommandOutput(stdout: "", exitCode: 128)
        }
        let snap = GitStatusSnapshot.capture(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner)
        XCTAssertNil(snap)
    }

    func testCaptureFormatsRunnerOutput() {
        let runner: GitStatusSnapshot.Runner = { args, _, _ in
            if args == ["rev-parse", "--is-inside-work-tree"] {
                return .init(stdout: "true\n", exitCode: 0)
            }
            if args == ["rev-parse", "--abbrev-ref", "HEAD"] {
                return .init(stdout: "feature/snap\n", exitCode: 0)
            }
            if args == ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"] {
                return .init(stdout: "refs/remotes/origin/main\n", exitCode: 0)
            }
            if args == ["config", "user.name"] {
                return .init(stdout: "Ada Lovelace\n", exitCode: 0)
            }
            if args == ["status", "--porcelain"] {
                return .init(stdout: " M Sources/Bar.swift\n?? scratch.md\n", exitCode: 0)
            }
            if args == ["log", "-5", "--oneline"] {
                return .init(stdout: "aaa1111 first\nbbb2222 second\n", exitCode: 0)
            }
            return .init(stdout: "", exitCode: 0)
        }
        let snap = GitStatusSnapshot.capture(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner)
        XCTAssertNotNil(snap)
        let text = snap ?? ""
        XCTAssertTrue(text.contains("Current branch: feature/snap"), text)
        XCTAssertTrue(text.contains("Main branch (you will usually use this for PRs): main"), text)
        XCTAssertTrue(text.contains("Git user: Ada Lovelace"), text)
        XCTAssertTrue(text.contains(" M Sources/Bar.swift"), text)
        XCTAssertTrue(text.contains("aaa1111 first"), text)
        XCTAssertTrue(text.contains("will not update"), text)
    }

    func testCaptureFallsBackToMasterWhenMainMissing() {
        let runner: GitStatusSnapshot.Runner = { args, _, _ in
            if args == ["rev-parse", "--is-inside-work-tree"] {
                return .init(stdout: "true\n", exitCode: 0)
            }
            if args == ["rev-parse", "--abbrev-ref", "HEAD"] {
                return .init(stdout: "hotfix\n", exitCode: 0)
            }
            if args == ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"] {
                return .init(stdout: "", exitCode: 1)
            }
            if args == ["rev-parse", "--verify", "--quiet", "refs/heads/main"] {
                return .init(stdout: "", exitCode: 1)
            }
            if args == ["rev-parse", "--verify", "--quiet", "refs/heads/master"] {
                return .init(stdout: "abc\n", exitCode: 0)
            }
            if args == ["config", "user.name"] {
                return .init(stdout: "Pat\n", exitCode: 0)
            }
            if args == ["status", "--porcelain"] {
                return .init(stdout: "", exitCode: 0)
            }
            if args == ["log", "-5", "--oneline"] {
                return .init(stdout: "ccc3333 tip\n", exitCode: 0)
            }
            return .init(stdout: "", exitCode: 1)
        }
        let snap = GitStatusSnapshot.capture(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner)
        XCTAssertTrue(snap?.contains("Main branch (you will usually use this for PRs): master") == true, snap ?? "nil")
    }

    // MARK: - Helpers

    private func makeInput(
        gitStatusSnapshot: String?,
        rawMode: Bool = false
    ) -> AgentSystemPromptComposer.Input {
        AgentSystemPromptComposer.Input(
            conversation: Conversation(title: "parity-prompt"),
            config: .init(rawMode: rawMode),
            model: ModelDescriptor(id: "m", displayName: "m", backend: .lmStudio),
            nudges: [],
            messages: [],
            gitStatusSnapshot: gitStatusSnapshot)
    }
}

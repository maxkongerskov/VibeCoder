//
//  SafeBashTests.swift
//  Wave B S10b — SafeBash v2: Grok-class dangerous prefixes, RO builds
//  tightened, quote-aware segments.
//

import XCTest
@testable import AgentCore

final class SafeBashTests: XCTestCase {

    // MARK: - Word-boundary dangerous list (Grok-class)

    func testBareRmIsDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("rm important.file"))
        XCTAssertTrue(SafeBash.isDangerous("rm -rf /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("rm -fr build"))
    }

    func testRmdirIsNotBareRm() {
        // Word boundary: rmdir must not match the `rm` prefix.
        XCTAssertFalse(SafeBash.matchesCommandPrefix("rmdir /tmp/x", prefix: "rm"))
        // rmdir alone is not on the Grok dangerous prefix list.
        XCTAssertFalse(SafeBash.isDangerous("rmdir empty-dir"))
    }

    func testGitPushIsDangerousEvenWithoutForce() {
        XCTAssertTrue(SafeBash.isDangerous("git push origin main"))
        XCTAssertTrue(SafeBash.isDangerous("git push --force origin main"))
        XCTAssertTrue(SafeBash.isDangerous("git push -f"))
        XCTAssertFalse(SafeBash.isDangerous("git status"))
        XCTAssertFalse(SafeBash.isDangerous("git log --oneline"))
    }

    func testChmodChownKillAreDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("chmod 000 secret"))
        XCTAssertTrue(SafeBash.isDangerous("chmod 777 /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("chown root:wheel file"))
        XCTAssertTrue(SafeBash.isDangerous("chgrp staff file"))
        XCTAssertTrue(SafeBash.isDangerous("kill -9 1234"))
        XCTAssertTrue(SafeBash.isDangerous("killall Finder"))
        XCTAssertTrue(SafeBash.isDangerous("pkill -f nginx"))
    }

    func testDangerousInChainSegment() {
        XCTAssertTrue(SafeBash.isDangerous("ls && rm -rf /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("git status; git push origin main"))
        XCTAssertFalse(SafeBash.isDangerous("git status && git diff"))
    }

    func testWrappedDangerousStillDetected() {
        XCTAssertTrue(SafeBash.isDangerous("env rm -rf /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("nohup rm important.file"))
        XCTAssertTrue(SafeBash.isDangerous("env FOO=1 rm file.txt"))
    }

    func testSudoStillDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("sudo ls"))
        XCTAssertTrue(SafeBash.isDangerous("sudo rm -rf /"))
    }

    // MARK: - RO classifier (builds not RO)

    func testInspectShellIsReadOnly() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("ls -la"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("cat README.md"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("echo hello"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("rg TODO Sources"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git status && git diff"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git log -1"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("cargo check"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("cargo clippy"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("swift package describe"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift package update"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift package add-dependency foo"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift package reset"))
    }

    func testBuildsAreNotReadOnly() {
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift build"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("cargo build"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("cargo test"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("swift test"))
    }

    func testMutatingShellNotReadOnly() {
        XCTAssertFalse(SafeBash.isReadOnlyCommand("ls && rm -rf /tmp/x"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("touch /tmp/x"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git push origin main"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git commit -m msg"))
    }

    func testFindDeleteAndRgPreNotReadOnly() {
        XCTAssertFalse(SafeBash.isReadOnlyCommand("find . -delete"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("rg --pre cat pattern"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("find . -name '*.swift'"))
    }

    func testFindExecAndOkNotReadOnly() {
        XCTAssertFalse(SafeBash.isReadOnlyCommand("find . -exec rm {} +"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("find . -execdir cat {} \\;"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("find . -ok rm {} \\;"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("find . -fprint /tmp/out.txt"))
    }

    func testGitRemoteAndTagMutatingNotReadOnly() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git remote"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git remote -v"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git remote show origin"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git remote add origin https://example.com/r.git"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git remote remove origin"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git remote set-url origin https://evil.example/r.git"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git tag"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git tag -l"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git tag v1.0.0"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git tag -d v1.0.0"))
    }

    func testSortOutputAndTeeNotReadOnly() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("sort file.txt"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("sort -o out.txt file.txt"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("tee out.txt"))
    }

    func testWritableRootsWorktreeExcludesProject() {
        let project = URL(fileURLWithPath: "/tmp/proj-main")
        let worktree = URL(fileURLWithPath: "/tmp/proj-main-agentcore-abc")
        let roots = SafeBash.writableRoots(
            workingDirectory: worktree,
            projectRoot: project,
            worktreeRoot: worktree)
        XCTAssertEqual(roots, [worktree.path])
        XCTAssertFalse(roots.contains(project.path))
    }

    func testWritableRootsWithoutWorktreeIncludesProject() {
        let project = URL(fileURLWithPath: "/tmp/proj-only")
        let roots = SafeBash.writableRoots(
            workingDirectory: project,
            projectRoot: project,
            worktreeRoot: nil)
        XCTAssertTrue(roots.contains(project.path))
    }

    func testGitStashMutatingNotReadOnly() {
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git stash push -m wip"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git stash drop"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git stash")) // bare = push
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git stash list"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git stash show"))
    }

    func testGitBranchMutatingNotReadOnly() {
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git branch"))
        XCTAssertTrue(SafeBash.isReadOnlyCommand("git branch -v"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git branch -D main"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("git branch new-feature"))
    }

    // MARK: - Quote-aware segments / tokenize

    func testQuoteAwareSegments() {
        let segs = SafeBash.segments(of: #"echo "a && b" && ls"#)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0], #"echo "a && b""#)
        XCTAssertEqual(segs[1], "ls")
        XCTAssertTrue(SafeBash.isReadOnlyCommand(#"echo "a && b" && ls"#))
    }

    func testQuoteAwarePipeNotSplitInsideQuotes() {
        let segs = SafeBash.segments(of: #"echo "foo|bar" | wc -l"#)
        XCTAssertEqual(segs.count, 2)
        XCTAssertTrue(segs[0].contains("foo|bar"))
        XCTAssertEqual(segs[1], "wc -l")
    }

    func testTokenizeStripsQuotes() {
        let tokens = SafeBash.tokenize(#"echo "hello world""#)
        XCTAssertEqual(tokens, ["echo", "hello world"])
    }

    func testMatchesCommandPrefixBoundaries() {
        XCTAssertTrue(SafeBash.matchesCommandPrefix("rm", prefix: "rm"))
        XCTAssertTrue(SafeBash.matchesCommandPrefix("rm -rf /", prefix: "rm"))
        XCTAssertFalse(SafeBash.matchesCommandPrefix("rmdir", prefix: "rm"))
        XCTAssertTrue(SafeBash.matchesCommandPrefix("git push origin", prefix: "git push"))
        XCTAssertFalse(SafeBash.matchesCommandPrefix("git status", prefix: "git push"))
        XCTAssertFalse(SafeBash.matchesCommandPrefix("git pushx", prefix: "git push"))
        XCTAssertFalse(SafeBash.matchesCommandPrefix("gitleaks", prefix: "git"))
    }

    func testPeelWrappers() {
        XCTAssertEqual(SafeBash.peelWrappers(["env", "rm", "-rf", "x"]), ["rm", "-rf", "x"])
        XCTAssertEqual(SafeBash.peelWrappers(["env", "FOO=1", "ls"]), ["ls"])
        XCTAssertEqual(SafeBash.peelWrappers(["env"]), ["env"]) // bare env kept
        XCTAssertEqual(SafeBash.peelWrappers(["nohup", "git", "status"]), ["git", "status"])
    }

    // MARK: - Wave C bug-hunt

    func testTimeoutWrapperDoesNotHideRm() {
        XCTAssertTrue(SafeBash.isDangerous("timeout 5 rm important.file"))
        XCTAssertTrue(SafeBash.isDangerous("timeout 10s rm -rf /tmp/x"))
        XCTAssertEqual(
            SafeBash.peelWrappers(["timeout", "5", "rm", "-rf", "x"]),
            ["rm", "-rf", "x"])
    }

    func testBashCNestedDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("bash -c 'rm -rf /tmp/x'"))
        XCTAssertTrue(SafeBash.isDangerous(#"sh -c "rm file.txt""#))
        XCTAssertTrue(SafeBash.isDangerous("zsh -lc 'git push origin main'"))
        // Nested inspect script is not flagged as dangerous (not RO either).
        XCTAssertFalse(SafeBash.isDangerous("bash -c 'ls -la'"))
        XCTAssertFalse(SafeBash.isReadOnlyCommand("bash -c 'ls -la'"))
    }

    // MARK: - Wave C2

    func testXargsPeelsToRm() {
        XCTAssertTrue(SafeBash.isDangerous("xargs rm -rf"))
        XCTAssertEqual(
            SafeBash.peelWrappers(["xargs", "-n", "1", "rm", "-f", "x"]),
            ["rm", "-f", "x"])
    }

    func testPythonCDangerousPayload() {
        XCTAssertTrue(SafeBash.isDangerous(#"python3 -c "import os; os.system('rm -rf /tmp/x')""#))
        XCTAssertTrue(SafeBash.isDangerous(#"python -c "import shutil; shutil.rmtree('/tmp/x')""#))
        XCTAssertFalse(SafeBash.isReadOnlyCommand(#"python3 -c "print(1)""#))
    }

    func testEvalAndSourceDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("eval rm -rf /tmp/x"))
        XCTAssertTrue(SafeBash.isDangerous("source ./evil.sh"))
    }

    func testDdOfDangerous() {
        XCTAssertTrue(SafeBash.isDangerous("dd of=/dev/disk0 if=/tmp/x"))
    }
}

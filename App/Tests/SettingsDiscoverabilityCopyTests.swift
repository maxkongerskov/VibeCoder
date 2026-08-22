//
//  SettingsDiscoverabilityCopyTests.swift
//  Polish P2 — honest defaults visible in Settings copy.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class SettingsDiscoverabilityCopyTests: XCTestCase {

    func testAgentToolsCopyStatesDefaultOff() {
        let off = SettingsDiscoverabilityCopy.agentToolsStatus(enabled: false)
        XCTAssertTrue(off.lowercased().contains("default") || off.lowercased().contains("off"))
        XCTAssertTrue(off.lowercased().contains("proxy") || off.lowercased().contains("completions") || off.lowercased().contains("tools"))
        let on = SettingsDiscoverabilityCopy.agentToolsStatus(enabled: true)
        XCTAssertTrue(on.lowercased().contains("on"))
        XCTAssertTrue(on.lowercased().contains("loop") || on.lowercased().contains("capped") || on.lowercased().contains("tool"))
        XCTAssertFalse(on.lowercased().contains("full agent loop inside xcode"))
    }

    func testSeatbeltAutoIsDefaultWording() {
        let auto = SettingsDiscoverabilityCopy.seatbeltCurrent(.auto)
        XCTAssertTrue(auto.lowercased().contains("default") || auto.lowercased().contains("auto"))
        XCTAssertTrue(SettingsDiscoverabilityCopy.seatbeltIntro.lowercased().contains("auto"))
    }

    func testGrantsCopyNotConfusedWithSeatbelt() {
        let intro = SettingsDiscoverabilityCopy.grantsIntro.lowercased()
        XCTAssertTrue(intro.contains("always") || intro.contains("never") || intro.contains("grant"))
        XCTAssertTrue(intro.contains("seatbelt") || intro.contains("permission") || intro.contains("safe mode"))
    }

    func testLocalAPIIntroDoesNotClaimAgentLoopInXcode() {
        let s = SettingsDiscoverabilityCopy.localAPIIntro.lowercased()
        XCTAssertTrue(s.contains("proxy") || s.contains("completions") || s.contains("loopback"))
        XCTAssertFalse(s.contains("cursor-level"))
        XCTAssertFalse(s.contains("full agentic"))
    }

    func testSettingsSearchHitsConnectionForLocalAPIOllamaXcode() {
        func hits(_ q: String) -> Bool {
            SettingsDiscoverabilityCopy.tabMatchesSearch(
                label: "Connection",
                subtitle: "Local servers & APIs",
                rawValue: "connection",
                query: q
            )
        }
        XCTAssertTrue(hits("local api"))
        XCTAssertTrue(hits("ollama"))
        XCTAssertTrue(hits("xcode"))
        XCTAssertTrue(hits("unsloth"))
        XCTAssertFalse(
            SettingsDiscoverabilityCopy.tabMatchesSearch(
                label: "Agent",
                subtitle: "Instructions & behavior",
                rawValue: "agent",
                query: "ollama"
            )
        )
    }

    func testEmptyChatCopyListsUnslothOnNoBackend() {
        let title = EmptyChatCopy.title(availableModelsEmpty: true, hasSelectedModel: false)
        let sub = EmptyChatCopy.subtitle(availableModelsEmpty: true, hasSelectedModel: false)
        XCTAssertEqual(title, "Connect a model server")
        XCTAssertTrue(sub.contains("Unsloth"))
        XCTAssertTrue(sub.contains("LM Studio"))
        XCTAssertTrue(sub.contains("Ollama"))
        XCTAssertTrue(sub.contains("oMLX"))
        XCTAssertTrue(sub.contains("EXO"))
        XCTAssertFalse(sub.localizedCaseInsensitiveContains("custom"))
        XCTAssertEqual(
            EmptyChatCopy.title(availableModelsEmpty: false, hasSelectedModel: false),
            "Pick a model to start"
        )
        XCTAssertEqual(
            EmptyChatCopy.title(availableModelsEmpty: false, hasSelectedModel: true),
            "What are we working on?"
        )
    }

    func testComposerSendDisabledUntilModelUnlessRunning() {
        XCTAssertFalse(ComposerSendGate.sendEnabled(hasDraft: true, hasModel: false, isRunning: false))
        XCTAssertTrue(ComposerSendGate.sendEnabled(hasDraft: true, hasModel: true, isRunning: false))
        XCTAssertTrue(ComposerSendGate.sendEnabled(hasDraft: true, hasModel: false, isRunning: true))
        XCTAssertFalse(ComposerSendGate.sendEnabled(hasDraft: false, hasModel: true, isRunning: false))
    }

    /// F3: loopback "Detected on this Mac" is not a selected model.
    func testSendDisabledWhenLoopbackDetectedButNoModelSelected() {
        let ollama = LoopbackDetectTarget.defaults.first { $0.backend == .ollama }!
        let hits = [LoopbackDetectHit(target: ollama, verdict: .modelsReady)]
        XCTAssertEqual(hits.first?.verdict, .modelsReady)
        XCTAssertFalse(
            ComposerSendGate.sendEnabled(hasDraft: true, hasModel: false, isRunning: false),
            "detected servers must not enable Send")
        XCTAssertEqual(
            EmptyChatCopy.title(availableModelsEmpty: false, hasSelectedModel: false),
            "Pick a model to start")
        XCTAssertTrue(
            EmptyChatCopy.subtitle(availableModelsEmpty: false, hasSelectedModel: false)
                .localizedCaseInsensitiveContains("model chip"))
    }

    func testWorktreeBindCopySurfacesSkippedNotGitOnly() {
        let notice = WorktreeBindCopy.notice(for: .skippedNotGit(path: "/tmp/plain-folder"))
        XCTAssertEqual(
            notice,
            WorktreeError.notAGitRepo("/tmp/plain-folder").errorDescription)
        XCTAssertTrue(notice?.localizedCaseInsensitiveContains("git") == true)
        XCTAssertNil(WorktreeBindCopy.notice(for: .unbound))
        XCTAssertNil(WorktreeBindCopy.notice(for: .skippedOptOut))
        XCTAssertNil(WorktreeBindCopy.notice(for: .alreadyIsolated))
        XCTAssertEqual(
            WorktreeBindCopy.alertTitle(forMessage: WorktreeError.notAGitRepo("/tmp/x").errorDescription),
            "Worktree")
        XCTAssertEqual(
            WorktreeBindCopy.alertTitle(forMessage: "Merge failed: conflict"),
            "Worktree error")
    }

    func testWorktreeChromeCopyIsHonest() {
        XCTAssertEqual(WorktreeChromeCopy.isolate, "Isolate work in git worktree")
        XCTAssertEqual(WorktreeChromeCopy.review, "Review worktree…")
        XCTAssertEqual(WorktreeChromeCopy.editMain, "Edit main tree…")
        XCTAssertEqual(
            WorktreeChromeCopy.isolatedActions(),
            [.review, .editMain],
            "Edit main tree is a distinct action from Review (opt-out, not discard)"
        )
    }

    func testComposerTabKeyShiftTabCyclesModeAndDoesNotStealSlashTab() {
        XCTAssertEqual(
            ComposerTabKey.action(shift: true, slashMenuVisible: false),
            .cycleMode
        )
        XCTAssertEqual(
            ComposerTabKey.action(shift: true, slashMenuVisible: true),
            .cycleMode,
            "⇧Tab still cycles when the slash menu is open"
        )
        XCTAssertEqual(
            ComposerTabKey.action(shift: false, slashMenuVisible: true),
            .acceptSlash,
            "plain Tab is slash-accept, not mode cycle"
        )
        XCTAssertEqual(
            ComposerTabKey.action(shift: false, slashMenuVisible: false),
            .ignore,
            "plain Tab without slash menu must not steal focus advance"
        )
    }

    func testCloudBotCopyIsLabeledCloudNotLocalFirst() {
        let intro = CloudBotCopy.intro.lowercased()
        XCTAssertTrue(intro.contains("cloud"))
        XCTAssertTrue(intro.contains("leave this mac"))
        XCTAssertTrue(intro.contains("not a local-inference"))
        XCTAssertTrue(intro.contains("not a byo http"))
        XCTAssertFalse(intro.contains("nothing leaves"))

        let honesty = CloudBotCopy.honesty.lowercased()
        XCTAssertTrue(honesty.contains("not local-first"))
        XCTAssertTrue(honesty.contains("not a storefront"))
        XCTAssertFalse(honesty.contains("nothing leaves"))

        let privacy = CloudBotCopy.privacyBlurb.lowercased()
        XCTAssertTrue(privacy.contains("cloudbot"))
        XCTAssertTrue(privacy.contains("leave this mac"))
        XCTAssertFalse(privacy.contains("nothing leaves"))
        XCTAssertFalse(privacy.hasPrefix("local-first"))

        XCTAssertEqual(CloudBotCopy.cloudLabel, "Cloud")
        XCTAssertFalse(AppSettings().cloudBotsEnabled)
        XCTAssertTrue(CloudBotCopy.status(enabled: false).lowercased().contains("default"))
        XCTAssertTrue(CloudBotCopy.status(enabled: true).lowercased().contains("cloud"))
        XCTAssertTrue(CloudBotCopy.status(enabled: true).lowercased().contains("leave"))
    }

    func testPrivacySearchHitsCloudBots() {
        func hits(_ q: String) -> Bool {
            SettingsDiscoverabilityCopy.tabMatchesSearch(
                label: "Privacy",
                subtitle: "Data & backup",
                rawValue: "privacy",
                query: q
            )
        }
        XCTAssertTrue(hits("cloudbot"))
        XCTAssertTrue(hits("cloud"))
        XCTAssertFalse(
            SettingsDiscoverabilityCopy.tabMatchesSearch(
                label: "Connection",
                subtitle: "Local servers & APIs",
                rawValue: "connection",
                query: "cloudbot"
            )
        )
    }

    /// Chat-header chip + help. Sable's copy test covers Settings intro/honesty/privacy.
    func testCloudBotChipCopyIsCloudNotOnDevice() {
        XCTAssertEqual(CloudBotCopy.cloudLabel, "Cloud")
        XCTAssertNotEqual(CloudBotCopy.cloudLabel, "Local")

        let help = CloudBotCopy.chipHelp.lowercased()
        XCTAssertTrue(help.contains("cloud"))
        XCTAssertTrue(help.contains("leave"))
        XCTAssertTrue(help.contains("this mac"))
        XCTAssertTrue(help.contains("not local"))
        XCTAssertFalse(help.contains("on-device"))
        XCTAssertFalse(help.contains("on device"))
        XCTAssertFalse(help.contains("nothing leaves"))
        XCTAssertFalse(help.contains("local-first"))

        let a11y = CloudBotCopy.chipAccessibility.lowercased()
        XCTAssertTrue(a11y.contains("cloud"))
        XCTAssertTrue(a11y.contains("leave"))
        XCTAssertTrue(a11y.contains("this mac"))
        XCTAssertFalse(a11y.contains("on-device"))
        XCTAssertFalse(a11y.contains("on device"))
        XCTAssertFalse(a11y.contains("nothing leaves"))
        XCTAssertFalse(a11y.contains("local-first"))
        XCTAssertFalse(a11y.contains("byo http"))
    }

    func testCloudBotToggleTitleIsOptIn() {
        let title = CloudBotCopy.toggleTitle.lowercased()
        XCTAssertTrue(title.contains("opt-in"))
        XCTAssertTrue(title.contains("cloudbot"))
        XCTAssertEqual(CloudBotCopy.settingsTitle, "CloudBots")
    }

    /// Sweep every Settings/chrome string so CloudBots cannot read as on-device.
    func testCloudBotVisibleCopyNeverClaimsOnDeviceOrNothingLeavesTheMac() {
        let strings: [(String, String)] = [
            ("settingsTitle", CloudBotCopy.settingsTitle),
            ("cloudLabel", CloudBotCopy.cloudLabel),
            ("toggleTitle", CloudBotCopy.toggleTitle),
            ("intro", CloudBotCopy.intro),
            ("honesty", CloudBotCopy.honesty),
            ("privacyBlurb", CloudBotCopy.privacyBlurb),
            ("chipHelp", CloudBotCopy.chipHelp),
            ("chipAccessibility", CloudBotCopy.chipAccessibility),
            ("statusOff", CloudBotCopy.status(enabled: false)),
            ("statusOn", CloudBotCopy.status(enabled: true)),
        ]
        for (name, raw) in strings {
            let lower = raw.lowercased()
            XCTAssertFalse(lower.contains("on-device"), "\(name) claims on-device: \(raw)")
            XCTAssertFalse(lower.contains("on device"), "\(name) claims on device: \(raw)")
            XCTAssertFalse(lower.contains("nothing leaves"), "\(name) claims nothing leaves: \(raw)")
            if lower.contains("local-first") {
                XCTAssertTrue(
                    lower.contains("not local-first"),
                    "\(name) uses local-first without negation: \(raw)")
            }
        }
        XCTAssertEqual(CloudBotCopy.cloudLabel, "Cloud")
    }

    func testConversationExportFilenameUsesCurrentProductName() {
        let name = SettingsDiscoverabilityCopy.conversationsExportFilename
        XCTAssertEqual(name, "VibeCoder-conversations.json")
        XCTAssertFalse(name.lowercased().contains("agentos"))
    }

    func testComputerUseCopyIsThisMacNotCloud() {
        XCTAssertEqual(ComputerUseCopy.macLabel, "This Mac")
        XCTAssertNotEqual(ComputerUseCopy.macLabel, "Cloud")
        let intro = ComputerUseCopy.intro.lowercased()
        XCTAssertTrue(intro.contains("this mac"))
        XCTAssertTrue(intro.contains("screenshot"))
        XCTAssertTrue(intro.contains("click"))
        XCTAssertTrue(intro.contains("permission"))
        XCTAssertTrue(intro.contains("not cloud"))
        XCTAssertTrue(intro.contains("not a storefront"))
        XCTAssertFalse(intro.contains("nothing leaves"))
        let honesty = ComputerUseCopy.honesty.lowercased()
        XCTAssertTrue(honesty.contains("screen recording"))
        XCTAssertTrue(honesty.contains("accessibility"))
        XCTAssertFalse(AppSettings().computerUseEnabled)
        XCTAssertTrue(ComputerUseCopy.status(enabled: false).lowercased().contains("default"))
        XCTAssertTrue(ComputerUseCopy.status(enabled: true).lowercased().contains("this mac"))
        XCTAssertTrue(
            SettingsDiscoverabilityCopy.tabMatchesSearch(
                label: "Privacy",
                subtitle: "Data & backup",
                rawValue: "privacy",
                query: "screenshot"
            )
        )
    }

    func testComposerPlaceholderAskTheAgentNotZCode() {
        XCTAssertEqual(
            EmptyChatCopy.composerPlaceholder(isEmptyChat: true, isRunning: false),
            "Ask the agent…")
        XCTAssertEqual(
            EmptyChatCopy.composerPlaceholder(isEmptyChat: false, isRunning: false),
            "Ask for follow-up changes")
        XCTAssertEqual(
            EmptyChatCopy.composerPlaceholder(isEmptyChat: true, isRunning: true),
            "Keep typing to queue follow-up changes")
        XCTAssertEqual(
            EmptyChatCopy.composerPlaceholder(isEmptyChat: false, isRunning: true),
            EmptyChatCopy.composerQueue)
        XCTAssertEqual(EmptyChatCopy.sendButtonLabel(isRunning: false), "Send")
        XCTAssertEqual(EmptyChatCopy.sendButtonLabel(isRunning: true), "Queue message")
        XCTAssertEqual(EmptyChatCopy.sendButtonHelp(isRunning: true), "Queue after the current response")
        XCTAssertTrue(EmptyChatCopy.queueHelp.lowercased().contains("queue"))
        XCTAssertFalse(EmptyChatCopy.queueLabel.lowercased().contains("interject"))
        XCTAssertFalse(EmptyChatCopy.composerQueue.lowercased().contains("interject"))
        let empty = EmptyChatCopy.composerEmpty.lowercased()
        XCTAssertFalse(empty.contains("zcode"))
        XCTAssertFalse(empty.contains("electron"))
        XCTAssertTrue(empty.contains("agent"))
        XCTAssertFalse(EmptyChatCopy.composerQueue.lowercased().contains("zcode"))
        XCTAssertFalse(EmptyChatCopy.queueLabel.lowercased().contains("zcode"))
    }


    func testShellCardCopyRunningChip() {
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 12), "Running for 12s")
        XCTAssertEqual(ToolCallGrouping.longRunningChipLabel(elapsedSeconds: 125), "Running for 2m 5s")
        let card = ShellCard(index: 0, status: .running, command: "sleep 2", startedAt: Date().addingTimeInterval(-12))
        XCTAssertEqual(ShellCardCopy.title(card), "sleep 2")
        XCTAssertTrue(ShellCardCopy.status(card).hasPrefix("Running for"))
        XCTAssertFalse(ShellCardCopy.status(card).lowercased().contains("zcode"))
        XCTAssertEqual(ShellCard(index: 0, status: .success, command: "ls").kindLabel, "Ran")
    }


    func testReviewCardUnifiedPreview() {
        XCTAssertEqual(ReviewCardCopy.verb, "Review")
        XCTAssertEqual(ReviewCardCopy.hide, "Hide")
        let text = ReviewCardCopy.unified(
            path: "App/Foo.swift",
            lines: [.removed("old"), .added("new")])
        XCTAssertTrue(text.contains("--- a/App/Foo.swift"))
        XCTAssertTrue(text.contains("+++ b/App/Foo.swift"))
        XCTAssertTrue(text.contains("-old"))
        XCTAssertTrue(text.contains("+new"))
        XCTAssertFalse(text.lowercased().contains("zcode"))
        let many = (0..<500).map { CodeDiffLine.added("l\($0)") }
        let truncated = ReviewCardCopy.unified(path: "x.swift", lines: many)
        XCTAssertTrue(truncated.contains("lines omitted"))
    }


    func testSkillAndSubAgentCardCopy() {
        let skill = SkillCard(index: 0, isRunning: true, skillName: "review", args: "strict")
        XCTAssertEqual(SkillCardCopy.verb(skill), "Running skill")
        XCTAssertEqual(SkillCardCopy.status(skill), "review · strict")
        XCTAssertEqual(SkillCardCopy.verb(SkillCard(index: 0, isRunning: false, skillName: "review")), "Ran skill")
        let agent = AgentCard(index: 1, isRunning: true, prompt: "scan tests", agentType: "explore")
        XCTAssertEqual(SubAgentCardCopy.title, "SubAgent")
        XCTAssertEqual(SubAgentCardCopy.verb(agent), "Launching")
        XCTAssertEqual(SubAgentCardCopy.status(agent), "scan tests")
        XCTAssertEqual(SubAgentCardCopy.verb(AgentCard(index: 1, isRunning: false)), "Launched")
        XCTAssertFalse(SubAgentCardCopy.title.lowercased().contains("zcode"))
    }

    func testExploreCardCopyBuckets() {
        let counts = ExploreBucketCounts(searches: 2, lists: 1, files: 3)
        XCTAssertEqual(ExploreCardCopy.verb, "Explore")
        XCTAssertEqual(ExploreCardCopy.status(counts: counts), "2 searches, 1 list, 3 files")
        XCTAssertEqual(
            ExploreCardCopy.status(counts: ExploreBucketCounts()),
            "0 files")
        XCTAssertFalse(ExploreCardCopy.verb.lowercased().contains("zcode"))
        let grouped = ToolCallGrouping.group([
            ToolCallEvent(name: "grep_code"),
            ToolCallEvent(name: "list_directory"),
            ToolCallEvent(name: "read_file"),
        ])
        XCTAssertEqual(grouped.count, 1)
        if case .explore(let c, let idx) = grouped[0] {
            XCTAssertEqual(c.searches, 1)
            XCTAssertEqual(c.lists, 1)
            XCTAssertEqual(c.files, 1)
            XCTAssertEqual(idx.count, 3)
        } else {
            XCTFail("expected explore group")
        }
    }
    func testFileChangeCardCopyBuckets() {
        let mixed = FileChangeGroupCounts(writes: 2, updates: 1, deletes: 1, fileCount: 4)
        XCTAssertEqual(FileChangeCardCopy.status(counts: mixed), "2 writes, 1 update, 1 delete")
        XCTAssertEqual(
            FileChangeCardCopy.status(counts: FileChangeGroupCounts()),
            "0 files")
        XCTAssertEqual(
            FileChangeCardCopy.status(counts: FileChangeGroupCounts(fileCount: 3)),
            "3 files")
        let writeEvents = [
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "write_file"),
        ]
        XCTAssertEqual(
            FileChangeCardCopy.verb(events: writeEvents, memberIndices: [0, 1]),
            "Wrote")
        XCTAssertEqual(
            FileChangeCardCopy.verb(
                events: [ToolCallEvent(name: "edit_file", isRunning: true)],
                memberIndices: [0]),
            "Updating")
        XCTAssertFalse(
            FileChangeCardCopy.verb(events: writeEvents, memberIndices: [0, 1])
                .lowercased().contains("zcode"))
        XCTAssertFalse(FileChangeCardCopy.status(counts: mixed).lowercased().contains("zcode"))
        let grouped = ToolCallGrouping.group([
            ToolCallEvent(name: "write_file"),
            ToolCallEvent(name: "edit_file"),
            ToolCallEvent(name: "delete_file"),
        ])
        XCTAssertEqual(grouped.count, 1)
        if case .fileChange(let c, let idx) = grouped[0] {
            XCTAssertEqual(c.writes, 1)
            XCTAssertEqual(c.updates, 1)
            XCTAssertEqual(c.deletes, 1)
            XCTAssertEqual(c.total, 3)
            XCTAssertEqual(idx.count, 3)
        } else {
            XCTFail("expected fileChange group")
        }
    }
}

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
}

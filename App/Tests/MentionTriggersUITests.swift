//
//  MentionTriggersUITests.swift
//
//  Wave U2 — `$` skill / `#` session / `@` file triggers, pin headers,
//  and token strip. Does not replace MentionSearchCoordinatorTests.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class MentionTriggersUITests: XCTestCase {

    // MARK: - Trigger detection

    func testAtTriggerAfterWhitespace() {
        let hit = MentionSearchCoordinator.activeTrigger(in: "see @Foo.swift")
        XCTAssertEqual(hit?.kind, .at)
        XCTAssertEqual(hit?.query, "Foo.swift")
        XCTAssertEqual(MentionSearchCoordinator.activeMentionQuery(in: "see @Foo.swift"), "Foo.swift")
        XCTAssertEqual(MentionSearchCoordinator.activeMentionQuery(in: "@Bar"), "Bar")
    }

    func testEmailAtIsNotATrigger() {
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "please email max@icloud.com"))
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "user@example.com"))
        XCTAssertNil(MentionSearchCoordinator.activeMentionQuery(in: "please email max@icloud.com"))
        XCTAssertNil(MentionSearchCoordinator.activeMentionQuery(in: "user@example.com"))
    }

    func testDollarTrigger() {
        let bare = MentionSearchCoordinator.activeTrigger(in: "$verify")
        XCTAssertEqual(bare?.kind, .skill)
        XCTAssertEqual(bare?.query, "verify")
        let mid = MentionSearchCoordinator.activeTrigger(in: "use $demo-skill")
        XCTAssertEqual(mid?.kind, .skill)
        XCTAssertEqual(mid?.query, "demo-skill")
        XCTAssertNil(
            MentionSearchCoordinator.activeMentionQuery(in: "$verify"),
            "@-only helper must ignore $ tokens"
        )
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "cost$100"))
    }

    func testHashTrigger() {
        let bare = MentionSearchCoordinator.activeTrigger(in: "#Auth")
        XCTAssertEqual(bare?.kind, .session)
        XCTAssertEqual(bare?.query, "Auth")
        let mid = MentionSearchCoordinator.activeTrigger(in: "continue #handoff")
        XCTAssertEqual(mid?.kind, .session)
        XCTAssertEqual(mid?.query, "handoff")
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "issue#12"))
    }

    func testSpaceAndNewlineEndTrigger() {
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "@file more"))
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "$skill more"))
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "#sess more"))
        XCTAssertNil(MentionSearchCoordinator.activeTrigger(in: "@foo\nbar"))
        XCTAssertEqual(MentionSearchCoordinator.activeTrigger(in: "see @Foo $bar")?.kind, .skill)
        XCTAssertEqual(MentionSearchCoordinator.activeTrigger(in: "see @Foo $bar")?.query, "bar")
    }

    // MARK: - Skill / session filters

    func testSkillFilterMatchesName() {
        let skills = [
            DiscoveredSkill(
                name: "u2-alpha-skill",
                description: "Wave U2 alpha helper",
                body: "",
                source: .project,
                metadataOnly: true
            ),
            DiscoveredSkill(
                name: "other",
                description: "unrelated",
                body: "",
                source: .user,
                metadataOnly: true
            ),
        ]
        let hits = MentionSearchCoordinator.filterSkills(skills, query: "u2-alpha")
        XCTAssertEqual(hits.map(\.displayName), ["u2-alpha-skill"])
        XCTAssertEqual(hits.first?.kind, .skill)
        XCTAssertTrue(hits.first?.subtitle.contains("Wave U2 alpha helper") == true)

        let byDesc = MentionSearchCoordinator.filterSkills(skills, query: "alpha helper")
        XCTAssertEqual(byDesc.map(\.displayName), ["u2-alpha-skill"])

        let miss = MentionSearchCoordinator.filterSkills(skills, query: "zzzz-nope")
        XCTAssertTrue(miss.isEmpty)
    }

    func testSessionFilterMatchesTitle() {
        let keep = Conversation(title: "Auth rewrite")
        let skip = Conversation(title: "Unrelated notes")
        var archived = Conversation(title: "Auth old")
        archived.archived = true
        let hits = MentionSearchCoordinator.searchSessions(
            query: "Auth",
            sessions: [keep, skip, archived],
            currentID: nil
        )
        XCTAssertEqual(hits.map(\.displayName), ["Auth rewrite"])
        XCTAssertEqual(hits.first?.kind, .session)
        XCTAssertEqual(hits.first?.path, keep.id.uuidString)
    }

    func testSessionFilterMatchesPreviewAndExcludesCurrent() {
        let current = Conversation(title: "Current chat")
        let viaPreview = Conversation(
            title: "Nope",
            messages: [ChatMessage(role: .user, content: "implement oauth handshake")]
        )
        let hits = MentionSearchCoordinator.searchSessions(
            query: "oauth",
            sessions: [current, viaPreview],
            currentID: current.id
        )
        XCTAssertEqual(hits.map(\.path), [viaPreview.id.uuidString])
        XCTAssertTrue(hits.first?.subtitle.contains("oauth") == true)

        let empty = MentionSearchCoordinator.searchSessions(
            query: "",
            sessions: [current, viaPreview],
            currentID: current.id
        )
        XCTAssertFalse(empty.contains { $0.path == current.id.uuidString })
        XCTAssertTrue(empty.contains { $0.path == viaPreview.id.uuidString })
    }

    // MARK: - Pins / header

    func testSkillPinRecordRoundTripAndHeaderContainsName() {
        let pin = StickyContextPin(
            kind: .skill,
            path: "u2-missing-skill",
            displayName: "u2-missing-skill",
            symbolName: "One-line description"
        )
        let again = StickyContextPin(record: pin.asRecord)
        XCTAssertEqual(again.kind, .skill)
        XCTAssertEqual(again.path, pin.path)
        XCTAssertEqual(again.displayName, pin.displayName)
        XCTAssertEqual(again.symbolName, pin.symbolName)

        let header = StickyContextCompose.pinHeaderText(pins: [pin])
        XCTAssertTrue(header.contains("$skill u2-missing-skill"), header)
        XCTAssertTrue(header.contains("One-line description"), header)
    }

    func testSessionPinRecordRoundTripAndHeaderContainsUUID() {
        let id = UUID()
        let pin = StickyContextPin(
            kind: .session,
            path: id.uuidString,
            displayName: "Auth rewrite"
        )
        let again = StickyContextPin(record: pin.asRecord)
        XCTAssertEqual(again.kind, .session)
        XCTAssertEqual(again.path, id.uuidString)

        let header = StickyContextCompose.pinHeaderText(pins: [pin])
        XCTAssertTrue(header.contains(id.uuidString), header)
        XCTAssertTrue(header.contains("#session Auth rewrite"), header)
        XCTAssertTrue(header.contains("read_session_context"), header)
        XCTAssertTrue(header.contains("sessionId=\"\(id.uuidString)\""), header)
    }

    func testFileAttachmentsIgnoresSkillAndSession() {
        let pins = [
            StickyContextPin(kind: .skill, path: "verify", displayName: "verify"),
            StickyContextPin(kind: .session, path: UUID().uuidString, displayName: "Other"),
            StickyContextPin(kind: .file, path: "/p/A.swift", displayName: "A.swift"),
        ]
        let merged = StickyContextCompose.fileAttachments(pins: pins, pending: [])
        XCTAssertEqual(merged.map(\.path), ["/p/A.swift"])
    }

    func testCandidateInitsSkillAndSessionKinds() {
        let skill = DiscoveredSkill(
            name: "demo", description: "Does demo", body: "", source: .bundled, metadataOnly: true)
        let skillPin = StickyContextPin(candidate: MentionCandidate(skill: skill))
        XCTAssertEqual(skillPin.kind, .skill)
        XCTAssertEqual(skillPin.displayName, "demo")

        let conv = Conversation(title: "Handoff")
        let sessionPin = StickyContextPin(candidate: MentionCandidate(session: conv, preview: "hi"))
        XCTAssertEqual(sessionPin.kind, .session)
        XCTAssertEqual(sessionPin.path, conv.id.uuidString)
        XCTAssertEqual(sessionPin.displayName, "Handoff")
    }

    func testSkillHeaderUsesEnvelopeWhenFileExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("u2-skill-\(UUID().uuidString)", isDirectory: true)
        let skillDir = root
            .appendingPathComponent(".vibecoder", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("u2-disk-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let md = """
        ---
        name: u2-disk-skill
        description: Disk skill for pin header.
        ---
        # Body
        Do the disk thing.
        """
        let file = skillDir.appendingPathComponent("SKILL.md")
        try md.write(to: file, atomically: true, encoding: .utf8)

        let pin = StickyContextPin(
            kind: .skill,
            path: file.path,
            displayName: "u2-disk-skill",
            symbolName: "Disk skill for pin header."
        )
        let header = StickyContextCompose.pinHeaderText(pins: [pin])
        XCTAssertTrue(header.contains("u2-disk-skill"), header)
        XCTAssertTrue(header.contains("<skill") || header.contains("$skill"), header)
        XCTAssertTrue(header.contains("Do the disk thing"), header)
    }

    // MARK: - Token strip

    func testStripAtTokenStillWorks() {
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "see @Foo.swift"),
            "see "
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "@Bar"),
            ""
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "please email max@icloud.com"),
            "please email max@icloud.com"
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "user@example.com"),
            "user@example.com"
        )
    }

    func testStripDollarAndHashTokens() {
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "use $verify"),
            "use "
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "continue #Auth"),
            "continue "
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "cost$100"),
            "cost$100"
        )
        XCTAssertEqual(
            MentionSearchCoordinator.stripActiveTriggerToken(from: "issue#12"),
            "issue#12"
        )
    }
}

@MainActor
final class MentionTriggersRefreshUITests: XCTestCase {

    func testRefreshHashPublishesSessionCandidates() async {
        let keep = Conversation(title: "Auth rewrite")
        let skip = Conversation(title: "Unrelated")
        let coordinator = MentionSearchCoordinator()
        coordinator.debounceNanosecondsWarm = 1
        coordinator.debounceNanosecondsCold = 1
        await coordinator.refresh(
            text: "#Auth",
            root: nil,
            sessions: [keep, skip],
            currentID: nil
        )
        XCTAssertTrue(coordinator.showPopup)
        XCTAssertEqual(coordinator.activeTriggerKind, .session)
        XCTAssertEqual(coordinator.candidates.map(\.displayName), ["Auth rewrite"])
    }

    func testRefreshAtStillRequiresRoot() async {
        let coordinator = MentionSearchCoordinator()
        coordinator.debounceNanosecondsWarm = 1
        coordinator.debounceNanosecondsCold = 1
        await coordinator.refresh(text: "@Foo", root: nil)
        XCTAssertFalse(coordinator.showPopup)
        XCTAssertTrue(coordinator.candidates.isEmpty)
        XCTAssertEqual(coordinator.activeTriggerKind, .at)
    }
}

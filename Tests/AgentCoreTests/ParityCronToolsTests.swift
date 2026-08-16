//
//  ParityCronToolsTests.swift
//
//  Model-facing cron_create / cron_list / cron_update / cron_delete
//  (ZCode Cron* parity). Uses a temp-dir ScheduledTaskStore via
//  CronToolStore.override so tests never touch the UI's default folder.
//

import XCTest
@testable import AgentCore

final class ParityCronToolsTests: XCTestCase {

    private var dir: URL!
    private var store: ScheduledTaskStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-cron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ScheduledTaskStore(directoryURL: dir)
        CronToolStore.override = store
    }

    override func tearDownWithError() throws {
        CronToolStore.override = nil
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
        dir = nil
        store = nil
    }

    private func ctx(project: URL? = nil) -> ToolContext {
        ToolContext(projectRoot: project ?? dir, conversationID: UUID())
    }

    private func args(_ dict: [String: Any]) -> ToolArguments {
        ToolArguments(dictionary: dict)
    }

    // MARK: - Metadata

    func testToolMetadata() {
        XCTAssertEqual(CronCreateTool.name, "cron_create")
        XCTAssertEqual(CronListTool.name, "cron_list")
        XCTAssertEqual(CronUpdateTool.name, "cron_update")
        XCTAssertEqual(CronDeleteTool.name, "cron_delete")

        for category in [CronCreateTool.category, CronListTool.category,
                         CronUpdateTool.category, CronDeleteTool.category] {
            XCTAssertEqual(category, .planning)
        }
        for permission in [CronCreateTool.permission, CronListTool.permission,
                           CronUpdateTool.permission, CronDeleteTool.permission] {
            XCTAssertEqual(permission, .mutates)
        }
        for availability in [CronCreateTool.availability, CronListTool.availability,
                             CronUpdateTool.availability, CronDeleteTool.availability] {
            if case .core = availability { continue }
            XCTFail("expected .core availability, got \(availability)")
        }

        XCTAssertEqual(CronCreateTool.schema.parameters.required, ["name", "prompt", "frequency"])
        XCTAssertEqual(CronUpdateTool.schema.parameters.required, ["id"])
        XCTAssertEqual(CronDeleteTool.schema.parameters.required, ["id"])
        XCTAssertTrue(CronListTool.schema.parameters.required.isEmpty)
    }

    func testDescriptionsMentionAppMustBeOpenAndSnakeCaseNames() {
        let create = CronCreateTool.schema.description.lowercased()
        XCTAssertTrue(create.contains("while the app is open"), create)
        XCTAssertTrue(create.contains("cron_create"), CronCreateTool.schema.description)

        let list = CronListTool.schema.description.lowercased()
        XCTAssertTrue(list.contains("while the app is open"), list)
        XCTAssertTrue(CronListTool.schema.description.contains("cron_update"))
        XCTAssertTrue(CronListTool.schema.description.contains("cron_delete"))

        let update = CronUpdateTool.schema.description.lowercased()
        XCTAssertTrue(update.contains("while the app is open"), update)
        XCTAssertTrue(CronUpdateTool.schema.description.contains("cron_list"))

        let delete = CronDeleteTool.schema.description.lowercased()
        XCTAssertTrue(delete.contains("while the app is open"), delete)
        XCTAssertTrue(CronDeleteTool.schema.description.contains("cron_list"))
    }

    // MARK: - create / list

    func testCreateMapsPromptAndListsFields() async throws {
        let result = try await CronCreateTool().execute(
            arguments: args([
                "name": "Morning tests",
                "prompt": "run the test suite",
                "frequency": "daily",
                "timeOfDayMinutes": 540,
            ]),
            context: ctx())
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Created schedule"))
        XCTAssertTrue(result.content.contains("frequency: daily"))
        XCTAssertTrue(result.content.contains("time: 09:00"))
        XCTAssertTrue(result.content.contains("last_fired: never"))
        XCTAssertTrue(result.content.lowercased().contains("while the app is open"))

        let tasks = await store.load()
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.name, "Morning tests")
        XCTAssertEqual(task.shortPrompt, "run the test suite")
        XCTAssertEqual(task.longPrompt, "run the test suite")
        XCTAssertEqual(task.frequency, .daily)
        XCTAssertEqual(task.timeOfDayMinutes, 540)
        XCTAssertTrue(task.setupComplete)
        XCTAssertTrue(result.content.contains(task.id.uuidString))

        let listed = try await CronListTool().execute(arguments: args([:]), context: ctx())
        XCTAssertFalse(listed.isError, listed.content)
        XCTAssertTrue(listed.content.contains(task.id.uuidString))
        XCTAssertTrue(listed.content.contains("Morning tests"))
        XCTAssertTrue(listed.content.contains("frequency: daily"))
        XCTAssertTrue(listed.content.contains("time: 09:00"))
        XCTAssertTrue(listed.content.contains("last_fired: never"))
    }

    func testCreateDefaultsProjectFolderToWorkspace() async throws {
        let project = dir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await CronCreateTool().execute(
            arguments: args([
                "name": "ws",
                "prompt": "check the tree",
                "frequency": "hourly",
            ]),
            context: ctx(project: project))
        let after = await store.load()
        let task = try XCTUnwrap(after.first)
        XCTAssertEqual(task.projectFolder, project.path)
    }

    func testCreateAcceptsExplicitProjectFolder() async throws {
        _ = try await CronCreateTool().execute(
            arguments: args([
                "name": "other",
                "prompt": "do it",
                "frequency": "weekly",
                "projectFolder": "~/code/app",
            ]),
            context: ctx())
        let after = await store.load()
        let task = try XCTUnwrap(after.first)
        XCTAssertEqual(task.projectFolder, ("~/code/app" as NSString).expandingTildeInPath)
    }

    func testListEmpty() async throws {
        let result = try await CronListTool().execute(arguments: args([:]), context: ctx())
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "No scheduled tasks.")
    }

    func testListShowsLastFired() async throws {
        let fired = Date(timeIntervalSince1970: 1_787_000_000)
        await store.add(ScheduledTask(
            name: "stale",
            shortPrompt: "ping",
            frequency: .hourly,
            setupComplete: true,
            lastFiredAt: fired))
        let listed = try await CronListTool().execute(arguments: args([:]), context: ctx())
        XCTAssertTrue(listed.content.contains("stale"))
        XCTAssertFalse(listed.content.contains("last_fired: never"))
        XCTAssertTrue(listed.content.contains(ISO8601DateFormatter().string(from: fired)))
    }

    func testCreateRejectsUnknownFrequencyAndBadTime() async throws {
        let badFreq = try await CronCreateTool().execute(
            arguments: args([
                "name": "x",
                "prompt": "y",
                "frequency": "monthly",
            ]),
            context: ctx())
        XCTAssertTrue(badFreq.isError)
        XCTAssertTrue(badFreq.content.contains("unknown frequency"))

        let badTime = try await CronCreateTool().execute(
            arguments: args([
                "name": "x",
                "prompt": "y",
                "frequency": "daily",
                "timeOfDayMinutes": 1440,
            ]),
            context: ctx())
        XCTAssertTrue(badTime.isError)
        XCTAssertTrue(badTime.content.contains("0 to 1439"))
        let leftover = await store.load()
        XCTAssertTrue(leftover.isEmpty)
    }

    func testCreateRejectsEmptyNameAndPrompt() async throws {
        let emptyName = try await CronCreateTool().execute(
            arguments: args(["name": "  ", "prompt": "work", "frequency": "manual"]),
            context: ctx())
        XCTAssertTrue(emptyName.isError)

        let emptyPrompt = try await CronCreateTool().execute(
            arguments: args(["name": "n", "prompt": "   ", "frequency": "manual"]),
            context: ctx())
        XCTAssertTrue(emptyPrompt.isError)
    }

    // MARK: - 20-task cap

    func testCreateCapsAtTwentyWithDoNotRetry() async throws {
        for i in 0..<20 {
            await store.add(ScheduledTask(
                name: "seed-\(i)",
                shortPrompt: "p\(i)",
                frequency: .manual,
                setupComplete: true))
        }
        let seeded = await store.load()
        XCTAssertEqual(seeded.count, 20)

        let result = try await CronCreateTool().execute(
            arguments: args([
                "name": "one-too-many",
                "prompt": "should not persist",
                "frequency": "daily",
            ]),
            context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.content, "Error: do not retry; schedule limit reached")
        let afterCap = await store.load()
        XCTAssertEqual(afterCap.count, 20)
        XCTAssertFalse(afterCap.contains(where: { $0.name == "one-too-many" }))
    }

    // MARK: - update / delete

    func testUpdatePatchesFields() async throws {
        let created = try await CronCreateTool().execute(
            arguments: args([
                "name": "old",
                "prompt": "first prompt",
                "frequency": "daily",
                "timeOfDayMinutes": 120,
            ]),
            context: ctx())
        XCTAssertFalse(created.isError, created.content)
        let createdTasks = await store.load()
        let id = try XCTUnwrap(createdTasks.first?.id)

        let updated = try await CronUpdateTool().execute(
            arguments: args([
                "id": id.uuidString,
                "name": "new",
                "prompt": "second prompt",
                "frequency": "weekdays",
                "timeOfDayMinutes": 600,
                "projectFolder": "/tmp/proj",
            ]),
            context: ctx())
        XCTAssertFalse(updated.isError, updated.content)
        XCTAssertTrue(updated.content.contains("Updated schedule"))
        XCTAssertTrue(updated.content.contains("frequency: weekdays"))
        XCTAssertTrue(updated.content.contains("time: 10:00"))

        let patched = await store.task(id: id)
        let task = try XCTUnwrap(patched)
        XCTAssertEqual(task.name, "new")
        XCTAssertEqual(task.shortPrompt, "second prompt")
        XCTAssertEqual(task.longPrompt, "second prompt")
        XCTAssertEqual(task.frequency, .weekdays)
        XCTAssertEqual(task.timeOfDayMinutes, 600)
        XCTAssertEqual(task.projectFolder, "/tmp/proj")
        XCTAssertEqual(task.id, id)
    }

    func testUpdateOmitsKeepExistingAndClearsFolder() async throws {
        _ = try await CronCreateTool().execute(
            arguments: args([
                "name": "keep",
                "prompt": "original",
                "frequency": "weekly",
                "timeOfDayMinutes": 90,
                "projectFolder": "/tmp/keep",
            ]),
            context: ctx())
        let createdTasks = await store.load()
        let id = try XCTUnwrap(createdTasks.first?.id)

        let onlyFreq = try await CronUpdateTool().execute(
            arguments: args(["id": id.uuidString, "frequency": "hourly"]),
            context: ctx())
        XCTAssertFalse(onlyFreq.isError, onlyFreq.content)
        var lookedUp = await store.task(id: id)
        var task = try XCTUnwrap(lookedUp)
        XCTAssertEqual(task.frequency, .hourly)
        XCTAssertEqual(task.name, "keep")
        XCTAssertEqual(task.shortPrompt, "original")
        XCTAssertEqual(task.timeOfDayMinutes, 90)
        XCTAssertEqual(task.projectFolder, "/tmp/keep")

        let cleared = try await CronUpdateTool().execute(
            arguments: args(["id": id.uuidString, "projectFolder": ""]),
            context: ctx())
        XCTAssertFalse(cleared.isError, cleared.content)
        lookedUp = await store.task(id: id)
        task = try XCTUnwrap(lookedUp)
        XCTAssertNil(task.projectFolder)
    }

    func testUpdateRequiresAPatchField() async throws {
        _ = try await CronCreateTool().execute(
            arguments: args(["name": "n", "prompt": "p", "frequency": "manual"]),
            context: ctx())
        let createdTasks = await store.load()
        let id = try XCTUnwrap(createdTasks.first?.id)
        let result = try await CronUpdateTool().execute(
            arguments: args(["id": id.uuidString]),
            context: ctx())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("nothing to update"))
    }

    func testUpdateAndDeleteUnknownOrInvalidID() async throws {
        let missing = UUID()
        let upd = try await CronUpdateTool().execute(
            arguments: args(["id": missing.uuidString, "name": "x"]),
            context: ctx())
        XCTAssertTrue(upd.isError)
        XCTAssertTrue(upd.content.contains("no schedule"))

        let del = try await CronDeleteTool().execute(
            arguments: args(["id": missing.uuidString]),
            context: ctx())
        XCTAssertTrue(del.isError)
        XCTAssertTrue(del.content.contains("no schedule"))

        let bad = try await CronDeleteTool().execute(
            arguments: args(["id": "not-a-uuid"]),
            context: ctx())
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.content.contains("invalid schedule id"))
    }

    func testDeleteRemovesTask() async throws {
        _ = try await CronCreateTool().execute(
            arguments: args(["name": "gone", "prompt": "bye", "frequency": "manual"]),
            context: ctx())
        let createdTasks = await store.load()
        let id = try XCTUnwrap(createdTasks.first?.id)

        let deleted = try await CronDeleteTool().execute(
            arguments: args(["id": id.uuidString]),
            context: ctx())
        XCTAssertFalse(deleted.isError, deleted.content)
        XCTAssertTrue(deleted.content.contains(id.uuidString))
        XCTAssertTrue(deleted.content.contains("gone"))
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty)

        let listed = try await CronListTool().execute(arguments: args([:]), context: ctx())
        XCTAssertEqual(listed.content, "No scheduled tasks.")
    }
}

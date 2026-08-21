//
//  SchedulerServiceTests.swift
//
//  The scheduler engine was fully built but never instantiated, so
//  scheduled tasks never fired (2026-06-10 audit). These tests pin the
//  pure firing logic and that a tick actually fires due tasks and stamps
//  lastFiredAt — the behaviour the boot-time wiring now relies on.
//
//  PC7: setupComplete / empty-prompt gates, tick re-entrancy skip, status,
//  ISO week boundary, JobMonitor formatting.
//

import XCTest
@testable import AgentCore

final class SchedulerServiceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentos-sched-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func task(
        _ freq: TaskFrequency,
        lastFired: Date? = nil,
        setupComplete: Bool = true,
        name: String = "t",
        shortPrompt: String = "do work"
    ) -> ScheduledTask {
        ScheduledTask(
            name: name,
            shortPrompt: shortPrompt,
            frequency: freq,
            setupComplete: setupComplete,
            lastFiredAt: lastFired
        )
    }

    // MARK: - shouldFire

    func testManualNeverFires() {
        XCTAssertFalse(SchedulerService.shouldFire(task: task(.manual), now: Date()))
    }

    func testIncompleteSetupNeverFires() {
        XCTAssertFalse(
            SchedulerService.shouldFire(
                task: task(.daily, setupComplete: false),
                now: Date()
            )
        )
    }

    func testEmptyPromptNeverFires() {
        let empty = ScheduledTask(
            name: "   ",
            shortPrompt: "",
            longPrompt: "",
            frequency: .daily,
            setupComplete: true
        )
        XCTAssertFalse(SchedulerService.shouldFire(task: empty, now: Date()))
        XCTAssertFalse(SchedulerService.hasRunnablePrompt(empty))
    }

    func testNeverFiredTasksFireOnFirstTick() {
        XCTAssertTrue(SchedulerService.shouldFire(task: task(.daily), now: Date()))
        XCTAssertTrue(SchedulerService.shouldFire(task: task(.hourly), now: Date()))
    }

    func testDailyFiresOncePerDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14))!
        let earlierSameDay = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 10))!
        XCTAssertFalse(SchedulerService.shouldFire(
            task: task(.daily, lastFired: earlierSameDay), now: now, calendar: cal))
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 14))!
        XCTAssertTrue(SchedulerService.shouldFire(
            task: task(.daily, lastFired: yesterday), now: now, calendar: cal))
    }

    func testWeekdaysSkipsWeekend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-06-13 is a Saturday, 2026-06-15 a Monday.
        let saturday = cal.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 9))!
        let monday = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
        XCTAssertFalse(SchedulerService.shouldFire(task: task(.weekdays), now: saturday, calendar: cal))
        XCTAssertTrue(SchedulerService.shouldFire(task: task(.weekdays), now: monday, calendar: cal))
    }

    func testWeeklySameISOWeekDoesNotRefire() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Both in ISO week of mid-June 2026.
        let mon = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))!
        let wed = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 10))!
        XCTAssertTrue(SchedulerService.sameISOWeek(mon, wed, calendar: cal))
        XCTAssertFalse(SchedulerService.shouldFire(
            task: task(.weekly, lastFired: mon), now: wed, calendar: cal))
        let nextWeek = cal.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 10))!
        XCTAssertTrue(SchedulerService.shouldFire(
            task: task(.weekly, lastFired: mon), now: nextWeek, calendar: cal))
    }

    // MARK: - time-of-day gating

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func testDailyWithTimeOfDayDoesNotFireBeforeTheTime() {
        let cal = utcCalendar()
        let at0130 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 1, minute: 30))!
        let task = ScheduledTask(name: "t", shortPrompt: "x", frequency: .daily,
                                 timeOfDayMinutes: 120, setupComplete: true) // 02:00
        XCTAssertFalse(SchedulerService.shouldFire(task: task, now: at0130, calendar: cal),
                       "must not fire before its time-of-day")
    }

    func testDailyWithTimeOfDayFiresAtOrAfterTheTime() {
        let cal = utcCalendar()
        let at0205 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 2, minute: 5))!
        let task = ScheduledTask(name: "t", shortPrompt: "x", frequency: .daily,
                                 timeOfDayMinutes: 120, setupComplete: true)
        XCTAssertTrue(SchedulerService.shouldFire(task: task, now: at0205, calendar: cal))
    }

    func testDailyWithTimeOfDayCatchesUpWhenAppOpensLater() {
        // App opens at 09:00; a 02:00 daily task that never fired today
        // should fire (catch-up), not wait until tomorrow.
        let cal = utcCalendar()
        let at0900 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9))!
        let task = ScheduledTask(name: "t", shortPrompt: "x", frequency: .daily,
                                 timeOfDayMinutes: 120, setupComplete: true)
        XCTAssertTrue(SchedulerService.shouldFire(task: task, now: at0900, calendar: cal))
    }

    func testDailyWithTimeOfDayDoesNotRefireSameDay() {
        let cal = utcCalendar()
        let firedAt0201 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 2, minute: 1))!
        let at0900 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9))!
        let task = ScheduledTask(name: "t", shortPrompt: "x", frequency: .daily,
                                 timeOfDayMinutes: 120, setupComplete: true,
                                 lastFiredAt: firedAt0201)
        XCTAssertFalse(SchedulerService.shouldFire(task: task, now: at0900, calendar: cal))
    }

    func testScheduleDescriptionFormatsTime() {
        XCTAssertEqual(ScheduledTask(name: "t", frequency: .daily, timeOfDayMinutes: 120).scheduleDescription,
                       "Daily · 02:00")
        XCTAssertEqual(ScheduledTask(name: "t", frequency: .weekdays, timeOfDayMinutes: 540).scheduleDescription,
                       "Weekdays · 09:00")
        XCTAssertEqual(ScheduledTask(name: "t", frequency: .hourly).scheduleDescription, "Hourly")
        XCTAssertEqual(ScheduledTask(name: "t", frequency: .daily).scheduleDescription, "Daily")
    }

    func testDueTasksHelper() {
        let tasks = [task(.daily), task(.manual), task(.daily, setupComplete: false)]
        let due = SchedulerService.dueTasks(tasks, now: Date())
        XCTAssertEqual(due.count, 1)
    }

    // MARK: - tick

    func testTickFiresDueTasksAndStampsLastFired() async throws {
        let store = ScheduledTaskStore(directoryURL: dir)
        await store.add(task(.daily))                 // due (never fired)
        await store.add(task(.manual))                // never fires

        let fired = FiredBox()
        let now = Date()
        let scheduler = SchedulerService(store: store, clock: { now }, fireTask: { t in
            await fired.append(t.id)
            return nil
        })

        await scheduler.tick()

        let firedIDs = await fired.ids
        XCTAssertEqual(firedIDs.count, 1, "only the daily task should fire")

        // A second tick in the same day must NOT re-fire it (lastFiredAt stamped).
        await scheduler.tick()
        let afterSecond = await fired.ids
        XCTAssertEqual(afterSecond.count, 1, "daily task must not re-fire same day")

        let st = await scheduler.status()
        XCTAssertEqual(st.lastTickFiredCount, 0) // second tick fired 0
        XCTAssertEqual(st.lastTickDueCount, 0)
        XCTAssertNotNil(st.lastTickAt)
        XCTAssertFalse(st.tickInFlight)
    }

    func testReloadPicksUpTasksAddedAfterFirstTick() async throws {
        // load() caches; tick() must use reload() so UI-created tasks
        // appear on the next cycle. Add a task AFTER the first tick.
        let store = ScheduledTaskStore(directoryURL: dir)
        let fired = FiredBox()
        let now = Date()
        let scheduler = SchedulerService(store: store, clock: { now }, fireTask: { t in
            await fired.append(t.id)
            return nil
        })
        await scheduler.tick()                         // nothing yet
        let before = await fired.ids.count
        XCTAssertEqual(before, 0)

        await store.add(task(.daily))                  // UI adds a task later
        await scheduler.tick()
        let after = await fired.ids.count
        XCTAssertEqual(after, 1, "tick must re-scan and fire newly-added tasks")
    }

    func testOverlappingTickSkipsWhileInFlight() async throws {
        let store = ScheduledTaskStore(directoryURL: dir)
        await store.add(task(.hourly))
        let fired = FiredBox()
        let gate = Gate()
        let now = Date()
        let scheduler = SchedulerService(store: store, clock: { now }, fireTask: { t in
            await gate.wait()
            await fired.append(t.id)
            return UUID()
        })

        async let first: Void = scheduler.tick()
        // Give first tick time to enter fireTask and set tickInFlight.
        try await Task.sleep(nanoseconds: 30_000_000)
        // Second tick must no-op while first is in flight.
        await scheduler.tick()
        await gate.open()
        await first

        let count = await fired.ids.count
        XCTAssertEqual(count, 1, "overlapping tick must not double-fire")
    }

    func testStartStopPollingFlag() async throws {
        let store = ScheduledTaskStore(directoryURL: dir)
        let scheduler = SchedulerService(
            store: store,
            pollInterval: 3600,
            fireTask: { _ in nil }
        )
        var polling = await scheduler.isPolling
        XCTAssertFalse(polling)
        await scheduler.start()
        polling = await scheduler.isPolling
        XCTAssertTrue(polling)
        let st = await scheduler.status()
        XCTAssertTrue(st.isPolling)
        await scheduler.stop()
        polling = await scheduler.isPolling
        XCTAssertFalse(polling)
    }
}

// MARK: - JobMonitor

final class JobMonitorTests: XCTestCase {

    override func tearDown() {
        failClosedTearDownLeftovers()
        super.tearDown()
    }

    func testFormatEmptyListIsHonest() {
        let text = JobMonitor.formatList([])
        XCTAssertTrue(text.contains("none running"))
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("not a full Grok")
                || text.localizedCaseInsensitiveContains("not a Grok"),
            "empty copy must disclaim full monitor product"
        )
    }

    func testFormatElapsedHelpers() {
        XCTAssertEqual(JobMonitor.formatElapsed(0), "0s")
        XCTAssertEqual(JobMonitor.formatElapsed(12), "12s")
        XCTAssertEqual(JobMonitor.formatElapsed(65), "1m 05s")
        XCTAssertEqual(JobMonitor.formatElapsed(3723), "1h 02m")
        XCTAssertEqual(JobMonitor.friendlyKind(.shell), "Shell")
        XCTAssertEqual(JobMonitor.friendlyKind(.subagent), "Subagent")
        XCTAssertEqual(JobMonitor.friendlyStatus(.killed), "stopped")
    }

    func testFormatRunningListIncludesIds() async throws {
        // Use a real BackgroundJobManager registration with a short no-op shell.
        let id = try await BackgroundJobManager.shared.startShell(
            command: "sleep 0.2",
            workingDirectory: nil,
            timeout: 5,
            conversationID: nil
        )
        defer {
            Task { _ = await BackgroundJobManager.shared.kill(id) }
        }
        // Brief wait for process to be registered as running.
        try await Task.sleep(nanoseconds: 20_000_000)
        let entries = await JobMonitor.listRunning()
        // May already have completed on very fast machines — format still works.
        let text = JobMonitor.formatList(entries)
        if entries.contains(where: { $0.snapshot.id == id }) {
            let short = String(id.uuidString.prefix(8)).lowercased()
            XCTAssertTrue(text.contains(short) || text.contains(id.uuidString))
            XCTAssertTrue(text.contains("Shell") || text.contains("running"))
        } else {
            XCTAssertTrue(text.contains("Background jobs"))
        }
        _ = await BackgroundJobManager.shared.kill(id)
    }

    func testFormatListStructure() {
        let snap = BackgroundJobSnapshot(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            kind: .shell,
            status: .running,
            command: "echo hello",
            output: "hello\n",
            exitCode: nil,
            startedAt: Date().addingTimeInterval(-12),
            finishedAt: nil,
            conversationID: nil
        )
        let entry = JobMonitor.Entry(snapshot: snap, now: Date())
        XCTAssertGreaterThanOrEqual(entry.elapsedSeconds, 11)
        let text = JobMonitor.formatList([entry])
        XCTAssertTrue(text.contains("1 running") || text.contains("Background jobs: 1"))
        XCTAssertTrue(text.contains("echo hello"))
        XCTAssertTrue(text.contains("Shell"))
        XCTAssertTrue(text.contains("aaaaaaaa") || text.contains("AAAAAAAA"))
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("not a Grok"),
            "non-empty header must keep honesty line"
        )
        // Readable elapsed, not raw "elapsed=12s" key style
        XCTAssertTrue(text.contains("12s") || text.contains("1m"))
    }
}

/// Thread-safe recorder for fired task ids.
private actor FiredBox {
    private(set) var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
}

/// Async gate for re-entrancy tests.
private actor Gate {
    private var openFlag = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if openFlag { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func open() {
        openFlag = true
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }
}

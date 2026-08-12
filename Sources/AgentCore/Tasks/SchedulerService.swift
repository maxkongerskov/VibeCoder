//
//  SchedulerService.swift
//
//  In-process polling timer that fires scheduled tasks as they come due.
//  While AgentOS is open, this is what makes Scheduled actually run — not a
//  background daemon, not a LaunchAgent, just a `DispatchSourceTimer` in
//  the actor's executor. When the app closes, the scheduler stops.
//
//  Concurrency: rewritten from `@MainActor ObservableObject` + `Timer` to
//  a `public actor` driven by `DispatchSource.makeTimerSource` — that
//  avoids capturing a non-Sendable `Timer` across isolation boundaries
//  under Swift 6 strict concurrency. The fire callback is `@Sendable`
//  and async so it can hop into any isolation domain.
//
//  Pure firing logic (`shouldFire(task:now:)`) is `static` + side-effect-
//  free so tests can drive it with a synthetic clock and verify every
//  frequency branch without waiting real time.
//
//  PC7: re-entrancy-safe tick, skip incomplete/empty tasks, stronger
//  weekly period check, status snapshot for monitor UI.
//

import Foundation

public actor SchedulerService {

    /// Closure type for the wall clock — defaults to `Date()`. Tests inject
    /// a synthetic clock.
    public typealias Clock = @Sendable () -> Date

    /// Callback invoked once per due task per tick. Production wires this
    /// to a closure that spawns a new conversation with the task's prompt
    /// and returns that conversation's id (so the scheduler can record it
    /// on the task for the "last run →" link); tests pass a closure that
    /// records calls. Returns nil when no conversation was produced (e.g.
    /// no model available).
    public typealias FireTask = @Sendable (ScheduledTask) async -> UUID?

    /// Lightweight observability for Settings / debug (not a full monitor product).
    public struct Status: Sendable, Equatable {
        public let isPolling: Bool
        public let pollInterval: TimeInterval
        public let lastTickAt: Date?
        public let lastTickFiredCount: Int
        public let lastTickDueCount: Int
        public let tickInFlight: Bool

        public init(isPolling: Bool,
                    pollInterval: TimeInterval,
                    lastTickAt: Date?,
                    lastTickFiredCount: Int,
                    lastTickDueCount: Int,
                    tickInFlight: Bool) {
            self.isPolling = isPolling
            self.pollInterval = pollInterval
            self.lastTickAt = lastTickAt
            self.lastTickFiredCount = lastTickFiredCount
            self.lastTickDueCount = lastTickDueCount
            self.tickInFlight = tickInFlight
        }
    }

    private let clock: Clock
    private let fireTask: FireTask
    private let pollInterval: TimeInterval
    private let store: ScheduledTaskStore
    private var timer: DispatchSourceTimer?

    private var lastTickAt: Date?
    private var lastTickFiredCount: Int = 0
    private var lastTickDueCount: Int = 0
    /// Prevents overlapping ticks if a slow `fireTask` outlives `pollInterval`
    /// (timer handler always schedules a new Task; actor serializes but we
    /// still skip a piled-up tick so we don't re-fire with a stale `now`).
    private var tickInFlight: Bool = false

    /// - Parameters:
    ///   - store: Source of truth for tasks. The scheduler `await`s `load()`
    ///     on every tick — fresh writes by the UI are visible on the next
    ///     poll cycle without a manual refresh.
    ///   - clock: Wall clock. Defaults to `Date()`.
    ///   - pollInterval: Seconds between ticks. Defaults to 60s in production;
    ///     tests pass a smaller value to exercise tick behavior fast.
    ///   - fireTask: Side-effecting callback invoked for each due task.
    public init(store: ScheduledTaskStore,
                clock: @escaping Clock = { Date() },
                pollInterval: TimeInterval = 60.0,
                fireTask: @escaping FireTask) {
        self.store = store
        self.clock = clock
        self.pollInterval = pollInterval
        self.fireTask = fireTask
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Lifecycle

    /// Begin polling. Fires an initial `tick()` so any tasks that became
    /// due while the app was closed get caught on launch.
    public func start() async {
        stop()
        await tick()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.tick()
            }
        }
        t.resume()
        timer = t
    }

    /// Stop polling. Safe to call multiple times.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Whether a timer is currently scheduled.
    public var isPolling: Bool { timer != nil }

    /// Observability snapshot (PC7 monitor v0 for the scheduler itself).
    public func status() -> Status {
        Status(
            isPolling: timer != nil,
            pollInterval: pollInterval,
            lastTickAt: lastTickAt,
            lastTickFiredCount: lastTickFiredCount,
            lastTickDueCount: lastTickDueCount,
            tickInFlight: tickInFlight
        )
    }

    // MARK: One tick

    /// One polling cycle: evaluate every task, fire the due ones, mark them
    /// with `lastFiredAt`. Exposed so tests can drive deterministically.
    ///
    /// Overlapping ticks (slow fire + short poll) skip while a previous tick
    /// is still in flight — avoids double-stamping with a delayed clock read.
    public func tick() async {
        if tickInFlight { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let now = clock()
        lastTickAt = now
        // reload() (not load()) so tasks the UI created/edited since the
        // last tick are picked up — load() caches after the first call.
        let tasks = await store.reload()
        let due = tasks.filter { Self.shouldFire(task: $0, now: now) }
        lastTickDueCount = due.count
        var fired = 0
        for task in due {
            let conversationID = await fireTask(task)
            var updated = task
            // Always stamp lastFiredAt so we do not re-fire every 60s when
            // fireTask returns nil (e.g. no model). UI "Run now" can still
            // invoke fireTask out of band without going through shouldFire.
            updated.lastFiredAt = now
            if let conversationID { updated.lastRunConversationID = conversationID }
            await store.save(updated)
            fired += 1
        }
        lastTickFiredCount = fired
    }

    // MARK: Pure firing logic

    /// Tasks that would fire at `now` (no side effects). Useful for UI previews.
    public static func dueTasks(
        _ tasks: [ScheduledTask],
        now: Date,
        calendar: Calendar = .current
    ) -> [ScheduledTask] {
        tasks.filter { shouldFire(task: $0, now: now, calendar: calendar) }
    }

    /// Returns true if a task is due to fire at `now`, given its `frequency`
    /// and `lastFiredAt`. No I/O, no side effects — fully testable.
    ///
    /// Semantics:
    /// - `.manual` never auto-fires (user runs it from the UI).
    /// - Incomplete setup (`setupComplete == false`) never auto-fires.
    /// - Empty prompt (no short/long/name useful body) never auto-fires.
    /// - `.hourly` fires once per calendar hour (time-of-day ignored).
    /// - `.daily` fires once per calendar day.
    /// - `.weekdays` fires once per calendar day, but only Mon–Fri.
    /// - `.weekly` fires once per ISO week (`yearForWeekOfYear` + `weekOfYear`).
    /// - For the day-based frequencies, when `timeOfDayMinutes` is set the
    ///   task does NOT fire until the clock has passed that time on a
    ///   qualifying day — so "Daily · 02:00" fires on the first tick at or
    ///   after 02:00 (including a catch-up fire if the app opens later that
    ///   morning and it hasn't run yet). nil time = fire on the first
    ///   matching tick (legacy behaviour).
    public static func shouldFire(task: ScheduledTask,
                                  now: Date,
                                  calendar: Calendar = .current) -> Bool {
        // Incomplete questionnaire / empty shell tasks stay silent.
        guard task.setupComplete else { return false }
        guard hasRunnablePrompt(task) else { return false }

        switch task.frequency {
        case .manual:
            return false

        case .hourly:
            guard let last = task.lastFiredAt else { return true }
            return !calendar.isDate(last, equalTo: now, toGranularity: .hour)

        case .daily, .weekdays, .weekly:
            // Weekdays only fire Mon–Fri.
            if task.frequency == .weekdays {
                let weekday = calendar.component(.weekday, from: now)  // 1=Sun … 7=Sat
                guard (2...6).contains(weekday) else { return false }
            }
            // Already fired this period?
            if let last = task.lastFiredAt {
                if task.frequency == .weekly {
                    if sameISOWeek(last, now, calendar: calendar) { return false }
                } else if calendar.isDate(last, equalTo: now, toGranularity: .day) {
                    return false
                }
            }
            // Time-of-day gate.
            if let tod = task.timeOfDayMinutes {
                let clamped = max(0, min(tod, 24 * 60 - 1))
                let nowMinutes = calendar.component(.hour, from: now) * 60
                              + calendar.component(.minute, from: now)
                if nowMinutes < clamped { return false }
            }
            return true
        }
    }

    /// True when the task has something the agent can run.
    public static func hasRunnablePrompt(_ task: ScheduledTask) -> Bool {
        let parts = [task.shortPrompt, task.longPrompt, task.name]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !parts.isEmpty
    }

    /// ISO-week equality using both week-of-year and year-for-week-of-year
    /// so week 1 of adjacent years does not collide.
    public static func sameISOWeek(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        let wa = calendar.component(.weekOfYear, from: a)
        let ya = calendar.component(.yearForWeekOfYear, from: a)
        let wb = calendar.component(.weekOfYear, from: b)
        let yb = calendar.component(.yearForWeekOfYear, from: b)
        return wa == wb && ya == yb
    }
}

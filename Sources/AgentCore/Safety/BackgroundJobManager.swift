//
//  BackgroundJobManager.swift
//
//  Background shell (and subagent) task registry: start → task_id,
//  get output, wait, kill, cleanup (global or per-conversation).
//
//  Subagents: `registerSubagent` + optional `attachSubagentWork` so
//  TaskTool(run_in_background:true) returns immediately while the child
//  loop runs on a stored waiter Task (kill cancels it).
//
//  Phase C PC4 — completion auto-wake:
//    Terminal transitions (complete / fail / kill / shell finalize) publish
//    `BackgroundJobCompletion` to:
//      1. in-memory pending queue (drain via takePendingCompletions)
//      2. live AsyncStream subscribers (subscribeCompletions)
//    Hosts (ChatViewModel / AgentLoop) can surface a parent-visible notice
//    without polling alone. Maps to AgentEvent.backgroundJobCompleted.
//

import Foundation

public enum BackgroundJobKind: String, Sendable {
    case shell
    case subagent
}

public enum BackgroundJobStatus: String, Sendable, Equatable {
    case running
    case completed
    case failed
    case killed
    case timedOut
}

public struct BackgroundJobSnapshot: Sendable, Equatable {
    public let id: UUID
    public let kind: BackgroundJobKind
    public let status: BackgroundJobStatus
    public let command: String
    public let output: String
    public let exitCode: Int32?
    public let startedAt: Date
    public let finishedAt: Date?
    /// Owning conversation — used for scoped cleanup so deleting one
    /// chat does not kill jobs belonging to another.
    public let conversationID: UUID?

    public init(id: UUID, kind: BackgroundJobKind, status: BackgroundJobStatus,
                command: String, output: String, exitCode: Int32?,
                startedAt: Date, finishedAt: Date?,
                conversationID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.conversationID = conversationID
    }
}


// MARK: - Completion auto-wake (PC4)

/// Parent-visible notice when a background job reaches a terminal status.
/// Reuses the same `task_id` as get_task_output / wait_tasks / kill_task.
public struct BackgroundJobCompletion: Sendable, Equatable {
    public let taskId: UUID
    public let kind: BackgroundJobKind
    public let status: BackgroundJobStatus
    public let command: String
    public let outputPreview: String
    public let conversationID: UUID?
    public let finishedAt: Date

    public init(taskId: UUID, kind: BackgroundJobKind, status: BackgroundJobStatus,
                command: String, outputPreview: String, conversationID: UUID?,
                finishedAt: Date = Date()) {
        self.taskId = taskId
        self.kind = kind
        self.status = status
        self.command = command
        self.outputPreview = outputPreview
        self.conversationID = conversationID
        self.finishedAt = finishedAt
    }

    public init(snapshot: BackgroundJobSnapshot) {
        self.taskId = snapshot.id
        self.kind = snapshot.kind
        self.status = snapshot.status
        self.command = snapshot.command
        self.outputPreview = String(snapshot.output.prefix(500))
        self.conversationID = snapshot.conversationID
        self.finishedAt = snapshot.finishedAt ?? Date()
    }

    /// One-line status suitable for AgentEvent.info / status line / next-turn wake.
    public var wakeMessage: String {
        let kindLabel = kind == .subagent ? "subagent" : "background job"
        let statusWord: String
        switch status {
        case .completed: statusWord = "completed"
        case .failed: statusWord = "failed"
        case .killed: statusWord = "was killed"
        case .timedOut: statusWord = "timed out"
        case .running: statusWord = "is still running"
        }
        let cmd = command.isEmpty ? taskId.uuidString : command
        let preview = outputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            return "Background \(kindLabel) \(statusWord): \(cmd) (task_id=\(taskId.uuidString))"
        }
        let short = preview.count > 120 ? String(preview.prefix(117)) + "…" : preview
        return "Background \(kindLabel) \(statusWord): \(cmd) — \(short) (task_id=\(taskId.uuidString))"
    }

    /// Map into a parent-visible AgentEvent (status/UI without ending the turn).
    public var agentEvent: AgentEvent {
        .backgroundJobCompleted(
            taskId: taskId,
            kind: kind.rawValue,
            status: status.rawValue,
            summary: wakeMessage,
            conversationID: conversationID
        )
    }
}

public actor BackgroundJobManager {
    public static let shared = BackgroundJobManager()
    public static let maxConcurrent = 8

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        let outBox = DataBox()
        let errBox = DataBox()
        init(_ p: Process) { self.process = p }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private struct Job {
        var snapshot: BackgroundJobSnapshot
        var box: ProcessBox?
        var waiter: Task<Void, Never>?
        var cancelled: Bool = false
    }

    private var jobs: [UUID: Job] = [:]

    /// Completions not yet drained by the host (conversation-scoped wake queue).
    private var pendingCompletions: [BackgroundJobCompletion] = []
    /// Live subscribers for push-style auto-wake (UI / optional loop inject).
    private var completionListeners: [UUID: AsyncStream<BackgroundJobCompletion>.Continuation] = [:]
    /// Job ids already auto-waked (dedupe kill + completeSubagent races).
    private var publishedCompletionIDs: Set<UUID> = []
    private static let maxPendingCompletions = 64

    public func startShell(
        command: String,
        workingDirectory: URL?,
        timeout: TimeInterval = 3600,
        conversationID: UUID? = nil
    ) throws -> UUID {
        let running = jobs.values.filter { $0.snapshot.status == .running }.count
        guard running < Self.maxConcurrent else {
            throw ToolError.execution("Too many background jobs (max \(Self.maxConcurrent))")
        }

        let id = UUID()
        let started = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        if let workingDirectory { proc.currentDirectoryURL = workingDirectory }
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil || env["HOME"]?.isEmpty == true {
            env["HOME"] = NSHomeDirectory()
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let box = ProcessBox(proc)
        try proc.run()
        // Own process group so kill can terminate shell grandchildren safely.
        let pid = proc.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
        }

        DispatchQueue.global().async {
            let h = outPipe.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                box.outBox.append(chunk)
            }
        }
        DispatchQueue.global().async {
            let h = errPipe.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                box.errBox.append(chunk)
            }
        }

        let snap = BackgroundJobSnapshot(
            id: id, kind: .shell, status: .running, command: command,
            output: "", exitCode: nil, startedAt: started, finishedAt: nil,
            conversationID: conversationID)
        jobs[id] = Job(snapshot: snap, box: box, waiter: nil, cancelled: false)

        let waiter = Task { [weak self] in
            guard let self else { return }
            await self.awaitProcess(id: id, box: box, timeout: timeout)
        }
        jobs[id]?.waiter = waiter
        return id
    }

    public func registerSubagent(
        id: UUID = UUID(),
        description: String,
        conversationID: UUID? = nil
    ) throws -> UUID {
        let running = jobs.values.filter { $0.snapshot.status == .running }.count
        guard running < Self.maxConcurrent else {
            throw ToolError.execution("Too many background jobs (max \(Self.maxConcurrent))")
        }
        let snap = BackgroundJobSnapshot(
            id: id, kind: .subagent, status: .running, command: description,
            output: "", exitCode: nil, startedAt: Date(), finishedAt: nil,
            conversationID: conversationID)
        jobs[id] = Job(snapshot: snap, box: nil, waiter: nil, cancelled: false)
        return id
    }

    /// Attach async work for a registered subagent job. The waiter is
    /// cancelled by `kill` (cooperative with SubAgentRunner jobID polls).
    /// Call only once per id; replaces any prior waiter.
    public func attachSubagentWork(
        id: UUID,
        work: @escaping @Sendable () async -> Void
    ) {
        guard jobs[id] != nil else { return }
        let waiter = Task { await work() }
        jobs[id]?.waiter = waiter
    }

    /// Register a subagent job and start background work in one call.
    /// Returns the job id immediately (work runs on a detached waiter Task).
    /// The work closure receives the job id (do not capture an outer `let id`).
    public func startSubagent(
        id: UUID = UUID(),
        description: String,
        conversationID: UUID? = nil,
        work: @escaping @Sendable (_ jobID: UUID) async -> Void
    ) throws -> UUID {
        let jobID = try registerSubagent(
            id: id, description: description, conversationID: conversationID)
        attachSubagentWork(id: jobID) {
            await work(jobID)
        }
        return jobID
    }

    public func isCancelled(_ id: UUID) -> Bool {
        jobs[id]?.cancelled == true || jobs[id]?.snapshot.status == .killed
    }

    public func completeSubagent(id: UUID, output: String, failed: Bool) {
        guard var job = jobs[id] else { return }
        // Already terminal (e.g. kill set .killed) — still attach runner
        // summary when the kill snapshot only has the short "[killed]" tag.
        if job.snapshot.status != .running {
            if job.snapshot.status == .killed, !output.isEmpty {
                let prior = job.snapshot.output
                let priorTrim = prior.trimmingCharacters(in: .whitespacesAndNewlines)
                let needsSummary = priorTrim == "[killed]"
                    || (priorTrim.hasSuffix("[killed]") && priorTrim.count < 64)
                if needsSummary {
                    let merged = output.hasSuffix("[killed]") ? output : (output + "\n[killed]")
                    job.snapshot = BackgroundJobSnapshot(
                        id: id, kind: .subagent, status: .killed,
                        command: job.snapshot.command,
                        output: merged,
                        exitCode: -9,
                        startedAt: job.snapshot.startedAt,
                        finishedAt: job.snapshot.finishedAt ?? Date(),
                        conversationID: job.snapshot.conversationID)
                    jobs[id] = job
                    // Do not re-publish kill wake (already published by kill()).
                }
            }
            return
        }
        let convo = job.snapshot.conversationID
        if job.cancelled {
            job.snapshot = BackgroundJobSnapshot(
                id: id, kind: .subagent, status: .killed,
                command: job.snapshot.command,
                output: output + "\n[killed]",
                exitCode: -9,
                startedAt: job.snapshot.startedAt,
                finishedAt: Date(),
                conversationID: convo)
            jobs[id] = job
            // kill() already published when it set cancelled; if complete
            // ran without kill race, still publish once.
            publishCompletion(job.snapshot)
            return
        }
        job.snapshot = BackgroundJobSnapshot(
            id: id, kind: .subagent,
            status: failed ? .failed : .completed,
            command: job.snapshot.command,
            output: output,
            exitCode: failed ? 1 : 0,
            startedAt: job.snapshot.startedAt,
            finishedAt: Date(),
            conversationID: convo)
        jobs[id] = job
        publishCompletion(job.snapshot)
    }

    /// Snapshot with **live** shell output while running (DataBox is not
    /// copied into the stored snapshot until finalize/kill).
    public func snapshot(_ id: UUID) -> BackgroundJobSnapshot? {
        guard let job = jobs[id] else { return nil }
        return liveSnapshot(job)
    }

    public func listRunning() -> [BackgroundJobSnapshot] {
        jobs.values.map { liveSnapshot($0) }.filter { $0.status == .running }
    }

    public func list(conversationID: UUID) -> [BackgroundJobSnapshot] {
        jobs.values
            .filter { $0.snapshot.conversationID == conversationID }
            .map { liveSnapshot($0) }
    }

    private func liveSnapshot(_ job: Job) -> BackgroundJobSnapshot {
        let s = job.snapshot
        guard s.status == .running, let box = job.box else { return s }
        let live = currentOutput(box)
        guard !live.isEmpty else { return s }
        return BackgroundJobSnapshot(
            id: s.id, kind: s.kind, status: s.status, command: s.command,
            output: live, exitCode: s.exitCode, startedAt: s.startedAt,
            finishedAt: s.finishedAt, conversationID: s.conversationID)
    }

    public func wait(id: UUID, timeoutMs: Int) async -> BackgroundJobSnapshot? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            guard let job = jobs[id] else { return nil }
            let s = liveSnapshot(job)
            if s.status != .running {
                return s
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // Timeout: still return live output so callers see partial progress.
        return jobs[id].map { liveSnapshot($0) }
    }

    public enum WaitMode: String, Sendable {
        case waitAll = "wait_all"
        case waitAny = "wait_any"
    }

    public func waitMany(ids: [UUID], mode: WaitMode, timeoutMs: Int) async -> [BackgroundJobSnapshot] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let snaps = ids.compactMap { jobs[$0].map { liveSnapshot($0) } }
            switch mode {
            case .waitAll:
                if snaps.count == ids.count, snaps.allSatisfy({ $0.status != .running }) {
                    return snaps
                }
            case .waitAny:
                if snaps.contains(where: { $0.status != .running }) {
                    return snaps
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return ids.compactMap { jobs[$0].map { liveSnapshot($0) } }
    }

    /// Progressive subagent transcript preview while still running (UI / get_task_output).
    public func updateSubagentOutput(id: UUID, output: String) {
        guard var job = jobs[id], job.snapshot.status == .running,
              job.snapshot.kind == .subagent else { return }
        let s = job.snapshot
        job.snapshot = BackgroundJobSnapshot(
            id: s.id, kind: .subagent, status: .running, command: s.command,
            output: output, exitCode: nil, startedAt: s.startedAt,
            finishedAt: nil, conversationID: s.conversationID)
        jobs[id] = job
    }

    @discardableResult
    public func kill(_ id: UUID) -> Bool {
        guard var job = jobs[id], job.snapshot.status == .running else { return false }
        job.cancelled = true
        if let box = job.box, box.process.isRunning {
            // Process-group kill so shell grandchildren die too.
            ShellRunner.forceTerminateProcess(box.process)
        }
        job.waiter?.cancel()
        let out = currentOutput(job.box)
        job.snapshot = BackgroundJobSnapshot(
            id: id, kind: job.snapshot.kind, status: .killed,
            command: job.snapshot.command,
            output: out + "\n[killed]",
            exitCode: -9,
            startedAt: job.snapshot.startedAt,
            finishedAt: Date(),
            conversationID: job.snapshot.conversationID)
        job.box = nil
        jobs[id] = job
        publishCompletion(job.snapshot)
        return true
    }

    /// Kill and drop every job (app quit).
    public func cleanup() {
        for (id, job) in jobs where job.snapshot.status == .running {
            _ = kill(id)
        }
        jobs.removeAll()
        pendingCompletions.removeAll()
        publishedCompletionIDs.removeAll()
    }

    /// Kill and drop only jobs owned by `conversationID` (conversation delete).
    public func cleanup(conversationID: UUID) {
        let ids = jobs.values
            .filter { $0.snapshot.conversationID == conversationID }
            .map { $0.snapshot.id }
        for id in ids {
            if jobs[id]?.snapshot.status == .running {
                _ = kill(id)
            }
            jobs.removeValue(forKey: id)
        }
    }

    public func removeFinished() {
        jobs = jobs.filter { $0.value.snapshot.status == .running }
    }


    // MARK: - Completion auto-wake API (PC4)

    /// Subscribe to terminal job completions (push). Callers must keep the
    /// stream alive; termination removes the listener.
    public func subscribeCompletions() -> AsyncStream<BackgroundJobCompletion> {
        let listenerID = UUID()
        return AsyncStream { continuation in
            completionListeners[listenerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeCompletionListener(listenerID) }
            }
        }
    }

    private func removeCompletionListener(_ id: UUID) {
        completionListeners.removeValue(forKey: id)
    }

    /// Drain pending completions for a conversation (or all if nil).
    /// Hosts call this after a turn or on a timer to inject wake notices
    /// into the status line / next parent prompt without missing events.
    public func takePendingCompletions(conversationID: UUID? = nil) -> [BackgroundJobCompletion] {
        let (taken, rest): ([BackgroundJobCompletion], [BackgroundJobCompletion])
        if let conversationID {
            var t: [BackgroundJobCompletion] = []
            var r: [BackgroundJobCompletion] = []
            for c in pendingCompletions {
                if c.conversationID == conversationID || c.conversationID == nil {
                    t.append(c)
                } else {
                    r.append(c)
                }
            }
            (taken, rest) = (t, r)
        } else {
            (taken, rest) = (pendingCompletions, [])
        }
        pendingCompletions = rest
        return taken
    }

    /// Peek without draining (tests / diagnostics).
    public func peekPendingCompletions(conversationID: UUID? = nil) -> [BackgroundJobCompletion] {
        if let conversationID {
            return pendingCompletions.filter {
                $0.conversationID == conversationID || $0.conversationID == nil
            }
        }
        return pendingCompletions
    }

    /// Clear pending wake notices (conversation delete / test setup).
    public func clearPendingCompletions(conversationID: UUID? = nil) {
        if let conversationID {
            pendingCompletions.removeAll {
                $0.conversationID == conversationID || $0.conversationID == nil
            }
        } else {
            pendingCompletions.removeAll()
        }
    }

    /// Publish a terminal snapshot as a parent-visible completion notice.
    private func publishCompletion(_ snapshot: BackgroundJobSnapshot) {
        guard snapshot.status != .running else { return }
        // One wake per job id (kill then completeSubagent must not double-fire).
        guard publishedCompletionIDs.insert(snapshot.id).inserted else { return }
        let notice = BackgroundJobCompletion(snapshot: snapshot)
        pendingCompletions.append(notice)
        while pendingCompletions.count > Self.maxPendingCompletions {
            pendingCompletions.removeFirst()
        }
        for cont in completionListeners.values {
            cont.yield(notice)
        }
        // Depth D4: queue next-iteration inject for the parent model (survives
        // InterjectionBuffer hard-stop clear). Fire-and-forget Task into actor.
        if let convo = snapshot.conversationID {
            let msg = PendingWakeInject.formatWakeMessage(notice)
            Task { await PendingWakeInject.shared.enqueue(conversationID: convo, message: msg) }
        }
    }

    private func currentOutput(_ box: ProcessBox?) -> String {
        guard let box else { return "" }
        let out = String(data: box.outBox.value, encoding: .utf8)
            ?? String(decoding: box.outBox.value, as: UTF8.self)
        let err = String(data: box.errBox.value, encoding: .utf8)
            ?? String(decoding: box.errBox.value, as: UTF8.self)
        if err.isEmpty { return out }
        return out + "\n--- stderr ---\n" + err
    }

    private func awaitProcess(id: UUID, box: ProcessBox, timeout: TimeInterval) async {
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async {
                    box.process.waitUntilExit()
                    g.leave()
                }
                let r = g.wait(timeout: .now() + timeout)
                cont.resume(returning: r == .success)
            }
        }
        finalizeShell(id: id, box: box, timedOut: !ok)
    }

    private func finalizeShell(id: UUID, box: ProcessBox, timedOut: Bool) {
        guard var job = jobs[id], job.snapshot.status == .running else { return }
        if timedOut, box.process.isRunning {
            box.process.terminate()
        }
        let output = currentOutput(box)
        let code = box.process.terminationStatus
        let status: BackgroundJobStatus
        if timedOut { status = .timedOut }
        else if code == 0 { status = .completed }
        else { status = .failed }
        job.snapshot = BackgroundJobSnapshot(
            id: id, kind: .shell, status: status, command: job.snapshot.command,
            output: output, exitCode: code,
            startedAt: job.snapshot.startedAt, finishedAt: Date(),
            conversationID: job.snapshot.conversationID)
        job.box = nil
        jobs[id] = job
        publishCompletion(job.snapshot)
    }
}

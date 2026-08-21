//
//  TurnRunner.swift
//  One AgentLoop.run. Does not grow AgentLoop.swift.
//  SIGINT during a turn cancels the run Task (same contract as
//  ChatViewModel.cancel → runTask?.cancel()). AgentLoop returns a
//  persistable partial conversation with paired tool_calls.
//

import Darwin
import Foundation
import AgentCore

/// Cancels the in-flight `AgentLoop.run` Task. Same handle ChatViewModel
/// uses (`runTask?.cancel()`): the loop checks `Task.isCancelled` and
/// returns rather than throwing.
public final class TurnCancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Conversation, Error>?
    /// SIGINT can arrive after arming and before `attach`.
    private var pending = false

    public init() {}

    public func attach(_ task: Task<Conversation, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = pending
        pending = false
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    public func cancel() {
        lock.lock()
        let t = task
        if t == nil {
            pending = true
        }
        lock.unlock()
        t?.cancel()
    }

    public func detach() {
        lock.lock()
        task = nil
        pending = false
        lock.unlock()
    }
}

/// SIGINT → `TurnCancelHandle.cancel()`, then restore default SIGINT so a
/// second Ctrl+C during unwind (or at `›`) exits the process (K2).
public final class TurnSIGINTSession: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let previous: sig_t?
    private let handle: TurnCancelHandle
    private let lock = NSLock()
    private var restored = false

    init(
        source: DispatchSourceSignal,
        previous: sig_t?,
        handle: TurnCancelHandle
    ) {
        self.source = source
        self.previous = previous
        self.handle = handle
    }

    /// Same path as a delivered SIGINT (tests without a TTY).
    public func deliverForTesting() {
        fire()
    }

    func fire() {
        handle.cancel()
        restore()
    }

    public func restore() {
        lock.lock()
        let already = restored
        restored = true
        let prev = previous
        lock.unlock()
        guard !already else { return }
        source.cancel()
        signal(SIGINT, prev ?? SIG_DFL)
    }
}

public enum TurnSIGINT {
    /// `SIG_IGN` + DispatchSource so the default terminate action does not
    /// fire. First SIGINT cancels the turn **and** restores the previous
    /// disposition immediately (second Ctrl+C is fatal). Caller still
    /// `restore()` on the normal path (idempotent).
    public static func install(cancelling handle: TurnCancelHandle) -> TurnSIGINTSession {
        let previous = signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .global(qos: .userInitiated)
        )
        let session = TurnSIGINTSession(
            source: source,
            previous: previous,
            handle: handle
        )
        source.setEventHandler {
            session.fire()
        }
        source.resume()
        return session
    }
}

public struct TurnRunner: Sendable {
    public var backend: any InferenceBackend
    public var model: ModelDescriptor
    public var settings: AppSettings
    public var maxIterations: Int?
    /// Tests inject these so runTurn does not block on stdin.
    public var patchReviewer: PatchReviewer?
    public var userQuestionReviewer: UserQuestionReviewer?
    public var shellApprovalCoordinator: ShellApprovalCoordinator?

    public init(
        backend: any InferenceBackend,
        model: ModelDescriptor,
        settings: AppSettings,
        maxIterations: Int? = nil,
        patchReviewer: PatchReviewer? = nil,
        userQuestionReviewer: UserQuestionReviewer? = nil,
        shellApprovalCoordinator: ShellApprovalCoordinator? = nil
    ) {
        self.backend = backend
        self.model = model
        self.settings = settings
        self.maxIterations = maxIterations
        self.patchReviewer = patchReviewer
        self.userQuestionReviewer = userQuestionReviewer
        self.shellApprovalCoordinator = shellApprovalCoordinator
    }

    public func runTurn(
        userMessage: String,
        conversation: Conversation,
        cancel: TurnCancelHandle? = nil
    ) async throws -> Conversation {
        let roots: [URL] = [conversation.worktreeRootURL, conversation.projectRoot].compactMap { $0 }
        let safeMode = ExecutionMode.build.enablesSafeMode
            ? settings.safeModeConfig(projectRoots: roots)
            : nil
        let projectKey = conversation.projectRoot?.path ?? conversation.worktreeRootURL?.path
        var prepared = await AgentRunBootstrap.prepareChatRun(
            workerModel: model,
            settings: settings,
            store: ModelSettingsStore.shared,
            xcodeMCPLive: false,
            headless: false,
            safeMode: safeMode,
            patchReviewer: patchReviewer ?? TTYApprovals.patchReviewer(projectKey: projectKey),
            userQuestionReviewer: userQuestionReviewer ?? TTYApprovals.questionReviewer(),
            shellApprovalCoordinator: shellApprovalCoordinator ?? TTYApprovals.shellReviewer(),
            orchestratorBrief: nil,
            executionMode: .build
        )
        if let maxIterations {
            prepared.config.maxIterations = maxIterations
        }
        await ToolRegistry.shared.registerBuiltins()
        let loop = AgentLoop(backend: backend, model: model, config: prepared.config)
        let printer = EventPrinter()

        let handle = cancel ?? TurnCancelHandle()
        let sigint = TurnSIGINT.install(cancelling: handle)
        defer { sigint.restore() }

        let work = Task {
            try await loop.run(
                userMessage: userMessage,
                conversation: conversation,
                sampling: prepared.sampling
            ) { event in
                printer.handle(event)
            }
        }
        handle.attach(work)
        defer { handle.detach() }

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

//
//  AgentRunBootstrap.swift
//
//  Single seam for constructing an agent-loop run from persisted
//  settings + the active worker model. ChatViewModel delegates here so
//  tests exercise the same path the UI uses.
//

import Foundation

public enum AgentRunBootstrap {

    /// Build `AgentLoop.Configuration` and sampling params for one chat turn.
    /// Mirrors the block previously inlined in `ChatViewModel.send`.
    public static func buildLoopConfiguration(
        modelSettings: ModelSettings,
        workerModel: ModelDescriptor,
        settings: AppSettings,
        xcodeMCPLive: Bool,
        headless: Bool,
        safeMode: SafeModeConfig?,
        patchReviewer: PatchReviewer?,
        userQuestionReviewer: UserQuestionReviewer? = nil,
        shellApprovalCoordinator: ShellApprovalCoordinator? = nil,
        orchestratorBrief: String?,
        thinking: ThinkingRequestConfig? = nil,
        samplingOverride: SamplingParams? = nil,
        executionMode: ExecutionMode? = nil
    ) -> (config: AgentLoop.Configuration, sampling: SamplingParams) {
        // Prefer conversation override; else per-model inference settings
        // (including maxTokens). Do not rebuild without maxTokens — the
        // Developer Inference UI persists maxTokens on ModelSettings.
        let sampling = samplingOverride ?? modelSettings.samplingParams()
        let contextBudget = ContextBudget.resolveForChatRun(
            modelSettings: modelSettings.loadSettings,
            workerModel: workerModel,
            maxContextWindowTokens: settings.maxContextWindowTokens,
            compactThresholdPercent: settings.autoCompactThresholdPercent)
        let config = AgentLoop.Configuration(
            maxIterations: headless ? settings.headlessMaxIterations
                                     : settings.maxAgentIterations,
            stallWindow: settings.stallWindow,
            verifyEdits: settings.verifyEdits,
            safeMode: safeMode,
            patchReviewer: patchReviewer,
            userQuestionReviewer: userQuestionReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            disabledToolNames: settings.disabledToolNames,
            contextBudgetTokens: contextBudget,
            hostSystemPrompt: settings.systemPrompt,
            injectProjectMemory: settings.injectProjectMemory,
            memoryEnabled: settings.memoryEnabled,
            dreamEnabled: settings.dreamEnabled,
            fullReplaceCompactEnabled: settings.fullReplaceCompactEnabled,
            headlessMode: headless,
            // Chat mode is interactive-only; headless always runs as agent.
            rawMode: !headless && settings.rawMode,
            orchestratorBrief: orchestratorBrief,
            xcodeMCPEnabled: settings.xcodeMCPEnabled && xcodeMCPLive,
            mcpServers: settings.mcpServers,
            thinking: thinking,
            executionMode: executionMode)
        return (config, sampling)
    }

    /// Exact `ChatViewModel.send` preparation: `applyActivation` then build
    /// loop configuration. Tests and the UI share this path.
    public static func prepareChatRun(
        workerModel: ModelDescriptor,
        settings: AppSettings,
        store: ModelSettingsStore,
        xcodeMCPLive: Bool,
        headless: Bool,
        safeMode: SafeModeConfig?,
        patchReviewer: PatchReviewer?,
        userQuestionReviewer: UserQuestionReviewer? = nil,
        shellApprovalCoordinator: ShellApprovalCoordinator? = nil,
        orchestratorBrief: String?,
        thinking: ThinkingRequestConfig? = nil,
        samplingOverride: SamplingParams? = nil,
        executionMode: ExecutionMode? = nil
    ) async -> (
        config: AgentLoop.Configuration,
        sampling: SamplingParams,
        modelSettings: ModelSettings
    ) {
        let modelSettings = await store.applyActivation(
            modelId: workerModel.id,
            defaults: settings,
            advertised: workerModel.contextLength)
        let built = buildLoopConfiguration(
            modelSettings: modelSettings,
            workerModel: workerModel,
            settings: settings,
            xcodeMCPLive: xcodeMCPLive,
            headless: headless,
            safeMode: safeMode,
            patchReviewer: patchReviewer,
            userQuestionReviewer: userQuestionReviewer,
            shellApprovalCoordinator: shellApprovalCoordinator,
            orchestratorBrief: orchestratorBrief,
            thinking: thinking,
            samplingOverride: samplingOverride,
            executionMode: executionMode)
        return (built.config, built.sampling, modelSettings)
    }
}
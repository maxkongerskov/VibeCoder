//
//  ContextBudget.swift
//
//  Resolves the agent loop's per-request token budget from stored
//  per-model settings, backend-advertised length, and user preferences
//  (max window + auto-compact threshold %).
//

import Foundation

public enum ContextBudget {

    /// Prefer the larger of stored settings and backend-advertised length so
    /// non-catalog OMLX/LM Studio models (e.g. GLM-5.2-mxfp4) reach full window.
    public static func effectiveContextLength(stored: Int, advertised: Int?) -> Int {
        guard let advertised, advertised > 0 else { return stored }
        return max(stored, advertised)
    }

    /// Apply optional user cap (`maxContextWindowTokens`; 0 = no cap).
    public static func cappedWindow(modelWindow: Int, maxContextWindowTokens: Int) -> Int {
        guard maxContextWindowTokens > 0 else { return max(2_048, modelWindow) }
        return max(2_048, min(modelWindow, maxContextWindowTokens))
    }

    /// Budget = threshold% of the (possibly capped) window.
    /// Default 70% matches historical behaviour (reserve headroom for the reply).
    ///
    /// Floor policy (Wave C2 / B10):
    /// - Large windows: floor at 2048 so tiny % values still leave a usable budget.
    /// - Windows ≤ 2048: honor the percent as-is (capped at window) so we never
    ///   force budget == full window and erase reply headroom.
    public static func budgetTokens(
        effectiveContextLength: Int,
        compactThresholdPercent: Double = 70
    ) -> Int {
        let window = max(1, effectiveContextLength)
        let pct = min(100, max(10, compactThresholdPercent)) / 100.0
        let raw = max(1, Int((Double(window) * pct).rounded()))
        if window <= 2_048 {
            return min(window, raw)
        }
        return min(window, max(2_048, raw))
    }

    /// Legacy helper — 70% of effective context.
    public static func budgetTokens(effectiveContextLength: Int) -> Int {
        budgetTokens(effectiveContextLength: effectiveContextLength, compactThresholdPercent: 70)
    }

    public static func resolve(
        storedContextLength: Int,
        advertised: Int?,
        maxContextWindowTokens: Int = 0,
        compactThresholdPercent: Double = 70
    ) -> Int {
        let modelWindow = effectiveContextLength(stored: storedContextLength, advertised: advertised)
        let window = cappedWindow(modelWindow: modelWindow, maxContextWindowTokens: maxContextWindowTokens)
        return budgetTokens(
            effectiveContextLength: window,
            compactThresholdPercent: compactThresholdPercent)
    }

    public static func resolve(storedContextLength: Int, model: ModelDescriptor) -> Int {
        resolve(storedContextLength: storedContextLength, advertised: model.contextLength)
    }

    /// Full resolution for a chat run: model window + user max + compact %.
    public static func resolveForChatRun(
        modelSettings: ModelSettings.LoadSettings,
        workerModel: ModelDescriptor,
        maxContextWindowTokens: Int = 0,
        compactThresholdPercent: Double = 70
    ) -> Int {
        resolve(
            storedContextLength: modelSettings.contextLength,
            advertised: workerModel.contextLength,
            maxContextWindowTokens: maxContextWindowTokens,
            compactThresholdPercent: compactThresholdPercent)
    }

    /// Model window after user max cap (for UI display).
    public static func resolveWindow(
        modelSettings: ModelSettings.LoadSettings,
        workerModel: ModelDescriptor,
        maxContextWindowTokens: Int = 0
    ) -> Int {
        let modelWindow = effectiveContextLength(
            stored: modelSettings.contextLength,
            advertised: workerModel.contextLength)
        return cappedWindow(modelWindow: modelWindow, maxContextWindowTokens: maxContextWindowTokens)
    }
}

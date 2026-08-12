//
//  MLXModelLoadState.swift
//
//  Pure-type, UI-free model of MLX load progress. The DEV PLAN version
//  was an `@MainActor` `ObservableObject` driving SwiftUI; this port
//  strips Combine + main-actor isolation and exposes a value-type
//  snapshot plus the small set of transition methods that callers need.
//
//  Concrete actor / observer integration is a UI concern and lives in
//  the host (VibeCoderApp / AgentCoreApp), not in AgentCore.
//

import Foundation

/// Phase of an MLX model bring-up.
public enum MLXModelLoadPhase: String, Sendable, Codable, Equatable {
    /// Nothing happening.
    case idle
    /// Pulling weights from the Hugging Face Hub (fraction is meaningful).
    case downloading
    /// Weights downloaded; reading them into Metal/RAM (indeterminate).
    case loading
    /// Just finished — brief "landed" state before fading to idle.
    case ready
}

/// Immutable snapshot of MLX load state. A host UI layer can wrap this
/// in an `ObservableObject` (or observe a stream of snapshots) without
/// dragging Combine into AgentCore.
public struct MLXModelLoadState: Sendable, Equatable, Codable {
    public var phase: MLXModelLoadPhase
    /// 0...1 download progress; meaningful only while `phase == .downloading`.
    public var fraction: Double
    /// Friendly name of the model being loaded.
    public var modelName: String

    public init(phase: MLXModelLoadPhase = .idle,
                fraction: Double = 0,
                modelName: String = "") {
        self.phase = phase
        self.fraction = fraction
        self.modelName = modelName
    }

    public static let idle = MLXModelLoadState()

    /// A load just started for `modelId`. Preserves the current
    /// `fraction` when resuming a partial download for the SAME model
    /// (so a watchdog restart doesn't flash N% → 0% → N%).
    public mutating func begin(modelId: String, displayName: String? = nil) {
        let name = displayName ?? modelId
        let resuming = (name == modelName) && (phase == .downloading) && fraction > 0
        modelName = name
        if !resuming { fraction = 0 }
        phase = .downloading
    }

    /// New download progress (clamped). Flips to `.loading` once the
    /// bytes are all on disk.
    public mutating func update(fraction f: Double) {
        fraction = min(max(f, 0), 1)
        if phase == .idle { phase = .downloading }
        if fraction >= 0.999, phase == .downloading { phase = .loading }
    }

    /// Container is live in memory.
    public mutating func markReady() {
        phase = .ready
    }

    /// Reset back to idle.
    public mutating func reset() {
        phase = .idle
        fraction = 0
    }
}

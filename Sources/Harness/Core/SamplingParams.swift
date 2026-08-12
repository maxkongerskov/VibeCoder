//
//  SamplingParams.swift  (Harness)
//
//  Decoding/generation knobs, ported from AgentCore unchanged. The
//  model-class presets encode the hard-won defaults for open-weight models:
//  smaller models want a touch more temperature and a tighter repeat penalty
//  to avoid looping; larger models want less randomness.
//

import Foundation

public struct SamplingParams: Codable, Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var maxTokens: Int?

    public init(temperature: Double = 0.7,
                topP: Double = 0.95,
                topK: Int = 40,
                repeatPenalty: Double = 1.10,
                maxTokens: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
    }

    /// Defaults tuned for code generation: lower temperature, less creative
    /// top-p. The primary default for a coding worker.
    public static let coder = SamplingParams(temperature: 0.3, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    // MARK: - Model-class presets

    /// Small models (≤7B). Higher temperature to compensate for lower
    /// capacity; tighter repeat penalty to reduce looping.
    public static let small = SamplingParams(temperature: 0.4, topP: 0.95, topK: 40, repeatPenalty: 1.10)

    /// Mid-size models (8B–20B). Balanced defaults.
    public static let medium = SamplingParams(temperature: 0.3, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    /// Large models (21B+). Lower temperature — big models are precise enough
    /// that extra randomness hurts more than it helps.
    public static let large = SamplingParams(temperature: 0.2, topP: 0.95, topK: 40, repeatPenalty: 1.05)

    /// Pick the right preset for a model given its parameter count. Falls back
    /// to `.medium` when the count is unknown (0).
    public static func preset(forParameterCountB count: Double) -> SamplingParams {
        switch count {
        case ..<8:   return count == 0 ? .medium : .small
        case 8..<21: return .medium
        default:     return .large
        }
    }
}

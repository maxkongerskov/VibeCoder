//
//  WorkDurationFormat.swift
//
//  Z-Code / BuildCode style elapsed labels:
//  - Under 60s: "… for Ns" / "…s"
//  - At 60s+: switch to whole minutes only ("1 minute", "2 minutes")
//    — never keep climbing seconds after the first minute.
//

import Foundation

enum WorkDurationFormat {
    /// Live or finished working header ("Working for …" / "Worked for …").
    static func workingLabel(seconds: Int, isLive: Bool) -> String {
        let verb = isLive ? "Working for" : "Worked for"
        return "\(verb) \(durationPhrase(seconds: max(seconds, isLive ? 1 : seconds), allowZero: !isLive))"
    }

    /// Compact elapsed for "Thought for …" / "Thinking · …".
    static func shortElapsed(seconds: Int, streaming: Bool) -> String {
        if streaming && seconds <= 0 { return "…" }
        return durationPhrase(seconds: max(seconds, 1), allowZero: false)
    }

    /// "12s" | "1 minute" | "3 minutes"
    static func durationPhrase(seconds: Int, allowZero: Bool) -> String {
        let s = allowZero ? max(0, seconds) : max(1, seconds)
        if s < 60 {
            return "\(s)s"
        }
        let minutes = s / 60
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }
}

//
//  SleepAssertionService.swift
//
//  macOS sleep-prevention wrapper. Holds an `IOPMAssertion` that prevents
//  system sleep while keeping display-dim/sleep behaviour intact — the
//  sane default for "agent runs scheduled tasks overnight."
//
//  Session-only: released on app quit. There's no persistent state on the
//  system after AgentOS exits, so users can't forget they left it on.
//
//  Marked `@MainActor` + `ObservableObject` so SwiftUI views can bind to
//  `isActive` directly. The underlying IOKit calls are thread-safe but
//  keeping the type main-isolated also matches the SwiftUI consumer.
//

import Foundation
import AgentCore
import IOKit
import IOKit.pwr_mgt
import Combine

@MainActor
public final class SleepAssertionService: ObservableObject {

    @Published public private(set) var isActive: Bool = false
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    public init() {}

    /// Turn the assertion on. System will stay awake until `release()` (or
    /// the app quits). Display can still dim/turn off — only system sleep
    /// is prevented.
    public func acquire() {
        guard !isActive else { return }
        let reason = "\(AppBranding.displayName) — scheduled tasks running" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
        }
    }

    /// Release the assertion. Mac is free to sleep again on idle.
    public func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    /// Convenience toggle for UI bindings.
    public func toggle() {
        if isActive { release() } else { acquire() }
    }

    deinit {
        // `assertionID` is a plain value-type (UInt32) — safe to read off the
        // main actor during deinit. IOPMAssertionRelease is thread-safe.
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}

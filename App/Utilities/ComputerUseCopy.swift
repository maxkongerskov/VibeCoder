//
//  ComputerUseCopy.swift
//  Slice 1 — computer-use permission chrome (this Mac, not cloud).
//

import Foundation

/// Settings + chat-chrome honesty copy for computer-use.
/// This Mac. Not cloud. Not a storefront. Not LAN remote.
enum ComputerUseCopy {
    static let settingsTitle = "Computer use"
    static let macLabel = "This Mac"
    static let toggleTitle = "Allow computer use (opt-in)"

    static let intro =
        "Computer use is on this Mac: screenshot, click, type, and scroll. It is not cloud and not a CloudBot. Those actions need your permission. Not phone or LAN remote. Not a storefront."

    static let honesty =
        "macOS also requires Screen Recording (to see the screen) and Accessibility (to click, type, and scroll). Off by default. Screenshots are sent as vision images to the active model endpoint — a loopback /v1 stays on this Mac; a remote /v1 receives the image. A vision-capable model is required to see them. This does not replace your BYO HTTP coding agent."

    static func status(enabled: Bool) -> String {
        enabled
            ? "On. Computer use is this Mac, not cloud. Screenshot, click, type, and scroll still need your permission."
            : "Off (default). The coding agent does not screenshot or move the mouse."
    }

    static let chipHelp =
        "Computer use: this Mac, not cloud. Screenshot and input need your permission."

    static let chipAccessibility =
        "Computer use, this Mac, not cloud."

    static let screenRecordingButton = "Open Screen Recording in System Settings"
    static let accessibilityButton = "Open Accessibility in System Settings"
    static let howTo =
        "Find VibeCoder in the list (or add it), turn it on, then click Check Again."
}

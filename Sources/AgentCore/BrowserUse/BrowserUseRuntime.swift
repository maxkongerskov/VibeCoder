//
//  BrowserUseRuntime.swift
//
//  Isolated this-Mac browser session for the agent. Not desktop
//  computer-use. Not cloud. Not phone/LAN remote.
//  Fail closed when no host driver is installed (CLI / tests without a fake).
//

import Foundation

public enum BrowserUseKind: String, Sendable {
    case thisMac = "this-mac"
}

public struct BrowserPageState: Sendable, Equatable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public struct BrowserSnapshot: Sendable, Equatable {
    public let url: String
    public let title: String
    public let text: String
    public let clickable: String

    public init(url: String, title: String, text: String, clickable: String) {
        self.url = url
        self.title = title
        self.text = text
        self.clickable = clickable
    }
}

public protocol BrowserUseDriver: Sendable {
    func navigate(url: String) async throws -> BrowserPageState
    func snapshot() async throws -> BrowserSnapshot
    func click(selector: String) async throws
    func typeText(selector: String, text: String) async throws
}

/// In-memory driver for tests. Does not load the network or WebKit.
public final class RecordingBrowserUseDriver: BrowserUseDriver, @unchecked Sendable {
    public var currentURL: String = "about:blank"
    public var title: String = ""
    public var text: String = ""
    public var clickable: String = ""
    public var navigated: [String] = []
    public var clicks: [String] = []
    public var typed: [(String, String)] = []

    public init() {}

    public func navigate(url: String) async throws -> BrowserPageState {
        navigated.append(url)
        currentURL = url
        if title.isEmpty { title = url }
        return BrowserPageState(url: currentURL, title: title)
    }

    public func snapshot() async throws -> BrowserSnapshot {
        BrowserSnapshot(url: currentURL, title: title, text: text, clickable: clickable)
    }

    public func click(selector: String) async throws {
        clicks.append(selector)
    }

    public func typeText(selector: String, text: String) async throws {
        typed.append((selector, text))
    }
}

public enum BrowserUseRuntime {
    @TaskLocal public static var driverOverride: (any BrowserUseDriver)?

    public static func install(_ driver: any BrowserUseDriver) {
        installLock.lock()
        installedDriver = driver
        installLock.unlock()
    }

    public static func resetInstalled() {
        installLock.lock()
        installedDriver = nil
        installLock.unlock()
    }

    public static func driver() -> (any BrowserUseDriver)? {
        if let override = driverOverride { return override }
        installLock.lock()
        defer { installLock.unlock() }
        return installedDriver
    }

    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installedDriver: (any BrowserUseDriver)?
}

enum BrowserUseToolSupport {
    static let extras: [String: String] = [
        "kind": BrowserUseKind.thisMac.rawValue,
        "surface": "this-mac-webview",
        "cloud": "false",
        "remote": "false",
        "computer_use": "false",
    ]

    static func denyNoDriver() -> ToolResult {
        ToolResult(
            content: "browser use failed closed: no this-Mac browser host is installed (WKWebView in the app). Not cloud. Not computer-use of the desktop. Not phone/LAN remote.",
            isError: true,
            extras: extras
        )
    }

    static func fail(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true, extras: extras)
    }

    static func ok(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: false, extras: extras)
    }

    static func blockedURL(_ url: String) -> ToolResult {
        ToolResult(
            content: "browser use failed closed: refusing '\(url)' — local or private addresses are blocked. Isolated this-Mac browser, not a LAN remote.",
            isError: true,
            extras: extras
        )
    }
}

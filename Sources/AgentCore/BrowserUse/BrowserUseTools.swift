//
//  BrowserUseTools.swift
//
//  Isolated this-Mac browser: navigate, snapshot (text), click, type.
//  Not desktop computer-use. Not cloud. Fail closed without a host driver.
//

import Foundation

public enum BrowserUseToolNames: Sendable {
    public static let all: Set<String> = [
        BrowserNavigateTool.name,
        BrowserSnapshotTool.name,
        BrowserClickTool.name,
        BrowserTypeTool.name,
    ]
}

public struct BrowserNavigateTool: Tool {
    public static let name = "browser_navigate"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Open a URL in VibeCoder's isolated this-Mac browser (WKWebView, not your \
        desktop Chrome/Safari, not cloud, not phone/LAN remote). Requires the \
        Browser use opt-in. Fails closed on local/private URLs.
        """,
        parameters: .init(
            properties: [
                "url": .init(type: "string", description: "Absolute http:// or https:// URL.")
            ],
            required: ["url"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let driver = BrowserUseRuntime.driver() else {
            return BrowserUseToolSupport.denyNoDriver()
        }
        let raw = (try? arguments.string("url")) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return BrowserUseToolSupport.fail(
                "browser_navigate: requires an absolute http:// or https:// URL")
        }
        if let host = url.host, FetchURLTool.isBlocked(host: host) {
            return BrowserUseToolSupport.blockedURL(trimmed)
        }
        do {
            let page = try await driver.navigate(url: trimmed)
            return BrowserUseToolSupport.ok(
                "browser_navigate ok on this Mac (isolated webview, not cloud): \(page.title) — \(page.url)")
        } catch {
            return BrowserUseToolSupport.fail(
                "browser_navigate failed closed: \(error.localizedDescription)")
        }
    }
}

public struct BrowserSnapshotTool: Tool {
    public static let name = "browser_snapshot"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Read the isolated this-Mac browser: title, URL, visible text, and a short \
        list of clickable elements (CSS selectors). Not a desktop screenshot. \
        Not cloud. Use after browser_navigate.
        """,
        parameters: .init(properties: [:], required: [])
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let driver = BrowserUseRuntime.driver() else {
            return BrowserUseToolSupport.denyNoDriver()
        }
        do {
            let snap = try await driver.snapshot()
            var body = """
            browser_snapshot ok on this Mac (isolated webview, not cloud, not computer-use).
            URL: \(snap.url)
            Title: \(snap.title)

            Visible text:
            \(snap.text)
            """
            if !snap.clickable.isEmpty {
                body += "\n\nClickable:\n\(snap.clickable)"
            }
            return BrowserUseToolSupport.ok(body)
        } catch {
            return BrowserUseToolSupport.fail(
                "browser_snapshot failed closed: \(error.localizedDescription)")
        }
    }
}

public struct BrowserClickTool: Tool {
    public static let name = "browser_click"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Click a CSS selector in the isolated this-Mac browser. Not desktop click. \
        Not cloud. Requires Browser use opt-in and a prior browser_navigate.
        """,
        parameters: .init(
            properties: [
                "selector": .init(
                    type: "string",
                    description: "CSS selector of the element to click."
                )
            ],
            required: ["selector"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let driver = BrowserUseRuntime.driver() else {
            return BrowserUseToolSupport.denyNoDriver()
        }
        let selector = (arguments.stringOptional("selector") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            return BrowserUseToolSupport.fail("browser_click: requires selector")
        }
        do {
            try await driver.click(selector: selector)
            return BrowserUseToolSupport.ok(
                "browser_click ok on this Mac (isolated webview, not cloud) selector=\(selector)")
        } catch {
            return BrowserUseToolSupport.fail(
                "browser_click failed closed: \(error.localizedDescription)")
        }
    }
}

public struct BrowserTypeTool: Tool {
    public static let name = "browser_type"
    public static let category: ToolCategory = .web
    public static let permission: ToolPermission = .network
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Type into a CSS selector in the isolated this-Mac browser. Not desktop type. \
        Not cloud. Requires Browser use opt-in and a prior browser_navigate.
        """,
        parameters: .init(
            properties: [
                "selector": .init(
                    type: "string",
                    description: "CSS selector of the input/textarea."
                ),
                "text": .init(type: "string", description: "Characters to type into the element.")
            ],
            required: ["selector", "text"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let driver = BrowserUseRuntime.driver() else {
            return BrowserUseToolSupport.denyNoDriver()
        }
        let selector = (arguments.stringOptional("selector") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = arguments.stringOptional("text") ?? ""
        guard !selector.isEmpty else {
            return BrowserUseToolSupport.fail("browser_type: requires selector")
        }
        guard !text.isEmpty else {
            return BrowserUseToolSupport.fail("browser_type: requires non-empty text")
        }
        do {
            try await driver.typeText(selector: selector, text: text)
            return BrowserUseToolSupport.ok(
                "browser_type ok on this Mac (isolated webview, not cloud) selector=\(selector) chars=\(text.count)")
        } catch {
            return BrowserUseToolSupport.fail(
                "browser_type failed closed: \(error.localizedDescription)")
        }
    }
}

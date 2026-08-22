//
//  ComputerUseTools.swift
//
//  Agent-callable screenshot / click / type / scroll for THIS Mac.
//  Fail closed if TCC is missing. Do not throw into AgentLoop.
//

import Foundation

public struct ScreenshotTool: Tool {
    public static let name = "screenshot"
    public static let category: ToolCategory = .debug
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Capture the current display on this Mac (not cloud, not phone, not LAN remote). \
        Requires Screen Recording permission. If permission is missing, the tool fails \
        closed with an error — it does not hang or prompt from the agent loop.
        """,
        parameters: ToolSchema.Parameters(
            properties: [:],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let perms = ComputerUseRuntime.permissions()
        guard perms.screenRecording else {
            return ComputerUseToolSupport.denyScreenRecording()
        }
        do {
            let shot = try ComputerUseRuntime.driver().screenshot()
            var msg = "screenshot ok on this Mac (not cloud): \(shot.width)x\(shot.height)"
            if let b64 = shot.pngBase64, !b64.isEmpty {
                msg += "\npng_base64:\n" + b64
            }
            return ComputerUseToolSupport.ok(msg)
        } catch {
            return ComputerUseToolSupport.fail("screenshot failed closed: \(error.localizedDescription)")
        }
    }
}

public struct ClickTool: Tool {
    public static let name = "click"
    public static let category: ToolCategory = .debug
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Click at a screen point on this Mac (not cloud, not LAN remote). \
        Requires Accessibility permission. Fails closed if trust is not granted.
        """,
        parameters: ToolSchema.Parameters(
            properties: [
                "x": .init(type: "integer", description: "Horizontal pixel on this Mac's display."),
                "y": .init(type: "integer", description: "Vertical pixel on this Mac's display."),
                "button": .init(
                    type: "string",
                    description: "left (default) or right.",
                    enum: ["left", "right"]
                )
            ],
            required: ["x", "y"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard ComputerUseRuntime.permissions().accessibility else {
            return ComputerUseToolSupport.denyAccessibility(tool: Self.name)
        }
        guard let x = arguments.intOptional("x"), let y = arguments.intOptional("y") else {
            return ComputerUseToolSupport.fail("click: requires integer x and y")
        }
        let button = (arguments.stringOptional("button") ?? "left")
        do {
            try ComputerUseRuntime.driver().click(x: x, y: y, button: button)
            return ComputerUseToolSupport.ok(
                "click ok on this Mac (not cloud) at (\(x), \(y)) button=\(button)")
        } catch {
            return ComputerUseToolSupport.fail("click failed closed: \(error.localizedDescription)")
        }
    }
}

public struct TypeTool: Tool {
    public static let name = "type"
    public static let category: ToolCategory = .debug
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Type text into the focused UI on this Mac (not cloud, not LAN remote). \
        Requires Accessibility permission. Fails closed if trust is not granted.
        """,
        parameters: ToolSchema.Parameters(
            properties: [
                "text": .init(type: "string", description: "Characters to type on this Mac.")
            ],
            required: ["text"]
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard ComputerUseRuntime.permissions().accessibility else {
            return ComputerUseToolSupport.denyAccessibility(tool: Self.name)
        }
        let text = arguments.stringOptional("text") ?? ""
        guard !text.isEmpty else {
            return ComputerUseToolSupport.fail("type: requires non-empty text")
        }
        do {
            try ComputerUseRuntime.driver().typeText(text)
            return ComputerUseToolSupport.ok(
                "type ok on this Mac (not cloud), \(text.count) characters")
        } catch {
            return ComputerUseToolSupport.fail("type failed closed: \(error.localizedDescription)")
        }
    }
}

public struct ScrollTool: Tool {
    public static let name = "scroll"
    public static let category: ToolCategory = .debug
    public static let permission: ToolPermission = .executes
    public static let availability: ToolAvailability = .core

    public static let schema = ToolSchema(
        name: name,
        description: """
        Scroll the display or a point on this Mac (not cloud, not LAN remote). \
        Requires Accessibility permission. Fails closed if trust is not granted.
        """,
        parameters: ToolSchema.Parameters(
            properties: [
                "x": .init(type: "integer", description: "Cursor x before scrolling (this Mac)."),
                "y": .init(type: "integer", description: "Cursor y before scrolling (this Mac)."),
                "delta_x": .init(type: "integer", description: "Horizontal scroll delta in pixels."),
                "delta_y": .init(type: "integer", description: "Vertical scroll delta in pixels.")
            ],
            required: []
        )
    )

    public init() {}

    public func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard ComputerUseRuntime.permissions().accessibility else {
            return ComputerUseToolSupport.denyAccessibility(tool: Self.name)
        }
        let x = arguments.intOptional("x") ?? 0
        let y = arguments.intOptional("y") ?? 0
        let dx = arguments.intOptional("delta_x") ?? 0
        let dy = arguments.intOptional("delta_y") ?? 0
        do {
            try ComputerUseRuntime.driver().scroll(x: x, y: y, deltaX: dx, deltaY: dy)
            return ComputerUseToolSupport.ok(
                "scroll ok on this Mac (not cloud) at (\(x), \(y)) delta=(\(dx), \(dy))")
        } catch {
            return ComputerUseToolSupport.fail("scroll failed closed: \(error.localizedDescription)")
        }
    }
}

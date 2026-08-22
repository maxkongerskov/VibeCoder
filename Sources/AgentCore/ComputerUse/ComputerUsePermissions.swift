//
//  ComputerUsePermissions.swift
//
//  Slice 1: this-Mac screenshot / click / type / scroll.
//  Fail closed without Screen Recording (screenshot) or Accessibility
//  (click/type/scroll). Not cloud. Not LAN remote.
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Where computer-use tools run. Slice 1 is this Mac only.
public enum ComputerUseKind: String, Sendable {
    case thisMac = "this-mac"
}

public struct ComputerUsePermissionSnapshot: Sendable, Equatable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    public static let denied = ComputerUsePermissionSnapshot(
        screenRecording: false, accessibility: false)
    public static let granted = ComputerUsePermissionSnapshot(
        screenRecording: true, accessibility: true)
}

/// Live TCC preflight. Never prompts (`CGRequestScreenCaptureAccess` /
/// AX prompt options are not called — those hang or pop a sheet).
public enum ComputerUseTCC {
    public static let kind = ComputerUseKind.thisMac

    public static func current() -> ComputerUsePermissionSnapshot {
        #if os(macOS)
        var screen = false
        var ax = false
        #if canImport(CoreGraphics)
        screen = CGPreflightScreenCaptureAccess()
        #endif
        #if canImport(ApplicationServices)
        ax = AXIsProcessTrusted()
        #endif
        return ComputerUsePermissionSnapshot(screenRecording: screen, accessibility: ax)
        #else
        return .denied
        #endif
    }
}

/// Test seam: inject permission + driver without touching the Mac.
public enum ComputerUseRuntime {
    @TaskLocal public static var permissionOverride: ComputerUsePermissionSnapshot?
    @TaskLocal public static var driverOverride: (any ComputerUseDriver)?

    public static func permissions() -> ComputerUsePermissionSnapshot {
        permissionOverride ?? ComputerUseTCC.current()
    }

    public static func driver() -> any ComputerUseDriver {
        driverOverride ?? LiveMacComputerUseDriver()
    }
}

public struct ComputerUseCapture: Sendable {
    public let width: Int
    public let height: Int
    public let pngBase64: String?

    public init(width: Int, height: Int, pngBase64: String? = nil) {
        self.width = width
        self.height = height
        self.pngBase64 = pngBase64
    }
}

public protocol ComputerUseDriver: Sendable {
    func screenshot() throws -> ComputerUseCapture
    func click(x: Int, y: Int, button: String) throws
    func typeText(_ text: String) throws
    func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) throws
}

/// No-op driver for unit tests (does not click the Mac).
public struct RecordingComputerUseDriver: ComputerUseDriver {
    public init() {}
    public func screenshot() throws -> ComputerUseCapture {
        ComputerUseCapture(width: 1, height: 1, pngBase64: nil)
    }
    public func click(x: Int, y: Int, button: String) throws {}
    public func typeText(_ text: String) throws {}
    public func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) throws {}
}

public struct LiveMacComputerUseDriver: ComputerUseDriver {
    public init() {}

    public func screenshot() throws -> ComputerUseCapture {
        #if os(macOS) && canImport(CoreGraphics)
        let display = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(display) else {
            throw ToolError.execution("screenshot: could not capture this Mac display")
        }
        let w = image.width
        let h = image.height
        return ComputerUseCapture(width: w, height: h, pngBase64: nil)
        #else
        throw ToolError.unavailable("screenshot is this-Mac only (not cloud, not Linux CI)")
        #endif
    }

    public func click(x: Int, y: Int, button: String) throws {
        #if os(macOS) && canImport(CoreGraphics)
        let loc = CGPoint(x: x, y: y)
        let isRight = button.lowercased() == "right"
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let cgButton: CGMouseButton = isRight ? .right : .left
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: loc, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: loc, mouseButton: cgButton) else {
            throw ToolError.execution("click: could not build event on this Mac")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        #else
        throw ToolError.unavailable("click is this-Mac only (not cloud)")
        #endif
    }

    public func typeText(_ text: String) throws {
        #if os(macOS) && canImport(CoreGraphics)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ToolError.execution("type: no event source on this Mac")
        }
        for ch in text.unicodeScalars {
            let isReturn = ch == "\n" || ch == "\r"
            let keycode: CGKeyCode = isReturn ? 36 : 0
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else {
                throw ToolError.execution("type: could not build key event")
            }
            if !isReturn {
                var uc = UniChar(ch.value > 0xFFFF ? 0x3F : ch.value)
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uc)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uc)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        #else
        throw ToolError.unavailable("type is this-Mac only (not cloud)")
        #endif
    }

    public func scroll(x: Int, y: Int, deltaX: Int, deltaY: Int) throws {
        #if os(macOS) && canImport(CoreGraphics)
        let loc = CGPoint(x: x, y: y)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: loc, mouseButton: .left) else {
            throw ToolError.execution("scroll: could not move cursor")
        }
        move.post(tap: .cghidEventTap)
        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            throw ToolError.execution("scroll: could not build wheel event")
        }
        ev.post(tap: .cghidEventTap)
        #else
        throw ToolError.unavailable("scroll is this-Mac only (not cloud)")
        #endif
    }
}

enum ComputerUseToolSupport {
    static let kindLabel = "this Mac (not cloud, not LAN remote)"
    static let extras: [String: String] = [
        "kind": ComputerUseKind.thisMac.rawValue,
        "surface": "this-mac",
        "cloud": "false",
        "remote": "false"
    ]

    static func denyScreenRecording() -> ToolResult {
        ToolResult(
            content: "screenshot failed closed: needs Screen Recording permission on this Mac (System Settings → Privacy & Security → Screen Recording). Not cloud. Not remote.",
            isError: true,
            extras: extras
        )
    }

    static func denyAccessibility(tool: String) -> ToolResult {
        ToolResult(
            content: "\(tool) failed closed: needs Accessibility permission on this Mac (System Settings → Privacy & Security → Accessibility). Not cloud. Not remote.",
            isError: true,
            extras: extras
        )
    }

    static func ok(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: false, extras: extras)
    }

    static func fail(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true, extras: extras)
    }
}

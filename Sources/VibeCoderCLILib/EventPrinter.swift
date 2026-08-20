//
//  EventPrinter.swift
//  LoopEvent → stdout/stderr. Color when stderr/stdout is a TTY and
//  NO_COLOR is unset; otherwise the C1 plain text (no escapes).
//

import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct EventPrinter: Sendable {
    private let colorStdout: Bool
    private let colorStderr: Bool
    private let writeStdout: @Sendable (String) -> Void
    private let writeStderr: @Sendable (String) -> Void

    public init() {
        self.init(
            colorStdout: Self.colorEnabled(for: fileno(stdout)),
            colorStderr: Self.colorEnabled(for: fileno(stderr))
        )
    }

    init(
        colorStdout: Bool,
        colorStderr: Bool,
        writeStdout: (@Sendable (String) -> Void)? = nil,
        writeStderr: (@Sendable (String) -> Void)? = nil
    ) {
        self.colorStdout = colorStdout
        self.colorStderr = colorStderr
        self.writeStdout = writeStdout ?? { s in
            fputs(s, stdout)
            fflush(stdout)
        }
        self.writeStderr = writeStderr ?? { s in
            fputs(s, stderr)
            fflush(stderr)
        }
    }

    /// Color when the fd is a TTY and `NO_COLOR` is absent or empty.
    static func colorEnabled(
        for fd: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTTY: ((Int32) -> Bool)? = nil
    ) -> Bool {
        if let v = environment["NO_COLOR"], !v.isEmpty { return false }
        if let isTTY { return isTTY(fd) }
        return isatty(fd) != 0
    }

    public func handle(_ event: LoopEvent) {
        switch event {
        case .contentDelta(let s):
            guard !s.isEmpty else { return }
            writeStdout(paint(s, .token, enabled: colorStdout))
        case .reasoningDelta:
            break
        case .toolStarted(_, let name, let label):
            writeStderr(paint("[\(name)] \(label)\n", .toolStart, enabled: colorStderr))
        case .toolCompleted(_, let name, _, let isError):
            let role: Role = isError ? .toolError : .toolOK
            writeStdout(paint("[\(isError ? "✗" : "✓") \(name)]\n", role, enabled: colorStdout))
        case .toolResult(let inv, let result):
            let mark = result.isError ? "✗" : "✓"
            let role: Role = result.isError ? .toolError : .toolOK
            let preview = result.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            writeStderr(paint("[\(mark) \(inv.name)] \(preview.prefix(120))\n", role, enabled: colorStderr))
        case .buildPassed:
            writeStderr(paint("[build ✓]\n", .buildOK, enabled: colorStderr))
        case .buildFailed(let log):
            writeStderr(paint("[build ✗] \(log.prefix(200))\n", .buildError, enabled: colorStderr))
        case .buildSkipped(let reason):
            writeStderr(paint("[build skip] \(reason)\n", .buildSkip, enabled: colorStderr))
        case .finished(let reason):
            writeStderr(paint("\n[done] \(reason)\n", .done, enabled: colorStderr))
        case .error(let description):
            writeStderr(paint("\n[error] \(description)\n", .error, enabled: colorStderr))
        case .stalled(let sig):
            writeStderr(paint("\n[stalled] \(sig)\n", .stall, enabled: colorStderr))
        case .iterationCapHit(let cap):
            writeStderr(paint("\n[iteration cap \(cap)]\n", .stall, enabled: colorStderr))
        case .info(let msg):
            writeStderr(paint("[info] \(msg)\n", .info, enabled: colorStderr))
        case .pendingQuestion(let q):
            writeStderr(paint("[ask] \(q.question)\n", .ask, enabled: colorStderr))
        default:
            break
        }
    }
}

// MARK: - Roles

private enum Role {
    case token
    case toolStart
    case toolOK
    case toolError
    case buildOK
    case buildError
    case buildSkip
    case ask
    case stall
    case error
    case done
    case info

    /// SGR prefix. Empty = leave the stream's default color (tokens).
    var sgr: String {
        switch self {
        case .token:      return ""
        case .toolStart:  return "\u{001B}[36m"      // cyan
        case .toolOK:     return "\u{001B}[32m"      // green
        case .toolError:  return "\u{001B}[31m"      // red
        case .buildOK:    return "\u{001B}[32m"
        case .buildError: return "\u{001B}[31m"
        case .buildSkip:  return "\u{001B}[33m"      // yellow
        case .ask:        return "\u{001B}[1;33m"    // bold yellow
        case .stall:      return "\u{001B}[33m"
        case .error:      return "\u{001B}[1;31m"    // bold red
        case .done:       return "\u{001B}[32m"
        case .info:       return "\u{001B}[2m"       // dim
        }
    }
}

private let sgrReset = "\u{001B}[0m"

private func paint(_ text: String, _ role: Role, enabled: Bool) -> String {
    guard enabled, !text.isEmpty, !role.sgr.isEmpty else { return text }
    return role.sgr + text + sgrReset
}

//
//  Diagnostics.swift
//
//  Replaces the original AgentOS's 197 `try?` silent-failure sites with a
//  single observable channel. Every failure that the user might care
//  about routes through `Diagnostics.report(...)`. The app subscribes via
//  `Diagnostics.events()` and surfaces the panel; the CLI prints to
//  stderr.
//
//  Why an actor: we expect to be called from every concurrency domain in
//  the codebase. Making this isolated keeps event ordering coherent
//  without locks.
//

import Foundation

public enum DiagnosticSeverity: String, Sendable, Codable {
    case info, warning, error, fatal
}

public struct DiagnosticEvent: Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let source: String        // module/file that reported it
    public let message: String
    public let detail: String?       // multi-line context (stack, JSON, etc.)

    public init(id: UUID = UUID(), timestamp: Date = Date(),
                severity: DiagnosticSeverity, source: String,
                message: String, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.source = source
        self.message = message
        self.detail = detail
    }
}

public actor DiagnosticsHub {
    public static let shared = DiagnosticsHub()

    private var buffer: [DiagnosticEvent] = []
    private let bufferCap = 512
    private var continuations: [UUID: AsyncStream<DiagnosticEvent>.Continuation] = [:]

    public func report(_ event: DiagnosticEvent) {
        buffer.append(event)
        if buffer.count > bufferCap { buffer.removeFirst(buffer.count - bufferCap) }
        for c in continuations.values { c.yield(event) }
        // Always log severe events to stderr so headless surfaces see them.
        if event.severity == .error || event.severity == .fatal {
            FileHandle.standardError.write(Data("[VibeCoder][\(event.severity.rawValue)] \(event.source): \(event.message)\n".utf8))
        }
    }

    public func recent(limit: Int = 100) -> [DiagnosticEvent] {
        Array(buffer.suffix(limit))
    }

    public func events() -> AsyncStream<DiagnosticEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await DiagnosticsHub.shared.detach(id: id) }
            }
        }
    }

    private func detach(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// Convenience facade so calling code doesn't have to know about the
/// actor. The non-blocking shape (`Task` wrapper) makes these legal at
/// any concurrency boundary.
public enum Diagnostics {
    public static func info(_ message: String, source: String = #fileID, detail: String? = nil) {
        emit(.init(severity: .info, source: source, message: message, detail: detail))
    }
    public static func warn(_ message: String, source: String = #fileID, detail: String? = nil) {
        emit(.init(severity: .warning, source: source, message: message, detail: detail))
    }
    public static func error(_ message: String, source: String = #fileID, detail: String? = nil) {
        emit(.init(severity: .error, source: source, message: message, detail: detail))
    }
    public static func fatal(_ message: String, source: String = #fileID, detail: String? = nil) {
        emit(.init(severity: .fatal, source: source, message: message, detail: detail))
    }

    private static func emit(_ event: DiagnosticEvent) {
        Task { await DiagnosticsHub.shared.report(event) }
    }
}

//
//  NotificationService.swift
//
//  Thin wrapper around `UNUserNotificationCenter` for posting completion /
//  halt / budget notifications when the agent finishes work and the user
//  isn't currently looking at AgentOS.
//
//  Authorization is requested lazily on first post. If the user denies, all
//  future calls become no-ops. If AgentOS is the frontmost app, notifications
//  are suppressed unless `bypassFrontmostCheck` (headless / scheduled runs).
//
//  Product S6: interactive turns also notify when the user is **not** looking
//  at the app (turn complete / halt / budget). Headless always bypasses the
//  frontmost check. `enabled` remains the caller master switch.
//

import Foundation
import UserNotifications
import AppKit
import AgentCore

@MainActor
public final class NotificationService {

    public static let shared = NotificationService()

    private enum AuthState { case unknown, allowed, denied }
    private var authState: AuthState = .unknown
    private let center = UNUserNotificationCenter.current()

    private init() {}

    public enum Kind: Sendable {
        case completed(taskSummary: String)
        case looped(signature: String)
        case budgetExceeded(iterations: Int)
        case streamFailed

        var title: String {
            switch self {
            case .completed:        return "\(AppBranding.displayName) task complete"
            case .looped:           return "\(AppBranding.displayName) halted — loop detected"
            case .budgetExceeded:   return "\(AppBranding.displayName) halted — iteration cap reached"
            case .streamFailed:     return "\(AppBranding.displayName) stream failed"
            }
        }

        var body: String {
            switch self {
            case .completed(let summary):
                return summary.isEmpty ? "Your agent finished its work." : summary
            case .looped(let sig):
                let trimmed = sig.count > 120 ? String(sig.prefix(120)) + "…" : sig
                return "Same tool call repeated 3× in a row: \(trimmed)"
            case .budgetExceeded(let n):
                return "Stopped after \(n) iterations. Raise the cap in Settings → Tools if needed."
            case .streamFailed:
                return "The model stream couldn't be recovered after retries."
            }
        }

        /// macOS notification sound. Only the halt/error kinds make a sound;
        /// successful completion is silent so overnight runs don't wake anyone.
        var sound: UNNotificationSound? {
            switch self {
            case .completed:                              return nil
            case .looped, .budgetExceeded, .streamFailed: return .default
            }
        }
    }

    /// Post a notification of the given kind.
    ///
    /// - Parameters:
    ///   - kind: which message to show.
    ///   - enabled: master switch from the caller's settings — false → no-op.
    ///     Pass `AppSettings.notificationsEnabled` (master toggle; default on).
    ///   - bypassFrontmostCheck: when true, post even if AgentOS is the
    ///     frontmost app. Used for explicitly-headless scheduled runs.
    public func notify(_ kind: Kind,
                       enabled: Bool,
                       bypassFrontmostCheck: Bool = false) {
        guard enabled else { return }
        // Skip when the user is already looking at AgentOS — unless this is
        // a headless run where they explicitly want to be pinged regardless.
        if NSApp.isActive && !bypassFrontmostCheck { return }

        Task { [weak self] in
            guard let self else { return }
            await self.ensureAuthorized()
            guard self.authState == .allowed else { return }
            self.post(kind)
        }
    }

    // MARK: - Private

    private func ensureAuthorized() async {
        if authState != .unknown { return }
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authState = .allowed
            return
        case .denied:
            authState = .denied
            return
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authState = granted ? .allowed : .denied
            } catch {
                authState = .denied
            }
        @unknown default:
            authState = .denied
        }
    }

    private func post(_ kind: Kind) {
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = kind.body
        if let sound = kind.sound { content.sound = sound }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Fire immediately.
        )
        center.add(req) { _ in /* fire-and-forget */ }
    }
}

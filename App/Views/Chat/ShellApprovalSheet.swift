//
//  ShellApprovalSheet.swift
//
//  Once / Session / Always / Never approval sheet for shell + MCP asks
//  (Wave B S4 / W09 / Wave U1 permsheet). Fail-closed Deny is also
//  offered as one-shot reject.
//

import SwiftUI
import AgentCore

struct ShellApprovalSheet: View {
    let request: ShellApprovalRequest
    let onDecide: (ShellApprovalDecision) -> Void
    /// Optional origin (subagent type). Falls back to the presenting service.
    var originTag: String? = nil

    @State private var focusedIndex: Int = 0
    @FocusState private var keysActive: Bool

    private var isDangerous: Bool {
        (request.toolName == "run_shell" || request.toolName == "run_shell_command")
            && (request.command.map { SafeBash.isDangerous($0) } ?? false)
    }

    private var title: String {
        if isDangerous { return "Dangerous command" }
        if ToolAuthorization.isMCPToolName(request.toolName) {
            return "Allow MCP tool?"
        }
        switch request.toolName {
        case "run_shell", "run_shell_command":
            return "Allow shell command?"
        case "task":
            return "Allow subagent?"
        default:
            return "Allow \(request.toolName)?"
        }
    }

    private var resolvedOrigin: String? {
        let direct = originTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        let pending = ShellApprovalCoordinatorService.presentedService?.pending?.originTag
        let trimmed = pending?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }

    private var scopeChip: String {
        SessionGrantStore.scopeChipLabel(toolName: request.toolName, command: request.command)
    }

    private var enabledActions: [SheetAction] {
        if isDangerous {
            return [.once, .deny]
        }
        return [.once, .session, .always, .never, .deny]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: isDangerous ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDangerous ? Theme.Palette.error : Theme.Palette.accent)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primary)
                Spacer(minLength: 0)
            }

            Text(request.reason)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let origin = resolvedOrigin {
                Text("Request from subagent: \(origin)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Command / detail mono block
            ScrollView {
                Text(request.detail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.Palette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(10)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                Text("Applies to:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
                Text(scopeChip)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Palette.subtle)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Theme.Palette.divider, lineWidth: 0.5)
                    )
                Spacer(minLength: 0)
            }

            if isDangerous {
                Text("Dangerous commands are never remembered — Always acts as Once.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            // Primary row: Once · Session · Always
            HStack(spacing: 10) {
                actionButton(.once)
                actionButton(.session)
                actionButton(.always)
            }

            // Secondary: Never · Deny
            HStack(spacing: 10) {
                actionButton(.never)
                actionButton(.deny)
            }

            Text("Tool: \(request.toolName)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiary)

            Text("Tab choose · ↩ confirm · Esc deny")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
        .background(Theme.Palette.canvas)
        .focusable()
        .focusEffectDisabled()
        .focused($keysActive)
        .onAppear {
            focusedIndex = 0
            keysActive = true
        }
        .onKeyPress(keys: [.tab], phases: .down) { press in
            moveFocus(press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            moveFocus(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocus(1)
            return .handled
        }
        .onKeyPress(.return) {
            confirmFocused()
            return .handled
        }
        .onKeyPress(.escape) {
            decide(.deny)
            return .handled
        }
        .onExitCommand {
            decide(.deny)
        }
    }

    // MARK: - Actions

    private enum SheetAction: Hashable {
        case once, session, always, never, deny

        var title: String {
            switch self {
            case .once: return "Once"
            case .session: return "Allow for this session"
            case .always: return "Always"
            case .never: return "Never"
            case .deny: return "Deny"
            }
        }
    }

    private func isEnabled(_ action: SheetAction) -> Bool {
        if isDangerous {
            return action == .once || action == .deny
        }
        return true
    }

    private func isFocused(_ action: SheetAction) -> Bool {
        let enabled = enabledActions
        guard enabled.indices.contains(focusedIndex) else { return false }
        return enabled[focusedIndex] == action
    }

    @ViewBuilder
    private func actionButton(_ action: SheetAction) -> some View {
        let enabled = isEnabled(action)
        let focused = isFocused(action)
        let primary = action == .once || action == .session || action == .always
        let label = Text(action.title)
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, primary ? 9 : 8)
            .multilineTextAlignment(.center)
        Group {
            if focused && action != .never {
                Button {
                    guard enabled else { return }
                    choose(action)
                } label: {
                    label
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
            } else {
                Button(role: action == .never ? .destructive : nil) {
                    guard enabled else { return }
                    choose(action)
                } label: {
                    label
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(!enabled)
        .focusable(false)
        .help(helpText(for: action))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Theme.Palette.accent : Color.clear, lineWidth: 1.5)
        )
    }

    private func helpText(for action: SheetAction) -> String {
        switch action {
        case .once:
            return "Allow only this call"
        case .session:
            return isDangerous
                ? "Dangerous shell cannot use session allow"
                : "Remember only until you quit the app"
        case .always:
            return isDangerous
                ? "Dangerous shell cannot use Always allow"
                : "Allow and remember for this project"
        case .never:
            return isDangerous
                ? "Dangerous shell never writes Never grants"
                : "Deny and remember never for this project"
        case .deny:
            return "Deny this call"
        }
    }

    private func moveFocus(_ delta: Int) {
        let count = enabledActions.count
        guard count > 0 else { return }
        let next = (focusedIndex + delta) % count
        focusedIndex = next < 0 ? next + count : next
        keysActive = true
    }

    private func confirmFocused() {
        let enabled = enabledActions
        guard enabled.indices.contains(focusedIndex) else { return }
        choose(enabled[focusedIndex])
    }

    private func choose(_ action: SheetAction) {
        switch action {
        case .once:
            decide(.once)
        case .session:
            decideSession()
        case .always:
            decide(.always)
        case .never:
            decide(.never)
        case .deny:
            decide(.deny)
        }
    }

    private func decide(_ decision: ShellApprovalDecision) {
        onDecide(decision)
    }

    private func decideSession() {
        if let svc = ShellApprovalCoordinatorService.presentedService {
            svc.resolveSession()
        } else {
            onDecide(.once)
        }
    }
}

// MARK: - Previews

#if DEBUG
struct ShellApprovalSheet_Previews: PreviewProvider {
    static var previews: some View {
        ShellApprovalSheet(
            request: ShellApprovalRequest(
                toolName: "run_shell",
                reason: "Ask mode requires approval for 'run_shell'",
                command: "npm install",
                detail: "npm install"
            ),
            onDecide: { _ in }
        )
        .padding()
    }
}
#endif

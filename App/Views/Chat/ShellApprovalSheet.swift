//
//  ShellApprovalSheet.swift
//
//  Minimal Once / Always / Never approval sheet for shell + MCP asks
//  (Wave B S4 / W09). Fail-closed Deny is also offered as one-shot reject.
//

import SwiftUI
import AgentCore

struct ShellApprovalSheet: View {
    let request: ShellApprovalRequest
    let onDecide: (ShellApprovalDecision) -> Void

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

            if isDangerous {
                Text("Dangerous commands are never remembered — Always acts as Once.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            // Primary row: Once · Always
            HStack(spacing: 10) {
                Button {
                    onDecide(.once)
                } label: {
                    Text("Once")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)

                Button {
                    onDecide(.always)
                } label: {
                    Text("Always")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .disabled(isDangerous)
                .help(isDangerous
                      ? "Dangerous shell cannot use Always allow"
                      : "Allow and remember for this project")
            }

            // Secondary: Never · Deny
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    onDecide(.never)
                } label: {
                    Text("Never")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(isDangerous)
                .help(isDangerous
                      ? "Dangerous shell never writes Never grants"
                      : "Deny and remember never for this project")

                Button {
                    onDecide(.deny)
                } label: {
                    Text("Deny")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }

            Text("Tool: \(request.toolName)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
        .background(Theme.Palette.canvas)
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

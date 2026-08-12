//
//  RemoteControlSheet.swift
//
//  QR + shareable link for LAN remote control of the active AgentOS session.
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AgentCore

struct RemoteControlSheet: View {
    @EnvironmentObject private var app: AppViewModel
    var onDismiss: () -> Void = {}

    @State private var sessionURL: URL?
    @State private var errorText: String?
    @State private var isStarting = false

    // Password setup state (first-run only)
    @State private var passwordSetupStep = 0 // 0=show password form, 1=success
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?

    // Tailscale state
    @State private var tailscaleAvailable = false

    @State private var qrImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // ── First-run password setup ─────────────────────────

                    if passwordSetupStep == 0 && !RemoteAccessPasswordStore.shared.isSet() {
                        passwordSetupView
                    }

                    // ── Session block (start / active) ───────────────────

                    if sessionURL != nil {
                        activeSessionView
                    } else if passwordSetupStep == 0 || !RemoteAccessPasswordStore.shared.isSet() {
                        startSessionButton
                    }

                    // ── Status / nudge footer ────────────────────────────

                    statusFooter
                }
                .padding(20)
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 420, idealHeight: 520)
        .background(Theme.Palette.canvas)
        .task { await startSession() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote control")
                    .font(.system(size: 15, weight: .semibold))
                Text("Phone QR · laptop link")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
            }
            Spacer()
            if sessionURL != nil {
                Button("Revoke", role: .destructive) {
                    Task {
                        await RemoteControlServer.shared.revoke()
                        sessionURL = nil
                        qrImage = nil
                    }
                }
            }
            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Password setup view

    private var passwordSetupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set a password for remote access")
                .font(.system(size: 14, weight: .semibold))

            Text("Remote devices will need this password to connect. It is stored locally and never sent over the network.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.system(size: 12))
                SecureField("Enter password (min 6 characters)", text: $newPassword)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm password")
                    .font(.system(size: 12))
                SecureField("Re-enter password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
            }

            if let passwordError {
                Text(passwordError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.error)
            }

            Button {
                Task { await handlePasswordSetup() }
            } label: {
                Text("Set password")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Active session view

    private var activeSessionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan with your phone or open the link on another computer on the same Wi‑Fi. You'll see the live chat and can send messages or stop the agent.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = errorText {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.error)
            }

            if let url = sessionURL {
                qrBlock(url: url)
                linkRow(url: url)
            } else {
                Button {
                    Task { await startSession() }
                } label: {
                    HStack {
                        if isStarting { ProgressView().controlSize(.small) }
                        Text(isStarting ? "Starting…" : "Start remote session")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStarting)
            }
        }
    }

    // MARK: - Start session button (when password not yet configured)

    private var startSessionButton: some View {
        Group {
            // If password is set but no session, show start button.
            if RemoteAccessPasswordStore.shared.isSet() && passwordSetupStep == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session")
                        .font(.system(size: 14, weight: .semibold))

                    if sessionURL == nil {
                        Button {
                            Task { await startSession() }
                        } label: {
                            Text("Start remote session")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: - Status footer with Tailscale nudge

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.tertiary)
                Text("LAN only — both devices must be on the same Wi‑Fi")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.tertiary)
            }

            if !tailscaleAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "tunnel.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.tertiary)
                    Text("Remote outside your home network? Use ")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.tertiary) +
                    Text("Tailscale")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondary) +
                    Text(" to create a secure tunnel between devices.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.tertiary)

                    Button("Learn more") {
                        if let url = URL(string: "https://tailscale.com/download") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                }
            }

            Text("Revoke when you're done. All sessions expire after 1 hour.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.tertiary)
        }
    }

    // MARK: - QR block

    private func qrBlock(url: URL) -> some View {
        VStack(spacing: 10) {
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(url.host ?? "this Mac")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Link row

    private func linkRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Text(url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Actions

    @MainActor
    private func handlePasswordSetup() async {
        guard !newPassword.isEmpty, newPassword.count >= 6 else {
            passwordError = "Password must be at least 6 characters."
            return
        }
        guard newPassword == confirmPassword else {
            passwordError = "Passwords do not match."
            return
        }

        isStarting = true
        passwordError = nil
        defer { isStarting = false }

        do {
            try await RemoteControlServer.shared.setPassword(newPassword)
            passwordSetupStep = 1

            // Reset fields
            newPassword = ""
            confirmPassword = ""

            // Auto-start session after password is set
            await startSession()
        } catch {
            passwordError = error.localizedDescription
        }
    }

    @MainActor
    private func startSession() async {
        isStarting = true
        errorText = nil
        defer { isStarting = false }

        // If no password set yet, do not start — require setup first.
        guard RemoteAccessPasswordStore.shared.isSet() else { return }

        do {
            await app.ensureRemoteControlHostAttached()
            _ = try await RemoteControlServer.shared.start(port: 18765, lifetime: 3600)
            let ip = LANAddress.primaryIPv4() ?? "127.0.0.1"
            guard let url = await RemoteControlServer.shared.sessionURL(hostAddress: ip) else {
                errorText = "Could not build session URL."
                return
            }
            sessionURL = url
            qrImage = QRCodeGenerator.image(from: url.absoluteString, dimension: 440)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Periodic check for Tailscale availability (every 30s).
    @MainActor
    private func checkTailscaleAvailability() async {
        // Check if Tailscale's tunnel device is active.
        let tailscaleBinary = "/opt/homebrew/bin/tailscale"
        let tailscalePath = "/usr/local/bin/tailscale"

        // Simple heuristic: check if Tailscale tunnel is up via system network list.
        tailscaleAvailable = await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                var found = false

                // Try scanning known Tailscale IP ranges on the network.
                if let status = try? String(contentsOf: URL(fileURLWithPath: "/var/db/tailscale.json"), encoding: .utf8) {
                    found = !status.isEmpty
                }

                // Fallback: try running `tailscale status` (if available).
                if !found {
                    let process = Process()
                    let paths: [String] = [tailscaleBinary, tailscalePath, "/usr/bin/tailscale"]
                    for path in paths where FileManager.default.fileExists(atPath: path) {
                        process.launchPath = path
                        process.arguments = ["status"]
                        let output = Pipe()
                        process.standardOutput = output
                        do {
                            try process.run()
                            process.waitUntilExit()
                            if process.terminationStatus == 0 {
                                found = true
                                break
                            }
                        } catch {}
                    }
                }

                continuation.resume(returning: found)
            }
        }
    }
}

// MARK: - LAN address

enum LANAddress {
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback, let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    // Prefer common private ranges; skip link-local if possible.
                    if !ip.hasPrefix("169.254.") {
                        address = ip
                        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { break }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}

// MARK: - QR

enum QRCodeGenerator {
    static func image(from string: String, dimension: CGFloat) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: dimension, height: dimension))
    }
}

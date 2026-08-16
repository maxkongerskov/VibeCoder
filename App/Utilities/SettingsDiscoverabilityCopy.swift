//
//  SettingsDiscoverabilityCopy.swift
//  Polish P2 — pure strings for Settings help (defaults stay honest).
//

import Foundation
import Network
import AgentCore

/// View-layer discoverability copy. Does not change persisted defaults.
enum SettingsDiscoverabilityCopy {
    static let localAPIIntro =
        "Loopback-only OpenAI-compatible server for Xcode Intelligence and other clients on this Mac. Default: completions proxy (tools: []). Optional multi-step agent loop is opt-in below — not Cursor-style Xcode agents by default. No auth token; bind is localhost."

    static let agentToolsToggleTitle = "Agent loop on Local API (opt-in)"

    static let agentToolsHelpDefaultOff =
        "Default: Off (recommended for Xcode). When On, chat completions run a bounded multi-step tool loop (model → tools → model) with a hard iteration cap. Leave Off for Xcode Intelligence. Tools use the same permissions as in-app chat (unsandboxed app)."

    static func agentToolsStatus(enabled: Bool) -> String {
        enabled
            ? "Status: agent loop On — tools execute server-side (capped iterations; not unbounded)."
            : "Status: agent loop off (default) — completions proxy only, tools: []."
    }

    static let seatbeltIntro =
        "Optional write fence for run_shell (sandbox-exec). Default is Auto: on only when Permission mode is Auto. This is not macOS App Sandbox — the app entitlements file is empty (full-trust agent)."

    static func seatbeltCurrent(_ pref: ShellSeatbeltPreference) -> String {
        switch pref {
        case .auto: return "Auto (default) — fence when Permission mode is Auto"
        case .always: return "Always on"
        case .never: return "Off"
        }
    }

    static let grantsIntro =
        "Settings → Tools. Durable Always allow / Never allow from shell and path prompts. Not Permission mode, Safe Mode allow-lists, or shell seatbelt."

    static let grantsEmpty =
        "No Always/Never grants yet. When the agent asks for shell or path approval, choose Always or Never to pin a grant here."
}

struct LoopbackDetectTarget: Equatable, Identifiable, Sendable {
    var id: BackendIdentifier { backend }
    let backend: BackendIdentifier
    let label: String
    let host: String
    let port: Int

    static let defaults: [LoopbackDetectTarget] = [
        .init(backend: .lmStudio, label: "LM Studio", host: "127.0.0.1", port: 1234),
        .init(backend: .ollama, label: "Ollama", host: "127.0.0.1", port: 11434),
        .init(backend: .omlx, label: "oMLX", host: "127.0.0.1", port: 8080),
        .init(backend: .unslothStudio, label: "Unsloth Studio", host: "127.0.0.1", port: 8888),
        .init(backend: .exo, label: "EXO", host: "127.0.0.1", port: 52415),
    ]

    func resolved(from settings: AppSettings) -> LoopbackDetectTarget {
        let host: String
        let port: Int
        switch backend {
        case .lmStudio: host = settings.lmStudioHost; port = settings.lmStudioPort
        case .ollama: host = settings.ollamaHost; port = settings.ollamaPort
        case .omlx: host = settings.omlxHost; port = settings.omlxPort
        case .unslothStudio: host = settings.unslothHost; port = settings.unslothPort
        case .exo: host = settings.exoHost; port = settings.exoPort
        default: return self
        }
        return LoopbackDetectTarget(
            backend: backend,
            label: label,
            host: host.isEmpty ? self.host : host,
            port: port > 0 ? port : self.port
        )
    }
}

enum LoopbackProbeVerdict: Equatable, Sendable {
    /// GET /v1/models returned 200 + a models list, or 401/403 (compat + auth).
    case modelsReady
    /// Something answered HTTP that is not an OpenAI-compat models list.
    case busyNotCompat
    /// Nothing useful (connection refused / timeout).
    case unreachable
}

struct LoopbackDetectHit: Equatable, Identifiable, Sendable {
    var id: BackendIdentifier { target.backend }
    let target: LoopbackDetectTarget
    let verdict: LoopbackProbeVerdict
}

enum LoopbackServerProbe {
    /// Classify an HTTP /v1/models response. TCP-open is never a verdict.
    static func classify(status: Int, body: Data?) -> LoopbackProbeVerdict {
        if status == 401 || status == 403 { return .modelsReady }
        guard status == 200, let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .busyNotCompat }
        if obj["object"] as? String == "list" { return .modelsReady }
        if obj["data"] is [Any] { return .modelsReady }
        return .busyNotCompat
    }

    static func modelsURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host):\(port)/v1/models")
    }

    static func probe(url: URL, timeout: TimeInterval = 0.8) -> LoopbackProbeVerdict {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let box = VerdictBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if error != nil {
                box.value = .unreachable
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 0 {
                box.value = .unreachable
                return
            }
            box.value = classify(status: code, body: data)
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 0.25) == .timedOut {
            task.cancel()
            return .unreachable
        }
        return box.value
    }

    static func scan(
        targets: [LoopbackDetectTarget] = LoopbackDetectTarget.defaults,
        settings: AppSettings
    ) -> [LoopbackDetectHit] {
        targets.map { raw in
            let t = raw.resolved(from: settings)
            let url = modelsURL(host: t.host, port: t.port)
            let verdict = url.map { probe(url: $0) } ?? .unreachable
            return LoopbackDetectHit(target: t, verdict: verdict)
        }
    }

    private final class VerdictBox: @unchecked Sendable {
        var value: LoopbackProbeVerdict = .unreachable
    }
}

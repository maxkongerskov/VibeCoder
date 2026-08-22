//
//  BrowserUseRegistration.swift
//
//  App-hosted isolated WKWebView driver for browser-use tools.
//  AgentCore stays UI-free; the app installs this at boot.
//  This Mac. Not cloud. Not desktop computer-use. Not phone/LAN remote.
//

import Foundation
import WebKit
import AppKit
import AgentCore

enum BrowserUseHostError: Error, LocalizedError {
    case missingElement(String)
    case timeout
    case javascript(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .missingElement(let sel):
            return "no element matching \(sel)"
        case .timeout:
            return "navigation timed out"
        case .javascript(let s):
            return s
        case .notLoaded:
            return "no page loaded — call browser_navigate first"
        }
    }
}

/// Isolated, non-persistent WKWebView session. Hidden off-screen window
/// so JavaScript evaluation is reliable on macOS.
final class WKWebViewBrowserDriver: BrowserUseDriver, @unchecked Sendable {
    private let box: BrowserWebViewBox

    @MainActor
    init() {
        self.box = BrowserWebViewBox()
    }

    func navigate(url: String) async throws -> BrowserPageState {
        guard let parsed = URL(string: url) else {
            throw BrowserUseHostError.javascript("invalid URL")
        }
        try await box.load(parsed)
        return await box.pageState()
    }

    func snapshot() async throws -> BrowserSnapshot {
        try await box.snapshot()
    }

    func click(selector: String) async throws {
        try await box.click(selector: selector)
    }

    func typeText(selector: String, text: String) async throws {
        try await box.type(selector: selector, text: text)
    }
}

@MainActor
private final class BrowserWebViewBox: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var pending: CheckedContinuation<Void, Error>?
    private var inFlight: WKNavigation?
    private var loadGeneration = 0
    private var loaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        self.webView = wv
        let win = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        win.isReleasedWhenClosed = false
        win.isExcludedFromWindowsMenu = true
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        win.contentView = wv
        win.orderOut(nil)
        self.window = win
        super.init()
        wv.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        loaded = false
        loadGeneration += 1
        let generation = loadGeneration
        if let old = pending {
            pending = nil
            inFlight = nil
            old.resume(throwing: BrowserUseHostError.javascript("superseded"))
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending = cont
            inFlight = webView.load(URLRequest(url: url, timeoutInterval: 20))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard generation == loadGeneration, let still = pending else { return }
                pending = nil
                inFlight = nil
                still.resume(throwing: BrowserUseHostError.timeout)
            }
        }
        // Let simple pages paint before snapshot/click.
        try await Task.sleep(nanoseconds: 250_000_000)
        loaded = true
    }

    func pageState() -> BrowserPageState {
        BrowserPageState(
            url: webView.url?.absoluteString ?? "",
            title: webView.title ?? ""
        )
    }

    func snapshot() async throws -> BrowserSnapshot {
        guard loaded else { throw BrowserUseHostError.notLoaded }
        let js = """
        (() => {
          const title = document.title || '';
          const url = location.href || '';
          const text = (document.body && document.body.innerText)
            ? document.body.innerText.slice(0, 8000) : '';
          const nodes = Array.from(document.querySelectorAll(
            'a, button, input, textarea, select, [role="button"], [onclick]'
          )).slice(0, 60);
          const esc = (s) => {
            try { return CSS.escape(s); } catch (e) {
              return String(s).replace(/[^a-zA-Z0-9_-]/g, '');
            }
          };
          const clickable = nodes.map((el, i) => {
            const sel = el.id
              ? ('#' + esc(el.id))
              : (el.name ? (el.tagName.toLowerCase() + '[name="' + String(el.name).replace(/"/g, '') + '"]') : el.tagName.toLowerCase());
            const label = (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 80);
            return (i + 1) + '. ' + sel + (label ? (' — ' + label) : '');
          }).join('\\n');
          return JSON.stringify({title, url, text, clickable});
        })()
        """
        let raw = try await evaluate(js)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let state = pageState()
            return BrowserSnapshot(url: state.url, title: state.title, text: raw, clickable: "")
        }
        return BrowserSnapshot(
            url: obj["url"] as? String ?? pageState().url,
            title: obj["title"] as? String ?? pageState().title,
            text: obj["text"] as? String ?? "",
            clickable: obj["clickable"] as? String ?? ""
        )
    }

    func click(selector: String) async throws {
        guard loaded else { throw BrowserUseHostError.notLoaded }
        let escaped = Self.jsString(selector)
        let js = """
        (() => {
          const el = document.querySelector(\(escaped));
          if (!el) return 'missing';
          el.scrollIntoView({block:'center', inline:'center'});
          el.click();
          return 'ok';
        })()
        """
        let raw = try await evaluate(js)
        if raw != "ok" {
            throw BrowserUseHostError.missingElement(selector)
        }
    }

    func type(selector: String, text: String) async throws {
        guard loaded else { throw BrowserUseHostError.notLoaded }
        let escapedSel = Self.jsString(selector)
        let escapedText = Self.jsString(text)
        let js = """
        (() => {
          const el = document.querySelector(\(escapedSel));
          if (!el) return 'missing';
          el.focus();
          if ('value' in el) {
            el.value = \(escapedText);
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
          } else {
            el.textContent = \(escapedText);
          }
          return 'ok';
        })()
        """
        let raw = try await evaluate(js)
        if raw != "ok" {
            throw BrowserUseHostError.missingElement(selector)
        }
    }

    private func evaluate(_ js: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    cont.resume(throwing: BrowserUseHostError.javascript(error.localizedDescription))
                } else if let s = result as? String {
                    cont.resume(returning: s)
                } else if result == nil {
                    cont.resume(returning: "")
                } else {
                    cont.resume(returning: String(describing: result!))
                }
            }
        }
    }

    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard navigation === inFlight, let p = pending else { return }
            pending = nil
            inFlight = nil
            p.resume()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard navigation === inFlight, let p = pending else { return }
            pending = nil
            inFlight = nil
            p.resume(throwing: error)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            guard navigation === inFlight, let p = pending else { return }
            pending = nil
            inFlight = nil
            p.resume(throwing: error)
        }
    }
}

enum BrowserUseRegistration {
    @MainActor
    static func install() {
        BrowserUseRuntime.install(WKWebViewBrowserDriver())
    }
}

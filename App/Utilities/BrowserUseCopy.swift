//
//  BrowserUseCopy.swift
//  Isolated this-Mac browser (WKWebView). Not computer-use. Not cloud.
//

import Foundation

enum BrowserUseCopy {
    static let settingsTitle = "Browser use"
    static let macLabel = "This Mac"
    static let toggleTitle = "Allow isolated browser (opt-in)"

    static let intro =
        "Browser use is an isolated webview on this Mac: navigate, read the page, click, and type by CSS selector. Those actions need the Browser use permission toggle. It is not desktop computer use, not a CloudBot, and not phone or LAN remote. Not a storefront."

    static let honesty =
        "Off by default. Pages load in a non-persistent WKWebView, not Safari/Chrome. Local and private addresses are blocked. This does not replace fetch_url for simple reads, and it does not screenshot the desktop."

    static func status(enabled: Bool) -> String {
        enabled
            ? "On. Isolated this-Mac browser, not cloud. Navigate / snapshot / click / type still need this opt-in."
            : "Off (default). The coding agent does not drive a browser."
    }
}

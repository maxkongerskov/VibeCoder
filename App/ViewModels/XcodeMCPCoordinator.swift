//
//  XcodeMCPCoordinator.swift
//
//  Xcode MCP bridge connection lifecycle.
//

import Foundation
import AgentCore

@MainActor
final class XcodeMCPCoordinator: ObservableObject {

    @Published var status: XcodeMCPConnectionStatus = .disconnected

    func start() async {
        status = .connecting
        await XcodeMCPBridge.shared.connect()
        status = await XcodeMCPBridge.shared.connectionStatus()
    }

    func stop() async {
        await XcodeMCPBridge.shared.disconnect()
        status = .disconnected
    }

    func reconnect() async {
        status = .connecting
        await XcodeMCPBridge.shared.reconnect()
        status = await XcodeMCPBridge.shared.connectionStatus()
    }

    var isLive: Bool {
        status.isConnected
    }
}
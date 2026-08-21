//
//  CloudBotHostTests.swift
//
//  Slice 0 characterization: CloudBot host stub cannot be read as local
//  inference. Kind/label is cloud, default off, no marketplace, does not
//  replace AgentLoop, disabled stub does not send.
//

import XCTest
@testable import AgentCore

final class CloudBotHostTests: XCTestCase {

    func testDefaultDisabled() {
        let host = CloudBotHost()
        XCTAssertFalse(host.isEnabled)
        XCTAssertFalse(host.canSend)
        XCTAssertFalse(AppSettings().cloudBotsEnabled)
        XCTAssertFalse(AppSettings().cloudBotHost.isEnabled)
        XCTAssertEqual(host.kind, .cloud)
    }

    func testKindAndLabelAreCloud() {
        let host = CloudBotHost()
        let handle = host.makeHandle(id: "atlas", name: "Atlas")
        XCTAssertEqual(host.kind, .cloud)
        XCTAssertEqual(handle.kind, .cloud)
        XCTAssertEqual(CloudBot.Kind.cloud.rawValue, "cloud")
        XCTAssertEqual(CloudBotHost.cloudLabel, "Cloud")
        XCTAssertEqual(handle.kind.rawValue, CloudBotHost.cloudLabel.lowercased())
    }

    func testKindIsNotALocalBackend() {
        let raw = CloudBot.Kind.cloud.rawValue
        XCTAssertNotEqual(raw, BackendIdentifier.lmStudio.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.omlx.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.ollama.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.unslothStudio.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.exo.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.custom.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.mlx.rawValue)
        XCTAssertNotEqual(raw, BackendIdentifier.xai.rawValue)
        XCTAssertNil(BackendIdentifier(rawValue: "cloud"))
    }

    func testNoMarketplaceURL() {
        XCTAssertNil(CloudBotHost.marketplaceURL)
    }

    func testDoesNotReplaceAgentLoopOrLocalInference() {
        XCTAssertFalse(CloudBotHost.replacesAgentLoop)
        XCTAssertFalse(CloudBotHost.replacesLocalInference)
    }

    func testConstructingHandleDoesNotStartAgentLoop() {
        let host = CloudBotHost()
        let handle = host.makeHandle(id: "mira", name: "Mira")
        XCTAssertEqual(handle.id, "mira")
        XCTAssertEqual(handle.name, "Mira")
        XCTAssertEqual(handle.kind, .cloud)
        XCTAssertFalse(CloudBotHost.replacesAgentLoop)
        XCTAssertFalse(host.canSend)
    }

    func testDirectHandleInitIsCloud() {
        let handle = CloudBot.Handle(id: "sable", name: "Sable")
        XCTAssertEqual(handle.kind, .cloud)
        XCTAssertEqual(handle.id, "sable")
    }

    func testDisabledStubDoesNotSend() async {
        let host = CloudBotHost()
        let handle = host.makeHandle(id: "nash", name: "Nash")
        do {
            try await host.send("hello", as: handle)
            XCTFail("disabled stub must not send")
        } catch let error as CloudBotHostError {
            XCTAssertEqual(error, .disabled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(host.canSend)
    }

    func testEnabledStubStillDoesNotSend() async {
        let host = CloudBotHost(enabled: true)
        XCTAssertTrue(host.isEnabled)
        XCTAssertFalse(host.canSend, "slice 0 has no runtime even when opted in")
        let handle = host.makeHandle(id: "reed", name: "Reed")
        do {
            try await host.send("hello", as: handle)
            XCTFail("stub must not send")
        } catch let error as CloudBotHostError {
            XCTAssertEqual(error, .stubNotImplemented)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSettingsFlagHooksHost() {
        var settings = AppSettings()
        XCTAssertFalse(CloudBotHost(settings: settings).isEnabled)
        settings.cloudBotsEnabled = true
        let host = CloudBotHost(settings: settings)
        XCTAssertTrue(host.isEnabled)
        XCTAssertEqual(host.kind, .cloud)
        XCTAssertFalse(host.canSend)
        XCTAssertTrue(settings.cloudBotHost.isEnabled)
    }

    func testWorktreeUsesAgentcorePrefix() {
        let id = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000001")!
        let branch = CloudBotHost.worktreeBranch(for: id)
        XCTAssertTrue(branch.hasPrefix(CloudBotHost.worktreeBranchPrefix))
        XCTAssertEqual(branch, "agentcore/" + WorktreeService.conversationShortId(from: id))
        XCTAssertEqual(CloudBotHost.worktreeBranchPrefix, "agentcore/")
    }
}

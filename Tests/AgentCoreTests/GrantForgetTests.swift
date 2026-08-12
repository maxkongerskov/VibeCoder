//
//  GrantForgetTests.swift
//
//  Polish P1 — single-key forget on RememberedGrants + DurableGrantStore.
//

import XCTest
@testable import AgentCore

final class GrantForgetTests: XCTestCase {

    private var tempDir: URL!
    private var durableURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-forget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        durableURL = tempDir.appendingPathComponent("durable-grants.json")
        await RememberedGrants.shared.clear()
    }

    override func tearDown() async throws {
        await RememberedGrants.shared.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testForgetRemovesProcessAndLeavesOthers() async {
        let keep = GrantKey(projectKey: "/proj", toolName: "write_file")
        let drop = GrantKey(
            projectKey: "/proj",
            toolName: "run_shell",
            commandFingerprint: "npm install"
        )
        await RememberedGrants.shared.remember(.never, for: keep)
        await RememberedGrants.shared.remember(.allow, for: drop)

        let removed = await RememberedGrants.shared.forget(drop)
        XCTAssertTrue(removed)
        let dropAfter = await RememberedGrants.shared.decision(for: drop)
        let keepAfter = await RememberedGrants.shared.decision(for: keep)
        XCTAssertNil(dropAfter)
        XCTAssertEqual(keepAfter, .never)

        let again = await RememberedGrants.shared.forget(drop)
        XCTAssertFalse(again)
    }

    func testDurableForgetPersistsAcrossStoreReload() async throws {
        let storeA = DurableGrantStore(fileURL: durableURL)
        let a = GrantKey(projectKey: "/p", toolName: "edit_file")
        let b = GrantKey(projectKey: "/p", toolName: "delete_file")
        await storeA.remember(.allow, for: a)
        await storeA.remember(.never, for: b)

        let forgot = await storeA.forget(a)
        XCTAssertTrue(forgot)
        let aGone = await storeA.decision(for: a)
        let bKept = await storeA.decision(for: b)
        let persistOK = await storeA.lastPersistSucceeded()
        XCTAssertNil(aGone)
        XCTAssertEqual(bKept, .never)
        XCTAssertTrue(persistOK)

        // New actor instance reloads from disk — forget must stick.
        let storeB = DurableGrantStore(fileURL: durableURL)
        let aReload = await storeB.decision(for: a)
        let bReload = await storeB.decision(for: b)
        let snap = await storeB.snapshot(projectKey: "/p")
        XCTAssertNil(aReload)
        XCTAssertEqual(bReload, .never)
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[b], .never)
    }

    func testRememberedForgetSyncsDurable() async throws {
        let keep = GrantKey(projectKey: "/ui", toolName: "read_file")
        let drop = GrantKey(projectKey: "/ui", toolName: "run_shell",
                            commandFingerprint: "git status")
        await RememberedGrants.shared.remember(.allow, for: keep)
        await RememberedGrants.shared.remember(.never, for: drop)

        _ = await RememberedGrants.shared.forget(drop)

        // Shared durable should not rehydrate the dropped key after load.
        await DurableGrantStore.shared.loadIntoRememberedGrants()
        let dropAfter = await RememberedGrants.shared.decision(for: drop)
        let keepAfter = await RememberedGrants.shared.decision(for: keep)
        let durableDrop = await DurableGrantStore.shared.decision(for: drop)
        XCTAssertNil(dropAfter)
        XCTAssertEqual(keepAfter, .allow)
        XCTAssertNil(durableDrop)
    }

    func testForgetDoesNotClearOtherProjects() async {
        let p1 = GrantKey(projectKey: "/one", toolName: "edit_file")
        let p2 = GrantKey(projectKey: "/two", toolName: "edit_file")
        await RememberedGrants.shared.remember(.allow, for: p1)
        await RememberedGrants.shared.remember(.allow, for: p2)
        _ = await RememberedGrants.shared.forget(p1)
        let d1 = await RememberedGrants.shared.decision(for: p1)
        let d2 = await RememberedGrants.shared.decision(for: p2)
        XCTAssertNil(d1)
        XCTAssertEqual(d2, .allow)
    }
}

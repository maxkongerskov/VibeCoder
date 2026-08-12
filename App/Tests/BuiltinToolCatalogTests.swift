//
//  BuiltinToolCatalogTests.swift
//  Wave C: Settings Tools tab must list every ToolRegistry builtin.
//

import XCTest
@testable import VibeCoderApp
@testable import AgentCore

final class BuiltinToolCatalogTests: XCTestCase {

    func testSettingsCatalogCoversRegisteredBuiltinNames() {
        let settingsNames = BuiltinToolCatalog.settingsNames
        let expected = BuiltinToolCatalog.allRegisteredNames
        let missing = expected.subtracting(settingsNames)
        XCTAssertTrue(
            missing.isEmpty,
            "Settings Tools tab missing registered tools: \(missing.sorted())"
        )
    }

    func testSettingsCatalogHasNoOrphanNames() {
        let settingsNames = BuiltinToolCatalog.settingsNames
        let expected = BuiltinToolCatalog.allRegisteredNames
        let orphans = settingsNames.subtracting(expected)
        XCTAssertTrue(
            orphans.isEmpty,
            "Settings lists tools not in builtins+app-hosted catalog: \(orphans.sorted())"
        )
    }

    func testPrimaryEditToolIsListed() {
        XCTAssertTrue(BuiltinToolCatalog.settingsNames.contains("edit_file"))
        XCTAssertTrue(BuiltinToolCatalog.settingsNames.contains("load_skill"))
        XCTAssertTrue(BuiltinToolCatalog.settingsNames.contains("task"))
    }

    func testPDFToolsListedInSettings() {
        for name in PDFToolRegistration.toolNames {
            XCTAssertTrue(
                BuiltinToolCatalog.settingsNames.contains(name),
                "Settings missing PDF tool \(name)"
            )
        }
        XCTAssertEqual(
            BuiltinToolCatalog.appHostedToolNames,
            PDFToolRegistration.toolNames
        )
    }

    /// Live registry cross-check (not just the mirrored set).
    func testCatalogMatchesLiveRegisterBuiltins() async {
        await ToolRegistry.shared.registerBuiltins()
        await PDFToolRegistration.register()
        let live = await ToolRegistry.shared.registeredNames()
        let catalog = BuiltinToolCatalog.allRegisteredNames
        // Builtins + app-hosted PDF tools must all be registered after boot registration.
        let notRegistered = catalog.subtracting(live)
        XCTAssertTrue(
            notRegistered.isEmpty,
            "Catalog names not registered: \(notRegistered.sorted())"
        )
        // Live may include extra dynamic tools (e.g. Xcode MCP); require catalog ⊆ live
        // for the names we claim to ship in Settings.
        let missingFromSettings = catalog.subtracting(BuiltinToolCatalog.settingsNames)
        XCTAssertTrue(
            missingFromSettings.isEmpty,
            "Catalog names missing from Settings list: \(missingFromSettings.sorted())"
        )
    }

    func testPDFCoreAndDeferredAvailability() async {
        await ToolRegistry.shared.registerBuiltins()
        await PDFToolRegistration.register()
        for name in PDFToolRegistration.coreToolNames {
            let meta = await ToolRegistry.shared.metadata(for: name)
            XCTAssertNotNil(meta, "Missing core PDF tool \(name)")
            if let meta {
                if case .core = meta.availability { } else {
                    XCTFail("\(name) should be .core")
                }
                XCTAssertNotEqual(meta.permission, .network)
            }
        }
        for name in PDFToolRegistration.deferredToolNames {
            let meta = await ToolRegistry.shared.metadata(for: name)
            XCTAssertNotNil(meta, "Missing deferred PDF tool \(name)")
            if let meta {
                if case .deferred = meta.availability { } else {
                    XCTFail("\(name) should be .deferred")
                }
                XCTAssertNotEqual(meta.permission, .network)
            }
        }
    }
}

//
//  ClusterPaneUITests.swift
//
//  EXO Cluster pane (b7db51f): mounts only on EXO (sidebar + palette),
//  read-only /state + pin Model ID, no cluster write/start/stop,
//  leftover RemoteControlSheet is gone. Not SwiftUI hit-testing.
//  Does not grow AgentLoop or ChatViewModel.
//

import XCTest
import AgentCore
@testable import VibeCoderApp

final class ClusterPaneUITests: XCTestCase {

    // MARK: - Sidebar mount (EXO-only)

    func testClusterMountsOnlyWhenEXOBackend() {
        XCTAssertEqual(
            SidebarTab.sidebarTabs,
            [.chat, .projects, .models, .notes, .scheduled]
        )
        XCTAssertFalse(SidebarTab.sidebarTabs.contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .lmStudio).contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .ollama).contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .unslothStudio).contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .omlx).contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .mlx).contains(.cluster))
        XCTAssertFalse(SidebarTab.sidebarTabs(for: .custom).contains(.cluster))
        XCTAssertEqual(
            SidebarTab.sidebarTabs(for: .exo),
            [.chat, .projects, .models, .cluster, .notes, .scheduled]
        )
    }

    func testZCodeSidebarNavUsesBackendFilteredTabs() throws {
        let src = try appSource("Views/Sidebar/ZCodeSidebar.swift")
        XCTAssertTrue(
            src.contains("SidebarTab.sidebarTabs(for: app.settings.backend)"),
            "ZCodeSidebar primaryNav must follow the active backend"
        )
    }

    // MARK: - Palette (EXO-gated)

    func testCommandPaletteClusterItemIsEXOGated() throws {
        let root = try appSource("Views/RootView.swift")
        guard let itemRange = root.range(of: "id: \"open-cluster\"") else {
            return XCTFail("RootView palette is missing open-cluster")
        }
        let gateStart = root.index(itemRange.lowerBound, offsetBy: -350, limitedBy: root.startIndex)
            ?? root.startIndex
        let gateWindow = String(root[gateStart..<itemRange.upperBound])
        XCTAssertTrue(
            gateWindow.contains("app.settings.backend == .exo"),
            "open-cluster must be appended only when EXO is selected"
        )
        XCTAssertTrue(root.contains("title: \"Cluster\""))
        XCTAssertTrue(root.contains("EXO topology (/state) and pin Model ID"))
        guard let run = root.range(of: "case \"open-cluster\":") else {
            return XCTFail("palette runner missing open-cluster")
        }
        let runEnd = root.index(run.upperBound, offsetBy: 80, limitedBy: root.endIndex) ?? root.endIndex
        XCTAssertTrue(
            String(root[run.upperBound..<runEnd]).contains("selectedTab = .cluster"),
            "palette Cluster must select the cluster tab"
        )
    }

    func testRootViewMountsClusterViewOnClusterTab() throws {
        let root = try appSource("Views/RootView.swift")
        XCTAssertTrue(root.contains("case .cluster:"), "RootView must mount the Cluster pane")
        XCTAssertTrue(
            root.contains("ClusterView(host: app.settings.exoHost, port: app.settings.exoPort)")
        )
        XCTAssertTrue(
            root.contains("if selectedTab == .cluster && backend != .exo"),
            "leaving EXO must bounce off the Cluster tab"
        )
    }

    // MARK: - Read-only /state + pin Model ID

    @MainActor
    func testClusterViewModelIsReadOnlyTopologyPoller() async {
        let vm = ClusterViewModel(host: "127.0.0.1", port: 52415)
        XCTAssertEqual(vm.state, .loading)
        XCTAssertEqual(vm.catalog, .idle)
        // refresh() is a no-op until start() constructs EXOBackend — do not
        // call start() here (that would hit the network).
        await vm.refresh()
        XCTAssertEqual(vm.state, .loading)
        vm.stop()
        XCTAssertEqual(vm.catalog, .idle)
    }

    func testClusterSourcesAreReadOnlyStateAndPinModelID() throws {
        let clusterView = try appSource("Views/Cluster/ClusterView.swift")
        let clusterVM = try appSource("Views/Cluster/ClusterViewModel.swift")

        XCTAssertTrue(clusterView.contains("/state"), "Cluster reads EXO /state")
        XCTAssertTrue(clusterVM.contains("/state"), "ClusterViewModel documents /state polling")
        XCTAssertTrue(clusterVM.contains("fetchTopology"), "topology comes from EXOBackend.fetchTopology")
        XCTAssertTrue(clusterVM.contains("fetchCatalog"), "catalog is GET /models")
        XCTAssertTrue(clusterView.contains("app.pinEXOModel(model.id)"), "Pin copies Model ID into settings")
        XCTAssertTrue(clusterView.contains("Text(\"Pin\")"))
        XCTAssertTrue(
            clusterView.contains("You load models in EXO itself — Pin just copies")
                || clusterView.contains("Pin this as the EXO Model ID"),
            "Pin is a local Model ID, not a cluster write"
        )

        for (name, src) in [("ClusterView", clusterView), ("ClusterViewModel", clusterVM)] {
            XCTAssertFalse(src.contains("httpMethod"), "\(name) must not set HTTP methods")
            XCTAssertFalse(src.contains("\"POST\""), "\(name) is not a write client")
            XCTAssertFalse(src.contains("\"PUT\""), "\(name) is not a write client")
            XCTAssertFalse(src.contains("\"DELETE\""), "\(name) is not a write client")
            XCTAssertFalse(src.contains("startInstance"), "\(name) must not start cluster nodes")
            XCTAssertFalse(src.contains("stopInstance"), "\(name) must not stop cluster nodes")
            XCTAssertFalse(src.contains("/start"), "\(name) must not hit start endpoints")
            XCTAssertFalse(src.contains("/stop"), "\(name) must not hit stop endpoints")
            XCTAssertFalse(src.contains("loadModel"), "\(name) must not load on the cluster")
            XCTAssertFalse(src.contains("unloadModel"), "\(name) must not unload on the cluster")
        }
    }

    @MainActor
    func testPinEXOModelSelectsTrimmedID() {
        let coord = BackendConnectionCoordinator()
        coord.pinEXOModel("  mlx-community/MiniMax-M2.7-4bit  ")
        XCTAssertEqual(coord.selectedModelID, "mlx-community/MiniMax-M2.7-4bit")
        XCTAssertEqual(coord.availableModels.map(\.id), ["mlx-community/MiniMax-M2.7-4bit"])
        XCTAssertEqual(coord.availableModels.first?.backend, .exo)
    }

    @MainActor
    func testPinEXOModelIgnoresBlank() {
        let coord = BackendConnectionCoordinator()
        coord.selectedModelID = "keep"
        coord.pinEXOModel("   \n")
        XCTAssertEqual(coord.selectedModelID, "keep")
        XCTAssertTrue(coord.availableModels.isEmpty)
    }

    // MARK: - No write / start / stop controls

    func testClusterViewHasNoStartStopLoadUnloadControls() throws {
        let view = try appSource("Views/Cluster/ClusterView.swift")
        XCTAssertFalse(view.contains("Text(\"Start\")"))
        XCTAssertFalse(view.contains("Text(\"Stop\")"))
        XCTAssertFalse(view.contains("Text(\"Unload\")"))
        XCTAssertFalse(view.contains("Text(\"Load\")"))
        XCTAssertFalse(view.contains("Text(\"Use on cluster\")"))
        XCTAssertEqual(
            view.components(separatedBy: "Text(\"Pin\")").count - 1,
            1,
            "only the Pin control should be a labeled action"
        )
    }

    // MARK: - RemoteControlSheet deleted

    func testRemoteControlSheetIsGone() throws {
        let sheet = appRoot.appendingPathComponent("Views/Chat/RemoteControlSheet.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sheet.path),
            "RemoteControlSheet.swift leftover must be deleted"
        )
        let found = leftoverRemoteControlSheets(under: appRoot.appendingPathComponent("Views"))
        XCTAssertTrue(found.isEmpty, "RemoteControlSheet.swift still on disk: \(found)")

        let root = try appSource("Views/RootView.swift")
        XCTAssertFalse(root.contains("RemoteControlSheet"))
        let cluster = try appSource("Views/Cluster/ClusterView.swift")
        XCTAssertFalse(cluster.contains("RemoteControlSheet"))
        let pbx = try String(
            contentsOf: appRoot.appendingPathComponent("VibeCoder.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertFalse(pbx.contains("RemoteControlSheet"))
    }

    // MARK: - Source helpers (characterization, not XCUI)

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func leftoverRemoteControlSheets(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var hits: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "RemoteControlSheet.swift" {
                hits.append(url.path)
            }
        }
        return hits
    }
}

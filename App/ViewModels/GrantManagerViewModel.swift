//
//  GrantManagerViewModel.swift
//
//  Phase C PC1 — list / revoke Always·Never grants and surface
//  PermissionRules source paths. Uses public RememberedGrants +
//  DurableGrantStore + PermissionRules APIs only.
//

import Foundation
import AgentCore

@MainActor
final class GrantManagerViewModel: ObservableObject {

    @Published private(set) var items: [GrantListItem] = []
    @Published private(set) var rulesSourcePaths: [String] = []
    @Published private(set) var rulesSummaryText: String = ""
    @Published private(set) var fileGrantCount: Int = 0
    @Published private(set) var ruleCount: Int = 0
    @Published private(set) var persistError: String?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusMessage: String?

    /// Open project root (for PermissionRules.load). Optional.
    var projectRoot: URL?

    init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot
    }

    /// Reload durable → process memory, then list all remembered grants.
    func reload() async {
        isBusy = true
        defer { isBusy = false }
        await DurableGrantStore.shared.loadIntoRememberedGrants()
        let entries = await RememberedGrants.shared.allEntries()
        items = GrantManagerFormatting.items(from: entries)
        persistError = await DurableGrantStore.shared.lastPersistError()

        let snap = PermissionRules.load(
            projectRoot: projectRoot,
            includeHome: true,
            includeClaudeSettings: true
        )
        rulesSourcePaths = snap.sourcePaths
        ruleCount = snap.rules.count
        fileGrantCount = snap.grants.count
        rulesSummaryText = GrantManagerFormatting.rulesSummary(snapshot: snap)
        statusMessage = nil
    }

    /// Revoke one Always/Never grant (process + durable) via single-key
    /// `RememberedGrants.forget` — does not clear/reseed other grants (P1).
    func revoke(_ item: GrantListItem) async {
        isBusy = true
        defer { isBusy = false }
        let removed = await RememberedGrants.shared.forget(item.grantKey)
        await reload()
        statusMessage = removed
            ? "Revoked \(item.decisionLabel) for \(item.title)"
            : "No grant found for \(item.title)"
    }

    /// Clear all Always/Never grants (all projects).
    func clearAll() async {
        isBusy = true
        defer { isBusy = false }
        await RememberedGrants.shared.clear()
        await reload()
        statusMessage = "Cleared all remembered grants"
    }

    /// Clear grants for one project key only.
    func clearProject(_ projectKey: String) async {
        isBusy = true
        defer { isBusy = false }
        await RememberedGrants.shared.clear(projectKey: projectKey)
        await reload()
        statusMessage = "Cleared grants for \(GrantManagerFormatting.shortProject(projectKey))"
    }
}

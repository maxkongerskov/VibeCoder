# perms — ZCode-parity permission rule syntax

Owner: `perms`. Files: `Sources/AgentCore/Safety/PermissionRules.swift`,
`Sources/AgentCore/Safety/ToolAuthorization.swift`. Did not touch AgentLoop,
tools, RememberedGrants, SwiftUI, or existing tests.

## What landed

Structured **command-prefix** rules for `run_shell` and **domain** rules for
`fetch_url` / `web_search`, plus a public **suggested-update** type for wave-2
approval sheets. Existing rule file paths and Claude `allow|deny|ask` still
parse; `commandContains` substring matching is unchanged.

## On-disk format (extend, do not replace)

Same files as before:

- `~/.vibecoder/permissions.json` / `~/.agentos/permissions.json`
- `<project>/.vibecoder/permissions.json` / `.agentos/permissions.json`
- `<project>/.claude/settings.json` → `permissions.allow|deny|ask`

New optional fields on a rule object (ignored by older readers):

```json
{ "kind": "allow", "tool": "run_shell", "ruleContent": "git status" }
{ "kind": "deny", "tool": "fetch_url", "ruleContent": "*.example.com" }
```

Aliases: `commandPrefix` → prefix `ruleContent`; `host` / `domain` → host
`ruleContent`. Do **not** add a new JSON schema version or a second store.

Claude-compatible:

- `Bash(git status)` / `Bash(git status:*)` → `run_shell` + `ruleContent`
  (still sets `commandContains` for the existing parse test)
- `WebFetch(*.example.com)` → `fetch_url` + host `ruleContent`

`alwaysAllow` / `alwaysDeny` grants stay fingerprint-exact (RememberedGrants).
Prefix “always allow `git status`” is a **rule**, not a new grant key.

## Match semantics

`AuthorizationRule.matches(tool:command:url:query:)`:

| Tool | `ruleContent` | Subject | Match |
|---|---|---|---|
| `run_shell` | `git status`, `git status:*`, `npm run` | `command` (and each `SafeBash` segment) | equals prefix **or** starts with `prefix + space/tab` |
| `run_shell` | glob with `*` (not `:*`) | same | `wildcardToRegExp` (`^….*…$`) |
| `fetch_url` / `web_search` | host or `domain:host` or `*.example.com` | URL host; `web_search` also `site:` in `query` | case-insensitive host; `*.example.com` is suffix (apex + subdomains) |

Allow rules apply only when **every** shell segment matches (so
`git status && npm install` cannot ride a `git status` prefix). Deny/ask fire
if any segment / host matches. Deny still beats ask; ask still beats allow.
Dangerous shell, plan mode, and path confinement still run after an allow.

Command-prefix normalizer (`CommandPrefixNormalizer`, first 1–2 tokens):

- `git`, `kubectl` → `git status`, `kubectl get`
- `npm run` / `pnpm|yarn|bun run` → `npm run`
- `docker compose` → `docker compose`

## SuggestedPermissionUpdate (wave-2 UI)

Public type on the auth surface (do **not** bind SwiftUI in this wave):

```swift
public struct SuggestedPermissionUpdate: Sendable, Equatable {
    public var toolName: String
    public var ruleContent: String?
    public var behavior: AuthorizationRule.Kind  // allow | deny | ask
    public var approvalLabel: String             // "Always allow git status"
    public var asRule: AuthorizationRule
}

ToolAuthorization.suggestions(forShellCommand: "git status -sb")
// → [{ toolName: "run_shell", ruleContent: "git status", behavior: .allow }]
```

Wave-2 sheet: when the pipeline returns `.ask` for `run_shell`, call
`suggestions(forShellCommand:)`. “Always allow” appends `update.asRule` to
`AuthorizationConfig.rules` (or writes the same object into
`permissions.json` `rules`). Once/Never stay on RememberedGrants.

No grant-suggestion hook existed in `ToolAuthorization`; this is that hook.

## Tests

`Tests/AgentCoreTests/ParityPermissionRulesTests.swift` — prefix match/non-match,
glob host, suggestions for `git status -sb`.

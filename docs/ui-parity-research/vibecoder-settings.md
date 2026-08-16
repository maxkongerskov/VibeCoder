# VibeCoder settings & secondary surfaces (code inventory)

Facts from `App/` + `Sources/AgentCore/Settings/`. Persistence is a single JSON blob in UserDefaults key `agentos.newday.settings` (`LegacySettingsMigration.appSettingsDefaultsKey`) via `SettingsStore` / `AppViewModel.settings.didSet` → `SettingsStore.replace`. `SettingsViewModel` exists (`App/ViewModels/SettingsViewModel.swift`) but is **not** attached to `SettingsViewV2`.

Doc vs code: `UI_DESIGN.md` §4.3 specifies a **5-tab top strip**, 720×520 sheet. Code is a **11-tab sidebar**, 980×700 sheet. Where they disagree, both are noted.

---

## 1. Settings container

| Item | Code | Doc §4.3 |
|---|---|---|
| Presentation | Modal **sheet** on `RootView` (`showingSettings`) | “Settings sheet” |
| Open | ⌘, (`VibeCoderApp` after `.appSettings`); sidebar footer **Settings**; command palette “Open Settings”; slash `/settings` `/config` `/preferences` `/prefs`; `/mcps` deep-links tab `mcp`; Chat can post `.settingsRequested` with `"connection"` | ⌘, |
| Not | Separate `Settings` window / `SettingsLink` | — |
| Size | min 920×620, ideal **980×700**, max 1100×820 (`SettingsViewV2` 143–144, 101–104) | 720×520 |
| Nav | Left sidebar 228 pt, 4 groups, search filters tabs | Tabs along the top |
| Default tab | `.agent` (“Agent”) | Tab 1 General |
| Deep-link | `initialTabRaw` = `SettingsTab.rawValue` (`agent`, `connection`, `model`, `mcp`, …) | — |
| Footer | **Close** (`.cancelAction` / Esc) | Done / ⌘W |
| Bind | `$app.settings` | — |

**Tab list (code labels)** — `SettingsTab` `App/Views/Settings/SettingsViewV2.swift` 14–87:

| Group (sidebar heading) | Tab label | `rawValue` | Icon | Subtitle |
|---|---|---|---|---|
| Agent | Agent | `agent` | `text.bubble.fill` | Instructions & behavior |
| Models & network | Connection | `connection` | `network` | Local servers & APIs |
| Models & network | Model & Backend | `model` | `cpu` | Providers & sampling |
| Models & network | MCP Servers | `mcp` | `server.rack` | External tools |
| Workspace | Tools | `tools` | `wrench.and.screwdriver` | Built-in capabilities |
| Workspace | Context | `context` | `rectangle.compress.vertical` | Window & compact |
| Workspace | Memory | `memory` | `brain.head.profile` | MEMORY & DECISIONS |
| System | Appearance | `general` | `paintbrush.fill` | Theme & type |
| System | Privacy | `privacy` | `lock.shield` | Data & backup |
| System | Advanced | `advanced` | `gearshape.2` | Chrome filter & debug |
| System | About | `about` | `info.circle` | Version & credits |

Doc §4.3 tabs: **General, Connection, Models, Privacy & License, About**. Code has no “Privacy & License” (no license UI), no dedicated Models-load tab (see §3), plus Agent / MCP / Tools / Context / Memory / Advanced.

---

## 2. Options by tab

Persistence column is `AppSettings` field unless noted. Defaults from `AppSettings.init` (`Sources/AgentCore/Settings/AppSettings.swift` 280–338).

### Agent (`AgentInstructionsSettingsView`)

| Option | Section/View | Control | Default | Persistence | Evidence |
|---|---|---|---|---|---|
| System instructions | System instructions | `TextEditor` (mono, live-bind) | `"You are a careful, precise coding agent. Edit by patch when possible; verify your changes."` | `systemPrompt` | `AgentInstructionsSettingsView.swift` 40–60, 133–135 |
| Reset to default | same | Button | restores `AppSettings.defaultSystemPrompt` | `systemPrompt` | 95–102 |
| Token estimate | same | Read-only `~\(n) tokens` | — | — | 19–21, 86–88 |

No per-conversation override editor here (copy says overrides still apply). Chat mode ignores this (`rawMode`).

### Appearance (enum `.general`, label “Appearance”) — `GeneralSettingsView` in `AppearanceSettingsView.swift`

Doc §4.3 Tab 1: Appearance segmented + Font size + **Agent trace toggle**. Code: no agent-trace control.

| Option | Section/View | Control | Default | Persistence | Evidence |
|---|---|---|---|---|---|
| Color Scheme | Appearance | Segmented: System / Light / Dark | `"system"` | `colorScheme` | 73–77, 92–101; applied `RootView` `.preferredColorScheme` 336, 360–366 |
| Font Size | Appearance | Segmented: Small / Default / Large | scale `1.0` (Default) | `chatFontScale` | 80–84, 103–111. Scales: 0.85 / 1.0 / 1.20 (`FontSizeChoice` 52–57). **AppSettings comment says 0.875 / 1.25** (240–242) — comment ≠ UI |
| Notifications | Appearance | Switch | `true` | `notificationsEnabled` | 114–124 |
| Live preview | Appearance | Static sample sentence at `16 * chatFontScale` | — | — | 129–138 |

### Connection (`ConnectionSettingsView`)

Doc §4.3 Tab 2: picker LM Studio / EXO / **llama.cpp** / **MLX**, host+port+Test, llama.cpp binary path. Code: **chip grid of 7 panes**; no llama.cpp; `MLXPanel` is compiled (“Not supported in v1”) but **not** in `ConnectionPane` / switch (dead). Active backend is per-card **Use this backend** / **Active**, also on Model & Backend strip.

Initial pane = active `settings.backend` (`ConnectionPane.initial`, 80–90). Landing never Local API.

**LM Studio** (`LMStudioPanel` 246–334)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Host | TextField | `127.0.0.1` | `lmStudioHost` |
| Port | TextField (1024–65535) | `1234` | `lmStudioPort` |
| Base URL | Read-only `http://host:port/v1` | — | derived |
| API Key | `SecureField` “Optional” | `""` | `lmStudioAPIKey` (secret input) |
| Test Connection | Button; states idle / Testing… / Connected — N models / error | — | calls `LMStudioBackend.listModels` + `ingestConnectionTestModels` |
| Auto-connect on launch | Toggle | `true` | `lmStudioAutoConnect` |
| Use this backend | Chip / button | backend default `.lmStudio` | `backend` via `app.activateBackend` |

**EXO Cluster** (`EXOPanel` 338–533)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Host / Port | TextField | `127.0.0.1` / `52415` | `exoHost` / `exoPort` |
| Endpoint | Read-only `/v1` | — | derived |
| Model ID | TextField (required to Connect) | `""` | `exoModelID` |
| Open Integrations page | Link `http://host:port/#/integrations` | — | — |
| Connect | Prominent button (not “Test Connection”) | — | ping + pin typed ID into `availableModels` / `selectedModelID` |
| Auto-connect on launch | Toggle | `false` | `exoAutoConnect` |
| Start snippets | Read-only `python -m exo` | — | — |

**oMLX** (`OMLXPanel` 537–617): Host/Port default `127.0.0.1`/`8080` (`omlxHost`/`omlxPort`); API Key secret `omlxAPIKey`; Test Connection → `OMLXBackend.listModels`. No auto-connect toggle.

**Ollama** (`OllamaPanel` 621–709): Host/Port `127.0.0.1`/`11434`; Test → `OllamaBackend.listModels`; Auto-connect `ollamaAutoConnect` default **false**; snippets `ollama serve` / `ollama pull llama3.2`. No API-key field.

**Unsloth Studio** (`UnslothStudioPanel` 713–806): Host/Port `127.0.0.1`/`8888`; API Key secret `unslothAPIKey` (blank → `~/.unsloth/studio/auth/`); Test; Auto-connect `unslothAutoConnect` default **false**.

**Custom Endpoint** (`CustomEndpointPanel` 810–932)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Endpoint | TextField | `http://127.0.0.1:1234/v1` | `customEndpoint` (normalized on Test) |
| API Key | `SecureField` | `""` | `customAPIKey` |
| Resolved | Read-only normalized URL | — | — |
| Test Connection | Button | — | `OpenAICompatibleClient.listModels`; success **activates** `.custom` if not already |

**Local API Server** (pane `localAPI`, 1026–1140) — doc flow 6.5 matches this pane, not a Connection “sub-section” of a 5-tab sheet.

| Option | Control | Default | Persistence |
|---|---|---|---|
| Run on app launch | Toggle | `false` | `localAPIEnabled` |
| Agent loop on Local API (opt-in) | Toggle | `false` | `localAPIAgentToolsEnabled` |
| Port | Stepper 1024…65535 | `11435` | `localAPIPort` |
| Start Server / Stop Server | Button + Listening/Stopped dot | runtime | `BackendConnectionCoordinator` / `LocalAPIServer` |
| Copy URL | `http://localhost:{port}/v1` | — | pasteboard |

**Xcode MCP Tools** (same Local API pane, `XcodeMCPSection` 1145–1216)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Enable Xcode MCP tools | Toggle | `false` | `xcodeMCPEnabled` |
| Reconnect | Button (if enabled) | — | `app.reconnectXcodeMCP` → `XcodeMCPCoordinator` |
| Status | Dot + `app.xcodeMCPStatus.label` | `.disconnected` | runtime |
| Bridge path | Read-only `XcodeMCPBridge.defaultBridgePath()` | — | — |

Crash-reporting toggle was removed from Connection (comment 119–121). Field `crashReportingEnabled` default `false` remains in schema; **no Settings control**.

### Model & Backend (`ModelBackendSettingsView`)

Doc §4.3 Tab 3 “Models”: model dropdown + **load sliders** (context, GPU offload, flash attn, KV cache) + **inference sliders** (temp, top-p, top-k, repeat penalty) + system-prompt override + reload banner. **None of those controls exist in this tab.** Engine strip + two-model role pickers only.

| Option | Control | Default | Persistence | Evidence |
|---|---|---|---|---|
| Active backend | 6-cell strip: LM Studio / EXO / oMLX / Ollama / Unsloth / Custom | `.lmStudio` | `backend` via `activateBackend` | 145–185. Reachability dots: `EngineReachabilityProbe` 15s ping |
| Local API status | Read-only if `localAPIEnabled` | — | — | 49–58 |
| Agents (Two-Model Mode) | Switch | `false` | `orchestratorEnabled` | 72–79 |
| Refresh role models | Icon button | — | runtime `refreshRoleModelOptions` | 83–94 |
| Orchestrator | Menu of live models + None | unset (`orchestratorBackendSet` false, model `""`) | `orchestratorBackend`, `orchestratorModelID`, `orchestratorBackendSet` | 109–118 |
| Worker | same | unset | `workerBackend`, `workerModelID`, `workerBackendSet` | 120–129 |

Sampling store exists (`ModelSettings` / `ModelSettingsStore`, App Support `model-settings/<id>.json`) with load+inference fields. **No Settings UI writes them.** `AppSettings.defaultSampling` = `.coder` (temp 0.3, topP 0.95, topK 40, repeatPenalty 1.05) — **no Settings control**.

### MCP Servers (`MCPServersSettingsView`)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Server list | Rows | `[]` | `mcpServers: [MCPServerConfig]` |
| Enabled | Switch per row | `true` on add | `mcpServers[i].enabled` |
| Probe | Antenna button → `tools/list` | — | runtime `MCPServerPool` |
| OAuth | Key icon (if `oauth` set) | signed out | `MCPOAuthCoordinator` (not AppSettings) |
| Edit / Delete | Buttons; delete confirm | — | replace/remove in `mcpServers` |
| Add Server | Button → sheet | name `new-server`, transport HTTP, enabled | append |

**Add/Edit sheet** (`MCPServerEditorSheet`, width 460):

| Field | Control | Default |
|---|---|---|
| Server Name | TextField | `new-server` / existing |
| Transport | Segmented: Streamable HTTP / Stdio | `.streamableHttp` |
| URL | TextField (HTTP) | `""` |
| Headers | TextEditor `key=value` lines → `[String:String]` | `[:]` |
| Bearer Token Env Var | TextField | nil |
| OAuth disclosure | Client ID, Auth URL, Token URL, Scopes, Client Secret (secret-ish), Callback Port | nil until expanded |
| Command Path | TextField (stdio) | — |
| Arguments | TextEditor one per line | `[]` |
| Environment | `key=value` JSON-ish editor | `[:]` |
| Startup Timeout (s) | Number field | `30` |
| Tool Timeout (s) | Number field | `120` |
| Enabled | Toggle | `true` |
| Per-Tool Timeouts | `tool_name=seconds` | `[:]` |

File discovery is **read-only**: `MCPConfigWalker.describeConfigSources` (project `.mcp.json` walk + `~/.vibecoder/mcp.json`). Files not editable in UI.

Xcode MCP is **not** an `mcpServers` row; it is `xcodeMCPEnabled` on Connection → Local API.

### Tools (`ToolsSettingsView` + nested `GrantManagerSettingsView`)

**Agent session** (300–485)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Permission mode | Segmented: Plan / Ask / Auto / Full (`ExecutionMode.shortLabel`) | `.build` (Ask) | **`AppViewModel.executionMode` only — not AppSettings** (`AppViewModel.swift` 102–107) |
| Safe Mode allow-list | Switch; disabled in Plan | `true` (because Ask enables Safe Mode) | `AppViewModel.safeModeOn` (session); writing it can flip mode Ask↔Auto |
| Headless / unattended | Switch | `false` | `AppViewModel.headlessModeOn` (session) |
| Shell seatbelt | Menu: Auto / Always on / Off | `.auto` | `shellSeatbeltPreference` |
| Auto-verify after edits | Switch; disabled if Chat mode | `true` | `verifyEdits` |
| Chat mode | Switch (`rawMode`) | `false` (Agent mode) | `rawMode` |
| Allowed path prefixes | List + Add `~/code/` | `["~/code/", "~/Downloads/", "/tmp/"]` | `safeModeAllowedPaths` (shown only if `safeModeOn`) |
| Allowed shell prefixes | List + Add `git` | `["swift build", "git", "ls"]` | `safeModeAllowedShellPrefixes` |

Same path/shell lists also edited in **Permissions sheet** (`PermissionsSheetView`, 700×600) from chat fingerprint: Safe Mode + Headless + lists. No Permission-mode picker there.

**Remembered grants** (`GrantManagerSettingsView`) — list/revoke only; **no add-rule form**.

| Option | Control | Persistence |
|---|---|---|
| Reload | Icon | `DurableGrantStore` → `RememberedGrants` |
| Rows | Always/Never badge + title + subtitle + **Revoke** | `RememberedGrants.forget` |
| Clear all… | Button | `RememberedGrants.clear` |
| Clear this project | Button if project open | `clear(projectKey:)` |
| Permission rule files | Read-only paths | disk: `.vibecoder` / `.agentos` `permissions.json`, `.claude/settings.json` (home + project) |

**Full Disk Access** — probe + Check Again + open System Settings. Not an AppSettings key.

**Builtin tools** — search “Filter tools…”, collapsible categories, per-tool Switch. Missing key = enabled. Reset → `toolEnabled = [:]`. Catalog `BuiltinToolCatalog.all` (Filesystem / Search / Shell / Git / Build / Web / Docs / PDF / Planning / Memory / Worktree / Agent). Names must match `Tool.name`. ~50 tools, all `defaultEnabled: true`.

Also: `maxAgentIterations` default 30, `headlessMaxIterations` 100, `stallWindow` 3 — **no Settings UI**.

### Context (`ContextSettingsView`)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Max context (tokens) | Number TextField; 0 = Auto | `0` | `maxContextWindowTokens` |
| Compact at | Slider 10…100 step 1 | `70` | `autoCompactThresholdPercent` |

Copy: auto-compact is wire-only; `/compact` rewrites transcript. `fullReplaceCompactEnabled` default `true` — **no toggle in this tab**.

### Memory (`ProjectMemorySettingsView`)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Project path | Read-only | conversation `projectRoot` else `openedProject` | — |
| File | Segmented MEMORY.md / DECISIONS.md | MEMORY.md | disk files at project root |
| Editor | `TextEditor` | empty / on-disk | `ProjectMemoryFiles` via VM |
| Reload / Revert / Insert template / Save (⌘S) | Buttons | — | write `MEMORY.md` / `DECISIONS.md` |
| Enable hybrid memory tools | Switch | `true` | `memoryEnabled` |
| Inject project MEMORY / DECISIONS | Switch | `true` | `injectProjectMemory` |
| Dream consolidation at turn end | Switch | `true` | `dreamEnabled` |

No FTS search UI. No embeddings. AppSupport dream MEMORY is separate (copy only).

### Privacy (`PrivacySettingsView` in `SettingsViewV2.swift` 373–493)

Doc §4.3 Tab 4: license key + status, Deactivate, crash reporting, backup. **Code: no license, no crash toggle.**

| Option | Control | Persistence |
|---|---|---|
| Report an issue… | Link `https://github.com/maxkongerskov/VibeCoder/issues` | — |
| Export… | NSSavePanel JSON | `ConversationStore.list` |
| Import… | NSOpenPanel JSON | `ConversationStore.save` each |
| Clear All… | Confirm “Delete All” | `app.deleteAllConversations()` |

### Advanced (`AdvancedSettingsView`)

| Option | Control | Default | Persistence |
|---|---|---|---|
| Clean model chrome | Switch | `true` | `cleanModelChrome` |

`playfulWaitingLabels` default `false` — **no UI** (read in `ChatView.swift`).

### About (`AboutView`)

Doc: Check for updates (Sparkle), OSS credits, privacy/terms links. **Code: version + one credit + copyright. No Sparkle, no update button.**

| Option | Control | Source |
|---|---|---|
| Version / Build | Read-only | `CFBundleShortVersionString` / `CFBundleVersion` |
| Credits | Max Køngerskov — Design & Engineering | hardcoded |
| Legal | © 2026 Max Køngerskov | hardcoded |

---

## 3. Model configuration (picker + Models pane)

**List source (code):** HTTP `InferenceBackend.listModels()` for the **active** `backend` (`BackendConnectionCoordinator.refreshModels` 107–133). Backends: LM Studio, EXO (pinned ID), oMLX, Ollama, Unsloth Studio, Custom `/v1`. In-process MLX factory still exists; Connection copy says v1 unsupported; `.mlx` / `.xai` not in engine strip.

**Not in UI:** Ollama/LM Studio as “local files”; HuggingFace Discover; catalog.json Library; GGUF download/pause/SHA; llama.cpp spawn.

**Connection test:** per Connection pane (see §2). Success → `ingestConnectionTestModels` → `ModelSettingsStore.applyActivations`.

**Per-model params exposed in UI:** none in Settings. Store fields (`ModelSettingsStore.swift` 40–75): load `contextLength` (default 32768 or catalog), `gpuOffloadLayers` (−1), `flashAttention` (true), `kvCacheType` (`f16`); inference `temperature` / `topP` / `topK` / `repeatPenalty` / optional `maxTokens`. Applied on `activateModel` / `warmUp` (oMLX load).

**Chat model picker** (`ModelPickerButton`): upward popover, search, sections Active + per-backend live + “Recognized catalog (not loaded)”. Expand state `UserDefaults` `vibecoder.modelPicker.expanded`. Command palette / `/model` → `ModelPickerSheet` (same picker + Done).

**Thinking effort** (`ThinkingEffortPicker` on input bar): Off/Low/Medium/High/Max when model advertises capability. **`ChatViewModel.thinkingEffort` default `.medium` — not AppSettings.** `/effort`.

---

## 4. Backend / connection coordinator

`BackendConnectionCoordinator` (`App/ViewModels/BackendConnectionCoordinator.swift`): `availableModels`, `selectedModelID`, `activeModelSettings`, `modelListError`, `modelLoadError`, `isLoadingModel`, `localServerRunning`. `activateBackend` writes `settings.backend` then `refreshModels` (EXO tries topology pin). `startLocalServer` / `stopLocalServer` wrap `LocalAPIServer`. Factory: `BackendFactory.make(from: AppSettings)` (HTTP). Settings UI for endpoints/keys is Connection tab only. `xaiAPIKey` in schema — **no Grok/xAI pane**.

---

## 5. Permissions / grants

| Surface | What | Persistence |
|---|---|---|
| Settings → Tools | Permission mode, Safe Mode, seatbelt, verify, Chat mode, allow-lists, grants list | mixed (see §2 Tools) |
| Permissions sheet | Safe Mode + Headless + path/shell lists | same bindings |
| Shell / MCP / task ask | `ShellApprovalSheet`: Once / Always / Never / Deny | Always/Never → `RememberedGrants` + `DurableGrantStore`; dangerous shell cannot Always/Never |
| File rules | Display only | JSON on disk |

**Mode default:** Ask (`.build`) + Safe Mode on. Plan forces Safe Mode. Full = `.yolo`. Cycle ⇧Tab / command palette / `/plan` `/auto` `/always-approve`.

No UI to author permission-rule JSON.

---

## 6. Hooks

**No hooks editor** in `Views/Settings` or elsewhere. `HookDispatcher` is invoked from `ChatViewModel` (UserPromptSubmit / Stop) reading project `.vibecoder/hooks` / `hooks.json`. Deny surfaces as status line. Config is files-only.

---

## 7. MCP

| Path | UI | Enable |
|---|---|---|
| User MCP (HTTP/stdio) | Settings → MCP Servers | `mcpServers[].enabled`; merge with file-discovered at turn start |
| Xcode native MCP | Settings → Connection → Local API pane | `xcodeMCPEnabled`; `XcodeMCPCoordinator` connect/reconnect/stop; tools via `mcpbridge` |

---

## 8. Skills / memory

**Skills:** no sidebar Skills tab, no manager window. `NotesLandingView` comment: replaced SkillsLandingView. Agent tool `load_skill`; slash `/skill` `/skills`. Toggle only via Tools → `load_skill`.

**Memory:** Settings → Memory editor (view/edit/save `MEMORY.md` / `DECISIONS.md`). No FTS search UI. Tools `memory` / `memory_search` / `memory_get` exist as toggles. `/remember` pins session note.

---

## 9. Secondary surfaces

**Sidebar (code):** `ZCodeSidebar` — workspace header + **Chat / Projects / Models / Notes / Scheduled** (`SidebarTab.sidebarTabs`, `SidebarShell.swift` 28–30). Footer: Delete all, Settings. Tasks list (conversations) with pin/rename/archive/delete/move. **Not** doc §4.2 four icon tabs Conversations / Projects / **Skills** / Models.

`SidebarTab.cluster` / `.code` exist. `.code` opens Chat. **Cluster is not in `sidebarTabs`**; `DetailPane` still hosts `ClusterView` if tab is `.cluster` (EXO host/port). RootView forces Chat if Cluster selected and backend ≠ EXO.

**Notes** (`NotesLandingView` + `NotesViewModel`): two-column list + editor. Search title/body. New / delete / delete all. Debounced save 0.4s. Disk: App Support `notes/<uuid>.json` (`NoteStore`). Not injected into the agent.

**Projects** (`ProjectsView` + `ProjectsViewModel`): card grid; New Project; per-card Rename / Delete (Trash). Persistence: `~/VibeCoder Projects/` via `ProjectsService` (comment also mentions App Support — `defaultRootFolderURL` is home/`AppBranding.projectsFolderName`). **No file tree in UI.** `ProjectFileTreeBuilder` is **tests only** (`App/Utilities/ProjectFileTreeBuilder.swift` unused by views).

**New Project sheet** (580×560): chooser Start from scratch / Use existing folder. Scratch: Name*, Instructions, Add Files, Location (default managed folder). Existing: folder picker. Footer toggle **“Memory is on”** is local `@State memoryOn` default true — **not read by `createFromScratch` / register** (dead control). Create opens `ProjectFolderLandingView`.

**Project folder landing:** back, composer “Start a new chat…”, list chats bound to that folder.

**Move to project:** `MoveToProjectSheet` from sidebar context menu.

**Scheduled** (`ScheduledLandingView`): list name, cadence, prompt snippet, last run, View last run, Run now, Delete. **New schedule** sheet (520×580): Name*, Task*, Frequency menu (Manual / Hourly / Daily / Weekdays / Weekly), Time of day (day-based; default 02:00), optional project folder. **No edit sheet** (`ScheduledTasksViewModel.update` unused by this view). Persist: `ScheduledTaskStore` (same dir as boot scheduler). Archive sidecar unused here.

`ScheduledTask` also has `longPrompt`, `askMode` (Ask/Auto-allow/Never) — **not on the create form**.

**TasksListView:** filter Active/Archived/All, search, bulk delete, New task → same `NewScheduleSheet`. Opened only by **DEBUG** ⌘⇧T (`showTasksListDebug`), not a sidebar tab. Comment still says “View All” from Recents.

**Models pane** (`ModelsLandingView`): header Refresh; active backend label; error; selected id; list `availableModels` with **Use**. Empty: “No models reported…”.

Doc §4.7 Library / Discover / HF filters / download lifecycle / catalog.json — **not implemented** in this view.

**Cluster** (`ClusterView`): Nodes (EXO `/state`) / Models (EXO catalog, search, fits-only, downloaded-only, Pin). Not in current sidebar nav.

**Patch review** (`PatchReviewSheetV2`): per-**file** Accept/Reject (not per-hunk — code comment: hunk buttons removed). Doc §4.4 per-hunk Y/N. Apply mapping `PatchDecision`. Live from `PatchReviewCoordinator`. Debug sheet uses empty apply.

**Worktree review** (`WorktreeReviewSheet`): file list + expand diffs, commit message, Continue / Discard / Merge into main. Live: `WorktreeService.reviewChanges`. Enable/merge/discard: `WorktreeCoordinator`. Debug sheet uses sample files.

**Remote control** (`RemoteControlSheet`): first-run password (`RemoteAccessPasswordStore`), start session, QR + URL, Revoke, Tailscale probe. Not a Settings tab.

**Context breakdown:** hover card on composer meter; optional `ContextBreakdownSheet`.

**Command palette** ⌘K: New/Clear/Compact/Session/Fork, Safe Mode, cycle/Plan mode, Settings, Projects, Scheduled, Choose Model.

---

## 10. Appearance / onboarding / license / language

| Topic | Code | Doc |
|---|---|---|
| Theme tokens | `App/Theme/Theme.swift`: dark #161616/#222/#2B2B2B; accent orange ≈ `#E48B46`; soft gray text | §2.3 Azure `#2563EB` / later Cobalt `#3385F2` — **doc ≠ Theme.swift** |
| User theme | Settings Appearance `colorScheme` only | System/Light/Dark (same) |
| Font | `chatFontScale` only | Small/Default/Large |
| Language | No UI | — |
| Onboarding | **Retired.** `VibeCoderApp` 46–52: always main UI; if `!hasCompletedOnboarding` sets `true` | §4.1 two screens (welcome + starter models) |
| License / trial / activation | **No views, no Settings fields** | §4.3 Privacy & License; §6.6 activation sheet |
| Updates | No Sparkle button in About | §4.3 Check for updates |

`hasCompletedOnboarding` default `false` but forced `true` on launch.

---

## AppSettings fields with no Settings control

`defaultSampling`, `maxAgentIterations`, `headlessMaxIterations`, `stallWindow`, `crashReportingEnabled`, `playfulWaitingLabels`, `xaiAPIKey`, `fullReplaceCompactEnabled`, `hasCompletedOnboarding` (auto-set). Session-only: `executionMode`, `safeModeOn`, `headlessModeOn`, `thinkingEffort`, `selectedModelID`.

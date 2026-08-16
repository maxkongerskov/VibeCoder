# ZCode 3.7.7 — Settings & auxiliary windows (UI inventory)

App: ZCode v3.7.7 (Electron + React 19). Settings is a two-pane window: left section list, right editor (`settings.title` / `settings.subtitle`). English copy from `IntlProvider-C321H7m8.js:14`. Nav IDs from `styles-OqUHW1P0.js:1077` (`n4t` / `t4t`). Desktop prefs schema: `out/main/chunk-L5EAZUIY.js:40` (`SS` zod object → `~/.zcode/v2/setting.json`). Model providers: `~/.zcode/v2/config.json`. Agent MCP/hooks/plugins: `~/.zcode/cli/config.json`. Catalog: `/Applications/ZCode.app/Contents/Resources/model-providers/models_catalog_china_llm_zcode_2026-06-03.json` (`schemaVersion` `zcode.model-providers.v1`).

**No dedicated settings tabs** for Permissions, Account, Network (proxy lives in General), Advanced, or Keyboard shortcuts.

## Settings nav

| Group id | Label | Evidence |
|---|---|---|
| `basics` | Basics | `settings.sidebar.group.basics` · `styles-OqUHW1P0.js:1077` |
| `agentCapabilities` | Agent capabilities | `settings.sidebar.group.agentCapabilities` |
| `dataAndStats` | Data and statistics | `settings.sidebar.group.dataAndStats` |

| Section id | Label | Group | Evidence |
|---|---|---|---|
| `general` | General | Basics | `settings.systemTitle` |
| `appearance` | Appearance | Basics | `settings.appearanceTitle` |
| `modelProvider` | Model settings | Basics | `settings.modelProviderTitle` |
| `browser` | Browser | Basics | `settings.browser.title` |
| `memory` | Memory | Agent capabilities | `settings.memory` |
| `plugins` | Plugins | Agent capabilities | `settings.plugins.title` |
| `skills` | Skills | Agent capabilities | `settings.skills.title` |
| `subagents` | Subagents | Agent capabilities | `settings.subagents.title` |
| `automations` | Automations **Beta** | Agent capabilities | `settings.automations.title` + `betaBadge` |
| `mcp` | MCP Servers | Agent capabilities | `settings.mcpTitle` |
| `commands` | Commands | Agent capabilities | `settings.commands.title` |
| `hooks` | Hooks | Agent capabilities | `settings.hooks.title` |
| `indexing` | Indexing | Data and statistics | `settings.indexing.title` |
| `usage` | Usage stats | Data and statistics | `settings.usageTitle` |

Theme chips in settings: `system` / `zai-dark` / `zai-light` (`e4t` · `styles-OqUHW1P0.js:1077`). Locales shipped in picker: `system`, `zh-CN` (中文简体), `en-US` (English). Schema default `locale` = `zh-CN`, `localePreference` = `system` (`chunk-L5EAZUIY.js:40`).

---

## Option inventory

Control types: **toggle** (`TC` checkbox), **select** (dropdown), **text+Save**, **number**, **button**, **list/form**.

| Option | Section | Control | Default / choices | Config key / file | Evidence |
|---|---|---|---|---|---|
| Language | General | select | `system` / `zh-CN` / `en-US` | `localePreference` → `~/.zcode/v2/setting.json`; resolved `locale` also stored | `o4t` `styles-OqUHW1P0.js:1077`; schema `:40` |
| Inherit system terminal profile | General | toggle | **on** | `terminalInheritSystemProfile` default `true` | `o4t`; schema |
| Terminal font | General | text + Save | blank = inherit; placeholder `MesloLGS NF, monospace` | `terminalFontFamily` optional | `settings.terminalFontFamily*` |
| Integrated terminal shell | General | select (Windows only, `showIntegratedTerminalShell`) | `auto`; plus discovered shells `{mode:shell,id,label,path,dialect}` | `integratedTerminalShell` | `settings.integratedTerminalShell*`; `o4t` |
| Enhanced Find and Grep | General | toggle | **on** (`!== false`) | `nativeSearchEnhancementsEnabled` default `true` | `settings.nativeSearchEnhancements*` |
| HTTP Proxy | General | text + Save | blank = direct; e.g. `http://127.0.0.1:7890`. Copy: does **not** read system env; restart required | `httpProxy` optional. Agent egress also uses `ZCODE_HTTP_PROXY` (FINDINGS §5) | `settings.httpProxy*` |
| No proxy | General | text + Save | comma hosts; e.g. `localhost,127.0.0.1,::1,.example.com,*.corp.com` | `httpProxyNoProxy` | `settings.httpProxyNoProxy*` |
| Custom certificate | General | text + Save | PEM path injected as `NODE_EXTRA_CA_CERTS`; restart required | `httpProxyCaCertPath` | `settings.httpProxyCaCertPath*` |
| Chrome hardware acceleration | General (desktop) | toggle | **on** | `desktopChromiumHardwareAccelerationEnabled` default `true` | `settings.desktopChromiumHardwareAcceleration*` |
| Receive preview updates early | General (desktop) | toggle | **off** | `receivePreviewUpdates` default `false` | `settings.receivePreviewUpdates*` |
| Automatically download and install updates | General (desktop) | toggle | **off** | `autoDownloadAndInstallUpdates` default `false` | `settings.autoDownloadAndInstallUpdates*` |
| Task notifications | General | toggle | **on** | `localStorage` `zcode-notification-enabled` (not `setting.json`) | `ho=` · `styles-OqUHW1P0.js:2` |
| Notification sound | General | toggle; disabled if notifications off | **on** | `localStorage` `zcode-notification-sound-enabled` | `go=` · same |
| Hide to tray when closing window | General (Windows) | toggle | **on** | `closeToTrayOnWindows` default `true` | `settings.closeToTrayOnWindows*` |
| Keep computer running | General (desktop) | toggle | **off** | `keepAwakeWhileRunning` default `false`. Also on Idle-time form | `settings.keepAwakeWhileRunning*` |
| Interaction behavior | General | select | **`queue`** / `guide` (`a4t`) | `zcodeInteractionBehavior` | `settings.zcodeInteractionBehavior*` |
| Automatically continue questions | General | toggle | **on** (5 min auto-continue) | `askUserQuestionAutoResolutionEnabled` default `true` | `settings.askUserQuestionAutoResolution*` |
| Show reasoning | General | toggle | **off** (schema); first reasoning item stays visible when off | `messageStreamShowReasoning` | `settings.messageStreamShowReasoning*` |
| Show todos | General | toggle | **off** (schema) | `messageStreamShowTodos` | `settings.messageStreamShowTodos*` |
| Auto-archive old tasks | General | toggle | **off** | `taskAutoArchiveEnabled` | `settings.taskAutoArchive*` |
| Archive retention | General | select; disabled if archive off | **7** / 3 / 14 / 30 days (`i4t`) | `taskAutoArchiveOlderThanDays` default `7`, max 365 | `settings.taskAutoArchiveDays*` |
| Data storage path | General | folder picker + Save | user home; suffix `.zcode/v2` fixed; restart required | `dataBaseDir` optional | `settings.dataBaseDir*` |
| Onboard | General | button | reopens onboarding / import | — | `settings.onboarding*` |
| Improve experience | General | toggle | **off** (telemetry of conversations) | `optimizeAgentExperienceEnabled` default `false` | `settings.optimizeAgentExperience*` |
| App theme | Appearance → Interface | select | `system` / `zai-light` / `zai-dark` (labels Light/Dark/System) | `localStorage` `zcode-theme` | `settings.themeMode*`; `e4t` |
| UI font size | Appearance → Interface | number 12–20 px | **14** if unset | `localStorage` `zcode-ui-font-size-px` | `fo()`/`po()` · `styles-OqUHW1P0.js:2` |
| Light code theme | Appearance → Code | select | **`github-light`** | `codePreviewSettings.lightTheme` in `localStorage` `zcode-code-preview-settings` | `lo=` · `:2`; picker `CO` `:274` |
| Dark code theme | Appearance → Code | select | **`github-dark`** | `codePreviewSettings.darkTheme` | same |
| Show line numbers | Appearance → Code | toggle | **on** | `codePreviewSettings.showLineNumbers` | `settings.showLineNumbers*` |
| Wrap long lines | Appearance → Code | toggle | **off** | `codePreviewSettings.wrapLongLines` | `settings.wrapLongLines*` |
| Code font size | Appearance → Code | number 12–20 px | **12** | `codePreviewSettings.fontSizePx` | `settings.fontSize*` |
| Code preview | Appearance | dual preview cards | Light + Dark; “Active” badge | — | `settings.previewSectionTitle` |
| Enable built-in browser control | Browser | toggle | enables official Browser Use plugin for new sessions | plugin enable + CUA | `settings.browser.control*` |
| Import Chrome browser data | Browser | button + confirm | one-shot cookies + LocalStorage from last-used Chrome profile | main `[browser-data]` | `settings.browser.import*` |
| Clear built-in browser cache | Browser | button | HTTP cache / Cache Storage / SW; keeps cookies | — | `settings.browser.clearCache*` |
| Clear all browser data | Browser | button + confirm | cookies + site data + cache | — | `settings.browser.clearAll*` |
| Workspace Memory | Memory | toggle + viewer | **off** | `memoryEnabled` default `false`; files under `~/.zcode/cli/memories` (FINDINGS §7) | `settings.memory*` |
| Memory viewer | Memory | tree + preview | per-workspace `MEMORY.md`; 5 MiB preview cap | local desktop only | `settings.memory.viewer*` |
| Index repositories for instant grep (Beta) | Indexing | toggle | **off** | `instantGrepIndexingEnabled` default `false` | `settings.indexing.instantGrep*` |
| Index new folders | Indexing | toggle | **off**; auto-index new folders with &lt; 50k files | `repoSnapshotIndexingEnabled` default `false` | `settings.indexing.repo*` |
| Usage tabs | Usage | tabs | **App usage** + one tab per connected Z.ai / BigModel Coding Plan / Team Plan | provider quota APIs | `settings.usage.tab.*` |
| App usage range | Usage | select | Last 7 / 30 days / All time | local session history | `settings.usage.range.*` |
| Coding Plan range | Usage | select | Today / 7 days / 30 days | provider monitor API | `settings.usage.codingPlanRange.*` |
| Entitlement cards | Usage | display | plan level, 5-hour prompt pool, weekly remaining, monthly MCP/tool quota, concurrency | Coding Plan account | `settings.usage.entitlement*` |

Code theme picker values (`CO` · `styles-OqUHW1P0.js:274`): GitHub Light/Dark, Vitesse Light/Dark, Minimal Light/Dark, GitHub HC Light/Dark, Catppuccin Latte/Mocha. Dark-classified: `github-dark`, `vitesse-dark`, `min-dark`, `github-dark-high-contrast`, `catppuccin-mocha`.

i18n exists for **Performance mode** (`settings.performanceMode*`) and store key `zcode-performance-mode` (`styles-OqUHW1P0.js:2`); **not** in `o4t` General form (inferred unused or gated).

---

## Model settings (`modelProvider`)

Two lists: **Providers** (presets: zai, bigmodel, ZAPI) and **Custom providers**. Connection modes: OAuth, Individual Plan (`codingPlan`), Team Plan, Start Plan, API key (`settings.modelProvider.connectionMode*`). Family selection persisted as `modelProviderFamilyModes` / `modelProviderFamilySelectedKeys` / `providerFamilyDomain` in `setting.json` (observed values: `zai` → `oauth` + `coding-plan:builtin:zai-start-plan`).

### Preset / account providers (not catalog)

| UI name | Kind | Base URL (observed in `~/.zcode/v2/config.json` `provider.*`) | Notes |
|---|---|---|---|
| Z.ai - API Key | `anthropic` | `https://api.z.ai/api/anthropic` | OAuth auto-fill |
| Bigmodel - API Key | `anthropic` | `https://open.bigmodel.cn/api/anthropic` | OAuth auto-fill |
| Z.ai - Coding Plan | `anthropic` | `https://api.z.ai/api/anthropic` | Individual Plan |
| BigModel - Coding Plan | `anthropic` | `https://open.bigmodel.cn/api/anthropic` | Individual Plan |
| BigModel- Coding Plan / Start Plan | `anthropic` | `https://zcode.z.ai/api/v1/zcode-plan/anthropic` | Start Plan / trial |
| ZAPI | built-in intranet | FINDINGS: `http://192.168.6.166:8080` | auto-sync model list |

Coding Plan purchase UI: Z.ai Lite / Pro / Max; BigModel enterprise Lite / Pro / Max + seats. Actions: Connect / Unlink / Use API key / Use subscription / Upgrade / View usage / View prices. API key field is a **secret input** (`settings.modelProvider.apiKeyPlaceholder` “Enter API key”); values stored `enc:v1:…` in `~/.zcode/v2/credentials.json` (FINDINGS §4) — not printed here.

Claude alias slots (FINDINGS §3 + UI): Haiku / Sonnet / Opus / Reasoning → mapped models (`settings.modelProvider.slot.*`, `claudeMapping*`). Build remaps `{haiku,sonnet,reasoning→GLM-5-Turbo, opus→GLM-5.2}`.

### Add / edit custom provider form

| Field | Control | Choices / notes | Maps to |
|---|---|---|---|
| Add path | buttons | **Provider catalog** / **Custom endpoint** | — |
| Name | text | placeholder `e.g. DeepSeek` | `provider.<id>.name` |
| API format | select (multi-kind) | Anthropic messages `/anthropic/v1/messages`; Chat completions `/v1/chat/completions`; Responses `/responses` | `kind` / per-model `kinds` |
| Base URL | text | `https://api.example.com/v1` | `options.baseURL` |
| Anthropic / OpenAI / Gemini endpoint | text (advanced) | per-format path overrides | catalog `endpoints.paths` |
| API key | secret input | empty allowed (`apiKeyRequired` flag) | `options.apiKey` (encrypted) |
| Model list | textarea (one name/line) or Add model | — | `models` |
| Model ID / Display name | text | — | `models.<id>`, `.name` |
| Context window | number | positive int; edit-model sheet is “Edit the context window” | `limit.context` |
| Max output tokens | number | empty or positive int | `limit.output` |
| Test model | button | auth / not found / network / no endpoint / rate limit / server | live request |
| Enable / Disable / Delete / Reorder | actions | drag reorder | `enabled`; `zcode.priority` |

Reasoning is **catalog-driven per model**, not a freeform settings field. Chat toolbar `thoughtLevel`: off / noThink / on / low / medium / high / xhigh / max (`chat.toolbar.thoughtLevel.value.*` · `IntlProvider-C321H7m8.js:17`).

### Bundled catalog (`models_catalog_china_llm_zcode_2026-06-03.json`)

| Catalog id | Name | defaultKind | baseURL | Models (ids) | Reasoning levels (catalog) |
|---|---|---|---|---|---|
| `moonshot-kimi` | Moonshot AI / Kimi | anthropic | `https://api.moonshot.cn` | kimi-k3, k3, k3-256k, kimi-k2.6, kimi-k2.5, moonshot-v1-{8k,32k,128k}[+vision-preview] | k3*: low/high/max (default max); k2.6: enabled/off |
| `minimax` | MiniMax | anthropic | `https://api.minimaxi.com` | MiniMax-M3, M2.7[+highspeed], M2.5[+hs], M2.1[+hs], M2 | none in catalog |
| `deepseek` | DeepSeek | anthropic | `https://api.deepseek.com` | deepseek-v4-flash, deepseek-v4-pro | off / high / max (default max) |
| `qwen-alibaba-model-studio-cn` | Qwen / Alibaba Cloud Model Studio (China) | anthropic | `https://dashscope.aliyuncs.com` | qwen3.5-plus/flash, qwen3-max, qwen-plus/flash, qwen3-vl-plus | enabled / off |
| `qwen-alibaba-model-studio-intl` | Qwen / Alibaba Cloud Model Studio (International) | openai-compatible | `https://dashscope-intl.aliyuncs.com` | same ids | enabled / off |
| `xiaomi-mimo` | Xiaomi MiMo | anthropic | `https://api.xiaomimimo.com` | mimo-v2.5-pro, v2.5, v2-pro, v2-omni, v2-flash | enabled / off |
| `zai` / `zai-coding-plan` | Z.AI [Coding Plan] | anthropic | `https://api.z.ai` | glm-5.3, 5.1[+highspeed], 5, 5-turbo, 5v-turbo, 4.7[+flashx/flash], 4.6, 4.5-air, 4.5, 4.6v[+flash/flashx], 4.1v-thinking-flash[x], glm-4-flash[x]-250414, glm-4v-flash, codegeex-4, charglm-4, emohaa | glm-5.3: low/high/max (default max); older: enabled/off |
| `bigmodel` / `bigmodel-coding-plan` | BigModel / 智谱 [Coding Plan] | anthropic | `https://open.bigmodel.cn` | same GLM ids | same |

Most non-Z.AI providers expose both `anthropic` and `openai-compatible` path suffixes. Per-model `modalities` (text/image/…) and `zcode.modified` live in `config.json`.

---

## Permissions (no settings tab)

No allow/deny rule list editor, no glob field, no per-directory trust panel in Settings.

| Surface | Control | Choices | Storage / notes | Evidence |
|---|---|---|---|---|
| Chat toolbar “Switch mode” | select | GLM labels: Default / Ask before changes (`build`) / Edit automatically (`edit`) / Plan mode / Full access (`yolo`) | per-task. Schema enum: `default,yolo,plan,edit,acceptEdits,auto,dontAsk,bypassPermissions,autoEdit,build` | `mode.label.glm.*` · `IntlProvider-C321H7m8.js:14`; `Ut=` · `chunk-L5EAZUIY.js:40` |
| Claude-compat labels | — | Default, Auto, Accept edits, Don't ask, Plan, Bypass permissions | same enum | `mode.label.claude.*` |
| Gemini-compat | — | Default, Auto edit, Plan, Yolo | — | `mode.label.gemini.*` |
| Codex-compat | — | Agent, Agent (full access), Auto edit, Full access, Read only | — | `mode.label.codex.*` |
| Runtime permission card | buttons | Allow; Always allow; Allow for session; Always allow in this project; Deny; Always deny | always-allow scoped to command prefix / exact command / file | `chat.permission.*` |
| Subagent form | select | Default, Auto, Accept edits, Don't ask, Plan, Bypass permissions | per-subagent | `settings.subagents.permissionMode.*` |
| Idle-time form | hint + mode | “Switch permissions to Full access…” | unattended; confirmations pause task | `offPeak.form.permissionWarning` / `fullAccessHint` |
| CUA (macOS) | sheet | drag `ZCode CUA Helper.app` into Accessibility / Screen Recording | not a settings toggle | `chat.cuaPermission.*` |

---

## Hooks (`hooks`)

Description: “Manage task lifecycle hooks to automatically execute commands on specific events.” Scope toggle: **User** only in the settings tabs component (`p2t` hard-codes `value:user`). Changes apply to **new sessions**.

Events (`f2t` · `styles-OqUHW1P0.js:1077`): `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`, `Stop`. Extra events (if present) still group in the list.

| Field | Control | Default / hint | Evidence |
|---|---|---|---|
| Event | select | the 7 names | `settings.hooks.event` |
| Runner | select | `command` (Shell command) / `process` (Process) | `settings.hooks.type.*` |
| Matcher | text | blank = match all; e.g. `Write, Edit, Bash` | `settings.hooks.matcher*` |
| Command | text | e.g. `echo 'Hello from hook'` | `settings.hooks.command*` |
| Arguments | textarea | one argv per line | `settings.hooks.args*` |
| Shell | text | System default | `settings.hooks.shell*` |
| Timeout (seconds) | number | — | `settings.hooks.timeout*` |
| Run in background | toggle | — | `settings.hooks.async` |
| Status message | text | e.g. Checking workspace | `settings.hooks.statusMessage*` |
| Custom fields JSON | textarea | must be object | `settings.hooks.customJson*` |
| Enable / Import / Delete | list actions | groups: Configured / Available to import / Plugin hooks | `settings.hooks.group.*` |

Persisted at `~/.zcode/cli/config.json` → `hooks` (`enabled` observed; hook records written by Hooks service). Plugin hooks are read-only here.

---

## MCP Servers (`mcp`)

List groups: **Configured MCP servers** / **Plugin MCP servers**. Search + add + import (Claude/Codex/etc.) + remote sync.

| Field | Control | Choices | Maps to |
|---|---|---|---|
| Name | text | — | `~/.zcode/cli/config.json` `mcp.servers.<name>` (inferred) |
| Type | select | **stdio (local command)** / **SSE (Server-Sent Events)** | server transport. No separate HTTP type in UI |
| Command | text | stdio | `command` |
| Arguments | text | space-separated | `args` |
| Environment variables | text (optional) | — | `env` |
| Headers | text (optional) | SSE | `headers` |
| Timeout MS | number | — | `timeoutMs` |
| Full configuration | JSON editor / paste | Form vs raw | `settings.mcp.form.fullConfig` |
| OAuth | button | “Open authorization” | plugin MCP OAuth |

Status chips: Connected / Connecting / Disconnected / Authorization required / Plugin disabled / Not loaded / Host built-in; `{count} tools`. Delete confirm removes from file.

Remote: “Sync MCP servers to remote target” copies user MCP to SSH/WSL/Docker host (HTTP URLs copied; filesystem paths rewritten).

---

## Skills (`skills`)

“Enabled skills can be referenced in chat with `$skill-name`.” Groups: **Workspace and personal skills** / **Plugin skills**. Filters: All / Enabled / Disabled; source filter. New skill / Import (copy or symlink; Global vs Project) / Sync to remote / Copy to common.

Detail: description, enabled, path, slug, scope (Personal / Plugin / Project), version, owner, diagnostics (frontmatter name/description rules). User-level skills desktop-only. Disk: `~/.zcode/skills/` (user) + workspace skill dirs + plugin `skills/`.

## Commands (`commands`)

`.md` command files invoked as `/command-name`. Form: Name (letters/numbers/-/_), Prompt (required), Description, Argument hint (`e.g. <file-path>`). Import copy/symlink. “Open user commands folder.”

## Subagents (`subagents`)

Groups: User / Built-in (read-only) / Plugin (read-only). Form: Name, Description, System prompt, Model (`inherit` / `defaultMain` / `lite` / `main` / pick), Color (blue/cyan/green/orange/pink/purple/red/yellow), Permission mode (above), Tools inherit-all vs custom + disallowed tools, Skills, `injectAgentsMd`, `maxTurns`, background. “Open user agents folder.” Workspace-level create/edit unsupported. Storage: `~/.zcode/cli/agents/` (FINDINGS §7).

## Plugins (`plugins`)

Tabs: **Installed** / **Discover**. Footer `{total} plugins · {enabled} enabled`. Components: skills, commands, hooks, MCP, agents, LSP.

Discover / store: Public vs Personal; search “Plugins, Skills, MCPs…”; categories Developer Tools / Guides / Productivity / Templates / Utilities / Other. Add marketplace: GitHub repo, git URL, file, or directory. Copy: “Discover uses GitHub marketplaces.” Label **Claude Code Plugins**.

Marketplaces on disk (`~/.zcode/cli/plugins/known_marketplaces.json`):

| id | source | URL / repo |
|---|---|---|
| `zcode-plugins-official` | url | `https://cdn-zcode.z.ai/zcode/official-plugin/marketplace.json` |
| `claude-plugins-official` | github | `anthropics/claude-plugins-official` |

Cache: `~/.zcode/cli/plugins/cache/`, `marketplaces/`. Bundled plugins under `Resources/glm/packages/` / cache: android-emulator, browser-use, document-skills, restore-legacy-sessions, zcode-guide, ios-simulator, skill-creator (+ observed `superpowers`). Manifests: `.zcode-plugin/`, `.claude-plugin/`, `.codex-plugin/` (FINDINGS §8).

Plugin config form can mark fields required / sensitive (needs secure storage). Uninstall deletes cache + data dir + saved config. Remote sync copies plugins to remote target.

---

## Terminal / editor

| Item | Where | Notes |
|---|---|---|
| Inherit system terminal profile | General | login shell env, proxy, k8s vars, local font |
| Terminal font override | General | blank = auto-detect |
| Integrated terminal shell | General, Windows | Auto → Git Bash then `cmd.exe`; Bash uses selected shell |
| Toggle terminal | Command palette | `quickPick.command.toggleTerminal` |
| Open in {editor} | file / task header | `appHeader.openInEditor`; “Choose app” |
| Open in Finder / File Manager | header | no “default editor” setting |
| Open provider config in editor | header | `appHeader.openProviderConfig*` |

---

## Account (no settings tab)

| UI | Control | Notes | Evidence |
|---|---|---|---|
| Welcome / login | OAuth buttons + skip | “Connect to Z.ai” (region Global) / “Connect to BigModel” (CN). Replaces current identity | `login.oauth.*` |
| API key onboarding | secret input + provider select | Z.ai / BigModel | `login.apiKey.*` |
| Sidebar profile | Connect / logged-in menu | `sidebar.profile.notLoggedIn` = Connect | |
| Disconnect | confirm | “Disconnect and restart”; interrupts running sessions | `logout.confirm.*` |
| Coding Plan unlink | Unlink on Model settings | `settings.modelProvider.codingPlan.disconnect` | |
| Plan popover | sidebar | Individual/Team, 5-hour / weekly / tool quota, Upgrade / Renew / Usage stats | `sidebar.usage.plan.*` |
| Account types | — | `bigmodel` (智谱) and `zai`, each with Coding Plan preset (FINDINGS §4) | |
| Credentials | not shown | `~/.zcode/v2/credentials.json` `enc:v1:<iv>.<tag>.<ct>` | FINDINGS §4 |

OAuth: `https://bigmodel.cn/login` → `https://zcode.z.ai/api/v1/oauth/token` (appId `zcode`, redirect `zcode://oauth/callback`).

---

## Network & remote (not a settings tab except proxy)

| Item | UI | Config |
|---|---|---|
| HTTP proxy / no-proxy / custom CA | General (above) | `setting.json`; restart. Description: model + MCP + tools + renderer. System env **not** read |
| Private CA (auto) | not user-visible as a toggle | `~/.zcode/v2/certs/zcode-network-ca.{pem,key}`; `ZCODE_AGENT_CA_CERT` (FINDINGS §5) |
| Remote workspace | separate wizard | methods: **SSH / Server / WSL / Docker** (`remote.kind.*`) |
| SSH form | Host, Port, Username, Auth = Password \| Private key (+ passphrase), SSH config alias, asset install = local-download-upload \| remote-download | `ssh.*` |
| Remote sync from settings | Plugins / Skills / MCP “Sync” | `settings.remoteSync.*` |
| Web remote control | QR + link sheet | `webRemoteControl.*`; device id in `setting.json` `webRemoteControlExternalRelayDevice` |

---

## Scheduler / off-peak

**Automations** settings tab (Beta): scheduled tasks for the current workspace. Form: title, instructions, model (inherit / pick), schedule (hourly / daily / weekdays / weekly / monthly / custom / one-time), weekdays, time, max runs, repeat indefinitely, run-now, pause/resume, run history. Templates: Morning dev brief, Risk scan, Documentation sync check, Content ideas, Meeting prep, Release brief, Weekly review. “Scheduled tasks only run while your computer is awake.” (`automations.*`)

**Idle-time tasks** (off-peak) are **not** a settings section; sidebar / new-task tabs “Idle-time task” vs “Scheduled tasks”. Coding Plan subscribers only; does not consume plan quota. Form: title, instructions, model, thought (off/nothink/low/high/max/enabled), keep-awake, Full-access hint. Templates: Customize, CI Failures & Flaky Test Report, Documentation sync check, Standup Git Summary. Status: queued (“Waiting for idle compute”) / running / paused / succeeded / failed / cancelled. Engine: `out/scheduler/index.js` (`off-peak-run` · FINDINGS §2).

---

## Other sheets / windows / menus

| Surface | How opened | Contents |
|---|---|---|
| Settings | sidebar / `quickPick.command.settings` | this document |
| About ZCode | Help → About ZCode | `titleBar.menu.help.about` (no extra i18n fields found) |
| Check for updates / update dialog | Help | auto-download checkbox; skip version; release notes | `updateDialog.*` / `updateReady.*` |
| Process monitor | Help → Process monitor | separate window `out/renderer/process-monitor.html` |
| Feedback | Help → Feedback | submit + My feedback tickets | `feedback.center.*` |
| Export logs / Clear all data | Help / sidebar | `titleBar.menu.help.*` |
| Toggle developer tools / stdio tap / performance recording | Help | `titleBar.menu.help.toggle*` |
| Developer tools panel | in-app | Network status (model HTTP) + Token debug | `developerTools.*` |
| Command palette | command center / quick pick | sections Application / Chat / Configuration / Navigation / Panels | `quickPick.*` |
| Command center | search | Actions / Tasks / Files | `commandCenter.*` |
| Keyboard shortcuts | — | **no cheatsheet UI**. `keyboardShortcuts-BGHopxr9.js` is a key-label helper only |
| Onboarding / Import Settings | General or first run | import from Claude Code, Codex CLI, Windsurf, Cursor-adjacent agents (Trae, Qoder, Roo, Goose, Continue, Augment, OpenCode, OpenClaw, Kiro, CodeBuddy, Qwen Code, …) | `settingsSync.agent.*` |
| Session expired | modal | Sign in again | `login.expired.*` |
| Force update | modal | current vs minimum version | `forceUpdate.*` |
| ZCode Endpoint (dev) | main `showZCodeEndpointPromptWindow` | writes `zcodeEndpointOrigin` | `chunk-L5EAZUIY` / `main/index.js` |
| Sidebar locale/theme/zoom | profile menu | locale + theme + Interface zoom (`desktopZoomLevel`) | `sidebar.settings.*` |

Command-palette settings-adjacent commands: Settings, Personalization, Model, MCP Servers, Skills, New task, Open workspace, Community, Product docs, My feedback, Logout/Disconnect, switch theme, toggle sidebar/terminal/preview/browser/diff.

---

## Config file map

| File | Role |
|---|---|
| `~/.zcode/v2/setting.json` | Desktop prefs (schema `SS` · `chunk-L5EAZUIY.js:40`) |
| `~/.zcode/v2/config.json` | `provider.<id>` models, endpoints, limits, reasoning, `zcode.modified` |
| `~/.zcode/v2/credentials.json` | encrypted API keys / OAuth (`enc:v1:`) |
| `~/.zcode/v2/certs/` | generated network CA |
| `~/.zcode/cli/config.json` | agent `model.main/lite`, `mcp.servers`, `hooks`, `plugins` |
| `~/.zcode/cli/plugins/` | marketplaces + installed plugin cache |
| `~/.zcode/cli/agents/`, `memories/`, `~/.zcode/skills/` | subagents, memories, user skills |
| `localStorage` | theme, UI font, code preview, notifications, performance mode |
| Catalog JSON in app Resources | picker defaults for Add-from-catalog |

Observed extra `setting.json` keys not in the General form: `recentProjects`, `lastWorkspaceSession`, `lastActiveTabIndex`, `enabledBuiltinAgentCliProviders`, `modelProviderFamily*`, `providerFamilyDomain*`, `skippedElectronUpdateVersions`, `settingsSyncFirstRunPromptHandled`, `webRemoteControlExternalRelayDevice`, `desktopZoomLevel`.

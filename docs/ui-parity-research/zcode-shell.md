# ZCode 3.7.7 — App shell & global chrome

Source: Electron + React 19 desktop GUI in `/Users/maxkongerskov/zcode-reverse/extracted/`. Primary renderer `out/renderer/assets/styles-OqUHW1P0.js` (1082 minified lines). English copy from `out/renderer/assets/IntlProvider-C321H7m8.js` (`m={...}` EN map, line 9). Menu labels from `out/main/chunk-L5EAZUIY.js:1` (`Tu["en-US"]` / `Tu["zh-CN"]`). Keyboard matchers `out/renderer/assets/keyboardShortcuts-BGHopxr9.js:1`. Desktop command IDs `out/renderer/assets/src-HCld2afU.js:39`. Theme CSS `out/renderer/assets/styles-BxSv8qTx.css:2`. Window/menus `out/main/index.js`.

Locales: **en-US** and **zh-CN** only. Resolved from `locale` query, settings, or `navigator.language` (`zh*` → `zh-CN`, else `en-US`). English strings below unless noted. Inferences marked **(inferred)**.

---

## 1. Window chrome (Electron)

| Item | Behavior | Evidence |
|---|---|---|
| Default size | **1200×800**, `minWidth:480`, `minHeight:640`, title from create-window arg | `out/main/index.js:682` `new UY({width:1200,height:800,...})` |
| macOS visual | `titleBarStyle:"hidden"`, `trafficLightPosition:{x:22,y:23}`, `vibrancy:"under-window"`, `visualEffectState:"active"`, `backgroundColor:"#00000000"` | `index.js:682` `XY` / `index.js:642` `var Gu={x:22,y:23}` |
| Windows visual | Hidden title bar + `titleBarOverlay`, `backgroundMaterial:"acrylic"`, transparent bg | `index.js:682` `XY` |
| Linux visual | `frame:!1`, `hasShadow:!1`, solid `backgroundColor:HY` | `index.js:682` `XY` |
| Preload / zoom | `contextIsolation:!0`, `webviewTag:!0`, `zoomFactor` from stored `desktopZoomLevel` (in −3…+5) | `index.js:682` `EL`; zoom enable flags in `rY` |
| Close (darwin) | Fullscreen close → leave fullscreen; else **hide** (not destroy) unless force-quit | `index.js` `UL` `handleDarwinWindowCloseRequest` |
| Close (Windows) | Optional **close-to-tray** hide when last window | `index.js:1091` `KL` |
| Dock badge | Unread sum → `app.setBadgeCount` on darwin/linux | `index.js` `zL` `supportsAppUnreadBadge` |
| Startup overlay | `#loading` `role="status"` `aria-busy` **`aria-label="Loading..."`**; 96×96 dark logo shell (`#000→#151718`); `#root` opacity 0 until `body.zcode-startup-ready` | `out/renderer/index.html:6–35,158–181` |
| Update-status window | `?windowKind=update-status` skips logo overlay and mounts update UI only | `index.html` unused; `assets/index-D0hX1M2_.js:1` `j=…windowKind===\`update-status\`` |

Renderer boot applies `platform-mac-desktop` / `platform-windows-desktop` / `platform-linux-desktop` on `<html>` (`index-D0hX1M2_.js:1`).

---

## 2. Main window regions

Shell root: `data-workspace-shell="true"` flex row (`styles-OqUHW1P0.js:1068`). **No status bar** (no `statusBar.*` i18n).

### 2.1 Top overlay (sits over sidebar / traffic lights)

Component `UOt` — absolute `h-14` (mac) / `h-12` (Win/Linux), `z-20`, `[app-region:no-drag]` (`:386`).

| Control | Label / aria | Behavior | Evidence |
|---|---|---|---|
| Toggle sidebar | `workspaceSidebar.toggleSidebar` = **Toggle sidebar**; shortcut ⌘B / Ctrl+B | Icon `sidebarClose`/`sidebarOpen`. Win/Linux: app logo (`alt="ZCode"`) swaps to sidebar icon on hover | `UOt` `:386`; `IntlProvider` |
| Task back | `taskNav.back` = **Go back**; shortcut ⌘[ / Ctrl+[ | Disabled when no history | `UOt`; `rge` `:243` |
| Task forward | `taskNav.forward` = **Go forward**; shortcut ⌘] / Ctrl+] | | same |
| New task | `sidebar.newTask` = **New task**; shortcut ⌘N / Ctrl+N | Shown when sidebar hidden (`showNewTaskButton ?? !isSidebarVisible`) | `UOt` |
| Update chip | `updateReady.shortTitle` **Update** / `updateReady.title` **Update v{version}** | Tooltip: ready / available; click opens update dialog | `BOt` in `UOt`; `updateReady.*` / `updateAvailable.tooltip` |

Mac traffic-light inset: `paddingLeft` default **96px** (`a??96`). Win overlay CSS `--windows-caption-control-width`.

### 2.2 Left sidebar (`#sidebar`, `data-workspace-sidebar-panel`)

| Item | Fact | Evidence |
|---|---|---|
| Width | CSS `--workspace-sidebar-panel-width` / `--workspace-sidebar-width`. **Min 264px** (`q5=264`, `uJt=264`). `max-w-[50%]`. Persisted `localStorage` `zcode:workspace-shell:sidebar-width-px`. Resize handle `role="separator"` `aria-label` `workspaceSidebar.resizeSidebar` (**Resize sidebar**), `aria-valuemin=264` | `:1068` |
| Hide | Width/opacity transition; `pointer-events-none opacity-0` when collapsed | `:1068` |
| Sections | Reorderable **Tasks** (`workspaceSidebar.conversationsSection`) and **Projects** (`projectsSection`) | `workspaceSidebar.reorderSection` “Move {section} section” |
| New task row | **New task** (`taskList.newThread` / `workspaceSidebar.newConversation`); shortcut chip ⌘N | `IFt` `:392` |
| Search | Sidebar button **Search** (`commandCenter.open`) + shortcut ⌘K; placeholder **Search actions, tasks, or files** | `:258` / `:392` |
| Automations | **Automations** (`workspace.openScheduledSettings`) — switches `workspaceMainView` to `automations` | `:392` `kJt` |
| Skills | **Skills** (`workspace.openSkillsSettings`) → settings `skills` | `:392` |
| File tree | **Show files** (`workspaceSidebar.showFileTree`); tree title **Workspace**; back **Back to tasks**; search files; **Show changed files only** | `workspaceFileTree.*` |
| Organize | Menu **View**: **Group** / **Project** / **Timeline**; **Sort by** **Created** / **Updated**; **Expand all** / **Collapse all** | `workspaceSidebar.organize*` |
| Task list | **Pinned**, **Recent**; empty **No tasks yet**; archived **Archived**; search **Search tasks...** | `taskList.*` / `workspaceSidebar.search*` |
| Task row menu | Pin / unpin, rename, archive, delete, mark unread, **Open in split pane**, feedback, model trajectory | `taskList.pin`…`openInSplitPane` |
| Groups | **New group**, colors gray/red/orange/yellow/green/blue/purple, rename, ungroup | `taskGroup.*` |
| Projects | **Add project**; empty **No open projects**; remove does **not** delete disk files (`confirmDialog.projectRemoveDescription`) | sidebar + confirm |
| Remote row | **Connecting** / **Not connected** / **Reconnect**; SSH popover Alias/Host/Path | `workspaceSidebar.connecting`…`sshConnection*` |
| Empty sidebar | **No workspaces yet. Open a workspace to get started.** | `workspaceSidebar.empty` |
| Missing dir | Banner: directory missing; history-only until restore + restart | `workspaceSidebar.unavailableLocalDirectory` |

**Sidebar footer / profile (settings popover, not a 4th column):**

| Control | Label | Evidence |
|---|---|---|
| Account | Logged out: **Connect** (`sidebar.profile.notLoggedIn` / `app.login`). Logged in: **Disconnect** (`app.logout`) | `IntlProvider`; logout confirm **Disconnect and restart ZCode?** |
| Usage | **Usage remaining**, **Coding Plan**, **Upgrade** / **Renew** / **More**, 5-hour + weekly quotas, **Usage stats** | `sidebar.usage.plan.*` |
| Theme picker | `qPt=['system','zai-dark','zai-light']` → **System default** / **Dark theme** / **Light theme** | `:391` |
| Locale | **English** / **中文简体** (`sidebar.settings.locale.*`) | same |
| Zoom | **Interface zoom** | `sidebar.settings.interfaceZoom` |
| Community | **Community** | `sidebar.menu.community` |
| Export logs | **Export logs** | `sidebar.exportLogs` |

### 2.3 Center column

`workspaceMainView`: `chat` | `automations` | `repo-wiki` (`kJt` `:1068` / `:1082`).

**Workspace header** (`header` `h-12` `border-b`, `data-testid` Jt) `:392`:

| Side | Controls | Labels |
|---|---|---|
| Left (`PFt`) | Workspace / project name, active task title, git dirty count, session/path menus | **Open in Finder** / File Explorer / File Manager; **Open in {editor}**; **Copy path** / task path / session ID / log / JSONL; **Reload session**; **Go to config** |
| Right (`MFt`) | Help menu; **Toggle terminal**; **Toggle panel** (side pane) | `workspaceHeader.help.menu` **Help**; `terminal.toggle`; `sidePane.togglePanel`. Side-pane aria **Expand side pane** / **Collapse side pane**. Shortcut ⌥⌘B / Ctrl+Alt+B |
| Help menu items | **Report an issue**, **Request a feature**, **User community**, **Product docs** | `workspaceHeader.help.*` |
| Win/Linux extra (`S6`) | New task, Open workspace, terminal, browser when overlay needs caption-row actions | `allowOpenWorkspace` |

Center stack default panel pair `CJt=['conversation','terminal']` (`:1068`) — chat + **bottom terminal dock**. Composer dock is in chat (out of scope). `--chat-bottom-dock-height` reserved for composer.

**No window-level footer.** Git / Diff live in the right side pane, not a status bar.

### 2.4 Right side pane

Toggled independently of the left sidebar. Tab strip + **Add tab**.

| Tab / action | Label | Evidence |
|---|---|---|
| Add / open tab | **Add tab**, **Open tab**, **Search tabs...**, Open / Recently closed | `sidePane.addTab` / `openTab` / `tabOverview` |
| Browser | **Browser**; address **Enter a URL**; back/forward/reload; **Open in default browser**; **DevTools**; **Free size**; element picker | `browser.*` |
| Review / Diff | **Review** / **Diff**; **Toggle diff panel** | `sidePane.review`, `diff.title` |
| Code viewer | **Code viewer** | `codeViewer.title` |
| Terminal | **Terminal**; **New terminal**; close tab | `terminal.*` |
| Whiteboard | **Whiteboard** | `whiteboard.title` |
| Repo wiki | **Repo wiki** | `repoWiki.title` |
| Subagents | **Subagents** / **Subagent** | `sidePane.subagent*` |
| Side conversation | **Side conversation** | `sidePane.selectionChat` |
| Open file | **Open file** — search workspace files | `sidePane.openFile*` |
| Treemapping / trajectory | **Treemapping**, **Model trajectory** | titles |
| Pane chrome | Expand / collapse / **Expand panel** / **Restore panel width**; close tab / others / all | `sidePane.maximize` / `restoreSize` / `close*` |

Default extra column pair `SJt=['conversation-column','browser']` **(inferred)** browser as first side-pane occupant.

### 2.5 Command overlay (palette + command center)

One dialog `Bje` (`:258`): scopes **All / Actions / Tasks / Files** (`commandCenter.scope*`). Command-only strings use `quickPick.*`.

| UI | Copy |
|---|---|
| Title | **Command palette** (`quickPick.title`) |
| Description | **Search and run commands available in this workspace.** |
| Placeholder | **Type a command** / **Search actions, tasks, or files** |
| Empty | **No matching commands.** / **No related results** |
| Find-in-task (⌘F) | **Find in task**; scopes messages / file changes; prev/next |

**Command catalog** (`O_e` `:243`):

| id | Section | EN label | Shortcut shown |
|---|---|---|---|
| `new-task` | Suggested | New task | ⌘N / Ctrl+N |
| `open-workspace` | Suggested | Open workspace | ⌘O / Ctrl+O |
| `suggested-settings` | Suggested | Settings | — |
| `toggle-sidebar` | Panels | Toggle sidebar | ⌘B |
| `toggle-terminal` | Panels | Toggle terminal | ⌘J |
| `toggle-preview` | Panels | Toggle preview | — (if embedded browser) |
| `add-terminal-tab` | Panels | Add terminal tab | — |
| `add-browser-tab` | Panels | Add browser tab | — |
| `add-review-tab` | Panels | Add review tab | — |
| `settings` | Configure | Settings | — |
| `switch-theme` | Configure | Switch theme to dark/light | — |
| `skills-settings` | Configure | Skills | — |
| `mcp-settings` | Configure | MCP Servers | — |
| `feedback` | Application | Feedback | — |
| `community` | Application | Community | if `canOpenCommunity` |
| `product-docs` | Application | Product docs | — |
| `login` / `logout` | Application | **Connect** / **Disconnect** | — |

Sections: Suggested, Chat, Navigation, Panels, Configure, Application. Extra i18n commands exist (`previousConversation` **Previous task**, `nextConversation` **Next task**, `goBack`/`goForward`, `toggleSidePane`, `toggleBrowserPanel`, `toggleDiffPanel`, `myTickets`, `personalization`, `openFile` **Search files**) — some are bound only via keydown, not `O_e`.

---

## 3. Navigation model

| Concept | Behavior | Evidence |
|---|---|---|
| Workspace | Opened folder (local) or remote session. Purpose query `initialWorkspacePurpose`: `conversation` \| `project` (default **project**) | `index-D0hX1M2_.js:1` |
| Open workspace | Native directory picker; menu/palette **Open workspace**. WSL UNC → prompt **Open this through WSL remote connection?** (**Open WSL connection** / **Continue with path**) | `workspace.wslUncPrompt.*`; `platform.selectDirectory` |
| Add workspace | **Add new workspace** / **Open folder** / **Start from scratch** | `workspace.addNewWorkspace`… |
| Remote kinds | Wizard **Remote connection**: **SSH**, **Server**, **WSL**, **Docker**. SSH success copy: **Connected, and opened in a new window.** | `remote.kind.*`, `ssh.success` |
| Conversation workspace | Purpose `conversation` — work outside a project (`chat.empty.workOutsideProject`) | empty-state i18n |
| Tasks | Per-workspace session list; create **New task**; archive; pin; group | sidebar |
| Task history | ⌘⇧[ / ⌘⇧] previous/next task; ⌘[ / ⌘] nav back/forward in workspace chrome | `rge` `:243` |
| Split panes | **Open in split pane**; **Split right** / **Split down** (new session); close pane keeps session running | `v4Pane.*` |
| Multi-window | `activateOrSetWorkspace`; remote SSH opens **new window**; deep-link `OpenWorkspacePath` with trust dialog “Only open folders from sources you trust…” | `index.js` `XP` `confirmExternalWorkspaceOpen`; preload `activateOrSetWorkspace` |
| Mobile remote | **Mobile remote control** — QR / link; phone sees current window’s workspaces/tasks only | `webRemoteControl.*` |
| Main view swap | Chat ↔ Automations ↔ Repo wiki **inside the same window** (not separate OS windows) | `workspaceMainView` |
| Close context | File → **Close window** (⌘W) sends `CloseActiveContext` to renderer (tab/context, not always OS-close) | `src-HCld2afU.js:39`; menu `Z.CloseActiveContext` |

No multi-root “workspace file” document. **One project path per workspace tab/window**; many tasks inside it.

---

## 4. Menu bar (macOS + others)

Built by `rY` / `rebuildApplicationMenu` (`out/main/index.js:682`). Labels `chunk-L5EAZUIY.js:1`. App locale `zh*` → zh-CN else en-US.

### ZCode (darwin only)

| Item | Role / action | Accelerator |
|---|---|---|
| About ZCode | `Z.ShowAbout` | — |
| Check for updates *(production)* | `Z.CheckForUpdates`; label mutates: Checking… / Update available {v} / Downloading… / Restart to update | — |
| Services | `role:"services"` | — |
| Hide {appName} | `role:"hide"` | system |
| Hide others | `role:"hideOthers"` | system |
| Show all | `role:"unhide"` | — |
| Quit {appName} | `role:"quit"` | system |

Non-darwin: About + Check for updates live under **Help**.

### File

| Item | Command | Accelerator |
|---|---|---|
| New task | `Z.NewTask` | **CmdOrCtrl+N** |
| Open workspace | `Z.OpenWorkspace` | **CmdOrCtrl+O** |
| Close window | `Z.CloseActiveContext` | **CmdOrCtrl+W** |

### Edit (roles only)

Undo, Redo, Cut, Copy, Paste, Select all.

### View

| Item | Command | Accelerator |
|---|---|---|
| Toggle full screen | `role:"togglefullscreen"` + `Z.ToggleFullScreen` | system |
| Zoom in | `Z.ZoomIn` | **CmdOrCtrl+Plus** and hidden **CmdOrCtrl+=**; enabled if zoom &lt; 5 |
| Zoom out | `Z.ZoomOut` | **CmdOrCtrl+-**; enabled if zoom &gt; −3 |
| Actual size | `Z.ResetZoom` | **CmdOrCtrl+0**; enabled if zoom ≠ 0 |

### Window

Minimize (`role:"minimize"`). Darwin: Zoom (`role:"zoom"`), Bring all to front (`role:"front"`).

In-window (Win caption / title-bar overlay, not this menu): **Minimize window**, **Maximize or restore window** (`titleBar.window.*`).

### Help

| Item | When | Command |
|---|---|---|
| What's new | always | `Z.OpenChangelog` (external) |
| Capture agent stdio traffic | unpackaged + visible | checkbox `Z.ToggleZCodeStdioTapDevProxy` |
| ZCode Endpoint → Production (default) / Test / Custom… / Reset to default | `he==="test"` only | `SetZCodeEndpoint*` |
| Toggle developer tools | always | `role:"toggleDevTools"` |
| Process monitor | always | `Z.OpenProcessMonitor` |
| Start / Stop performance recording | always | start/stop; stop starts disabled |
| Feedback | always | `Z.OpenFeedback` |
| Export logs | always | `Z.ExportLogs` |
| Clear all data | always | `Z.ClearAllData` |

### Tray (Windows `createWindowsDesktopTray`, `index.js:1061`)

Tooltip **ZCode**. Menu: **Open ZCode** | New task | Open workspace | Check for updates (prod) | About ZCode | Clear all data | **Quit**.

### Dock (darwin `configureDockMenu`, `index.js:1091`)

Single item **Show current window** (`dock.menu.showCurrentWindow`).

### Context menu (editable / selection)

Roles undo/redo/cut/copy/paste/delete/selectAll; **Inspect Element** in unpackaged (`index.js:682` `s9`).

---

## 5. Global keyboard shortcuts

Matchers (`keyboardShortcuts-BGHopxr9.js:1`): `ta` = ⌘/Ctrl+key; `Qi` = ⌘/Ctrl+Shift; `Rre` = ⌘/Ctrl+Alt; `ea` = **Ctrl** (not ⌘); `zre` = Ctrl+Shift. Display: `$i` = ⌘X / Ctrl+X; `Vre` = ⌥⌘X / Ctrl+Alt+X.

| Shortcut (mac) | Win/Linux | Action | Where |
|---|---|---|---|
| ⌘K **or** ⌘⇧P | Ctrl+K / Ctrl+Shift+P | Open command overlay | `rge` `:243` |
| ⌘F | Ctrl+F | Find in task | `rge` |
| ⌘B | Ctrl+B | Toggle left sidebar | `rge` |
| ⌘J | Ctrl+J | Toggle terminal | `rge` |
| ⌥⌘B | Ctrl+Alt+B | Toggle side pane | `rge` `Rre(e,\`b\`)` |
| ⌘[ / ⌘] | Ctrl+[ / ] | Workspace nav back/forward | `rge` |
| ⌘⇧[ / ⌘⇧] | Ctrl+Shift+[ / ] | Previous / next task | `rge` |
| ⌘N / ⌘O | Ctrl+N / O | New task / Open workspace | Menu; web-only keydown if `!isDesktop` (`:1082`) |
| ⌘W | Ctrl+W | Close active context | Menu |
| ⌘+ / ⌘= / ⌘- / ⌘0 | same | Zoom in / out / actual | Menu |
| Ctrl+M | Ctrl+M | Open model menu (composer toolbar; **not** ⌘M) | `:324` |
| Ctrl+Shift+M | same | Cycle session mode | `:324` |
| Ctrl+T | same | Cycle thought level | `:324` |
| Esc | Esc | Stop running task (chat); dismiss overlays | chat / dialogs |
| Enter | Enter | Submit composer (chat; default) | chat (other agent) |

Menu accelerators also registered at OS level (New task, Open workspace, Close, Zoom).

---

## 6. Appearance / theme

| Item | Fact | Evidence |
|---|---|---|
| Storage | `localStorage` **`zcode-theme`**, default **`zai-dark`** | `styles-OqUHW1P0.js:2` `Mie`; `index-D0hX1M2_.js:1` |
| Named options | **`system`**, **`zai-dark`**, **`zai-light`**. Legacy `dark`→`zai-dark`, `light`→`zai-light` (`So`) | `:2` `So`/`Co`; picker `qPt` `:391` |
| DOM classes | `html.dark` when resolved dark; `theme-zai-dark` / `theme-zai-light` | `Co` `:2` |
| System | Follows `prefers-color-scheme`; resolves to zai-dark or zai-light | `Co` |
| Picker labels | System default; Dark theme; Light theme | `sidebar.settings.theme.*` |
| Accent | Dark: `--color-accent:#001d3d`, brand `#fff`, primary `#fff`. Light: accent `#ebf4ff`, brand `#000`, primary `#000` | `styles-BxSv8qTx.css:2` |
| Code themes | Many Shiki packs (github-*, catppuccin-*, gruvbox-*, ayu-*, material-*, dracula, …) — **syntax only**, not app chrome | `out/renderer/assets/*-*.js` |
| Title bar sync | `platform.setTitleBarTheme` | `index-D0hX1M2_.js:1` |
| Locale store | `zcode-locale` default **`zh-CN`** | `:2` `Mie` |

**Key `theme-zai-dark` tokens** (`styles-BxSv8qTx.css:2`):

| Token | Value |
|---|---|
| `--color-background` | `#161616` |
| `--color-sidebar` | `#161616` |
| `--color-header` / `--color-panel` / `--color-tab` | `#202020` |
| `--color-card` / `--color-popover` / `--color-input` / `--color-toast` | `#2b2b2b` |
| `--color-border` | `#ffffff1a` |
| `--color-hover` | `#ffffff0d` |
| `--color-selected` | `#ffffff1a` |
| `--color-foreground` | `var(--color-neutral-300)` |
| `--color-primary` | `#fff` |
| `--color-terminal-blue` / charts | `#4099ff` |
| `--color-success` | `#46bf72` |
| `--color-destructive` | `#ff5c5c` |
| `--color-warning` | `#ff8a30` |

**Key `theme-zai-light` tokens:**

| Token | Value |
|---|---|
| `--color-background` | `#f8f8f8` |
| `--color-sidebar` | `#f0f0f0` |
| `--color-header` / `--color-panel` / `--color-card` | `#fff` |
| `--color-border` | `#0d0d0d1a` |
| `--color-foreground` | `var(--color-neutral-800)` (token block) |
| `--color-primary` | `#000` |
| `--color-accent` | `#ebf4ff` |
| `--color-terminal-blue` | `#0b7fff` |

Startup logo shell is **always** dark (`#000`/`#151718`) regardless of theme (`index.html:48` comment).

---

## 7. Onboarding / first-run / login

### 7.1 Boot

1. Native window + HTML loading logo.  
2. React root: `IntlProvider` + desktop app (`index-D0hX1M2_.js:1`).  
3. Query: `restoreSession` (default true), `initialWorkspacePath`, `initialWorkspacePurpose`, `unavailableWorkspacePath`, `locale`, `windowKind`.  
4. Theme applied **before** paint from `zcode-theme`.

### 7.2 Login (account chrome only)

Surface title **Welcome to ZCode**; description **Connect your account to start using ZCode**.

| Control | Copy |
|---|---|
| OAuth Z.ai | **Connect to Z.ai** + tag **Global** |
| OAuth BigModel | **Connect to BigModel** + tag **CN** |
| Waiting | **Waiting for {provider} authentication...** |
| Cancel / retry | **Cancel** / **Retry login** |
| API key | **Use API key** → title **API Key**, placeholder **Enter API key**, providers Z.ai / BigModel, **Get API Key**, **Continue** |
| Skip | **Skip for now** |
| Expired | **Your session has expired** / **Sign in again** |

OAuth authorize URL is Zhipu/Z.ai (main process; no tokens documented here). Hint: *Signing in again replaces the current identity.*

Legacy `welcome.username` / `welcome.password` / **Login** still in the catalog (older username/password form). Live login block uses `login.*` (`:1082`).

### 7.3 First-run / onboarding

Split view (`:1082`): left 50% + right 50% hero.

| Element | Copy |
|---|---|
| Eyebrow | **First run setup** |
| Title | **Welcome to ZCode** |
| Primary | **Start ZCode** |
| Secondary | **Migration Guide** |
| Helper | **Import existing tool settings now, or skip and continue later from Settings.** |
| Dialog alt | **Welcome to ZCode** / **Choose how to start your first session.** |
| Settings re-entry | **Onboard** / **Open onboarding** |

Migration wizard label **Migration Guide**; steps **Sessions, Skills, MCP servers, Plugins, Commands, AGENTS.md, Agent settings, Migration**.

No-workspace marketing pane: **Open fast. Stay focused.** / **Pick a workspace, jump back in, and keep the surface clean.** (`projectSelector.hero*`).

Post-login first window: restore last session if `restoreSession`; else empty workspace / picker. Unread badge and last sidebar width restore from local state.

---

## 8. Empty states & global banners

### Empty conversation (center)

Time-of-day heading (`Sit` `:340`, hours 5/9/12/14/18/23):

| Hours | Copy |
|---|---|
| 05–09 | Morning, ready when you are |
| 09–12 | Morning, how can I help? |
| 12–14 | Noon break? |
| 14–18 | Good afternoon! Leave the rest to me. |
| 18–23 | Evening, nice work today |
| 23–05 | It's late—remember to take care of yourself. |

Subtitle: **Start a new task in {workspace}**. Actions: **Choose workspace**, **Select project**, **Work outside a project**, **Home**, **Create workspace**.

Sidebar empties: **No tasks yet**, **No open projects**, **No workspaces yet. Open a workspace to get started.**

### Update / promo banners

| Surface | Copy |
|---|---|
| Title-bar chip | **Update v{version}**; tooltip **v{version} ready, click to restart and update** or **New version v{version} is available** |
| Dialog | **New version v{version} is available** / **Downloading v{version}** / **v{version} is ready**; **Download update**; **Restart to update**; **Skip this version**; **Later**; checkbox **Automatically download and install updates from now on** |
| Confirm restart | **Update to v{version}?** / **The app will quit and restart…** / **Restart now** / **Later** |
| Post-update | **Release notes** / **I know** |
| Toasts | You're on the latest version (v{v}); New version…; Downloading…; v{v} downloaded, restart to install; Updates are disabled in dev builds; Update check failed: {error} |
| Usage footer | **Upgrade** / **Renew** / **No active Coding Plan** / **Login to view plan usage.** |
| Force-update (OS dialog) | Title **Update ZCode**; message **The current version can no longer be used**; buttons **Auto update** / **Manual update** / **Quit** | `index.js:1061` `b9` |
| In-app force | **Update ZCode to continue** | `forceUpdate.*` |
| External workspace | Warning: only open folders you trust (agent runtime) | `index.js` `JP`/`XP` |
| App crash | **Something went wrong with the app UI** + **Retry** / **Reload app** | `appError.*` |

No carousel onboarding beyond the first-run split + migration wizard.

---

## 9. Auxiliary windows / sheets / toasts

| Window | Size / chrome | UI | Evidence |
|---|---|---|---|
| About | **256×312**, frameless, transparent, modal to parent, no menu | Title **About ZCode**. Body: **ZCode Desktop App**, **version {appVersion}**, optional **Optimized for Apple Silicon.**, **Copyright © {year} ZCode.** Button **OK** (closes). System `color-scheme: light dark`; card ~256×280 | `index.js:442` `SD`; `:640` `RD`; `G3=256,q3=312`; `K3="ZCode Desktop App"` |
| Process monitor | **680×500**, title **Process Monitor**, bg `#1e1e1e` | Separate `process-monitor.html` | `index.js:641` `Hu` |
| Update status | Extra `BrowserWindow`, `windowKind=update-status`, `restoreSession:false`, `supportsSettings:false` | Dedicated update UI; close-to-front instead of destroy while updating | `index.js:1275` `Zte` |
| ZCode Endpoint | **Modal**, title **ZCode Endpoint**, non-resizable (test/dev) | Custom origin prompt HTML | `index.js` `q5` |
| Force update | Native message box **before main window** | Blocks startup; auto/manual/quit | `index.js:1061` `OL` |
| Remote wizard | In-app dialog `max-w-4xl` almost full viewport | Kind → settings → connecting logs → directory | `remote.*` `:386` |
| SSH / WSL / Docker / Server | Same wizard | Fields host/port/user/auth; WSL distro; Docker container; Server URL/token | `ssh.*` `wsl.*` `docker.*` `server.*` |
| Mobile remote | Dialog + QR | **Mobile remote control**; **Stop**; **Refresh QR code** | `webRemoteControl.*` |
| Logout confirm | Dialog | **Disconnect and restart ZCode?** | `logout.confirm.*` |
| OS notifications | `platform.showTaskNotification` | Task complete / click focuses task | preload + `index-D0hX1M2_.js:1` |
| In-app toasts | `--color-toast`; update + scheduled-run toasts | e.g. `scheduledPreview.toast.running` **Running “{title}”…** | `:1082`; CSS |
| Feedback | Menu/palette **Feedback** | `Z.OpenFeedback` / in-app tickets panel | desktop command |

Desktop command enum (all shell-level): `newTask`, `openWorkspace`, `closeActiveContext`, `closeWindow`, `minimizeWindow`, `toggleMaximizeWindow`, `toggleFullScreen`, `resetZoom`, `zoomIn`, `zoomOut`, `showAbout`, `openChangelog`, `checkForUpdates`, `relaunchApp`, `openFeedback`, `openCommunity`, `exportLogs`, `toggleDevTools`, `openProcessMonitor`, `toggleZCodeStdioTapDevProxy`, `setZCodeEndpointProduction|Test|Custom`, `resetZCodeEndpoint`, `startPerformanceRecording`, `stopPerformanceRecording`, `clearAllData` (`src-HCld2afU.js:39`).

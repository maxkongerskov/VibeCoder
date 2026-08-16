# VibeCoder app shell — ground truth

Read-only inventory of **live** app chrome (Swift 5.10 / SwiftUI, bundle **VibeCoder 1.0.5**, macOS 14+). Chat transcript internals, settings option lists, and ZCode are out of scope except where they are window-level sheets/overlays.

**Live vs dead:** RootView hosts `ZCodeSidebar`. `SidebarShell` still compiles (engine strip + Agents panel + 20 pt rows) but is **not** mounted. `ConversationListViewModel` and `NavigationState` exist and are **unreferenced** by the live tree. Sidebar selection + CRUD go through `AppViewModel` → `ConversationCoordinator`.

Where `UI_DESIGN.md` disagrees with code, both are stated.

---

## 1. App entry & scenes

| Region | UI element | Behavior | Evidence |
|---|---|---|---|
| Scene | Single `WindowGroup` | One scene type. No `Window`, no `Settings { }`, no `defaultSize`, no `windowResizability`, no `@SceneStorage`. Title string empty. `.windowToolbarStyle(.unified)`. | `App/VibeCoderApp.swift` 22–60 |
| Window size | Min frame | Code: `.frame(minWidth: 960, minHeight: 620)`. Fully user-resizable (system default). **Doc §10:** min 960×620, **opens at 1280×800**. No default size is set in code — first-open size is AppKit/SwiftUI default. | `VibeCoderApp.swift` 40; `UI_DESIGN.md` 964 |
| Launch | `LaunchPhase` | Starts `.loading` (`Color.clear`). After `SettingsStore.shared.current()`, sets `hasCompletedOnboarding = true` if false, then `.ready` → `RootView`. `app.boot()` is **after** first paint (models/network not on critical path). Opacity transition. Canvas background on the group. | `VibeCoderApp.swift` 14–56, 1–5 |
| Environment | App-level objects | Only `@StateObject AppViewModel` injected as `.environmentObject`. Coordinators live **inside** `AppViewModel` (`BackendConnectionCoordinator`, `ConversationCoordinator`, `WorktreeCoordinator`, `XcodeMCPCoordinator`) plus `SleepAssertionService`, `PatchReviewCoordinator`, `UserQuestionCoordinator`, `ShellApprovalCoordinatorService`. Not separate env objects. | `VibeCoderApp.swift` 12, 35; `App/ViewModels/AppViewModel.swift` 40–142 |
| Pane VMs | Local, not app-level | `ProjectsViewModel` `@StateObject` in `ProjectsView` / `MoveToProjectSheet`. `NotesViewModel` in `NotesLandingView`. `ScheduledTasksViewModel` in `ScheduledLandingView`. Per-conversation `ChatViewModel` cached on coordinator. | `ProjectsView.swift` 35–47; `NotesLandingView.swift` 20; `ScheduledLandingView.swift` 19–26; `ConversationCoordinator.swift` 80–88 |
| Dead VMs | `NavigationState`, `ConversationListViewModel` | `NavigationState.Pane` (chat / newTaskLanding / projects / tasksList / notes / models) is unused. List VM is a DEV PLAN port; live list is `ConversationCoordinator`. | `App/ViewModels/NavigationState.swift` 12–21; `ConversationListViewModel.swift` 33–40 |
| Branding | Display / paths | `AppBranding.displayName = "VibeCoder"`; app-support `VibeCoder`; projects folder `VibeCoder Projects`. Info.plist `CFBundleName`/`DisplayName` VibeCoder, version 1.0.5, category developer-tools. | `Sources/AgentCore/AgentCore.swift` 14–18; `App/Info.plist` 13–24 |
| Onboarding flag | Auto-complete | First launch writes `hasCompletedOnboarding = true`. Comment: “Onboarding is retired — always land on the main UI.” | `VibeCoderApp.swift` 46–52 |

---

## 2. Main layout tree

Two-column `NavigationSplitView` only. No `HSplitView`. No window-level right/inspector column.

| Region | UI element | Behavior | Evidence |
|---|---|---|---|
| Split | `NavigationSplitView(columnVisibility:)` | Sidebar + detail. `$columnVisibility` default `.all`. Spring animation `response: 0.38, dampingFraction: 0.88` on visibility change (system Hide Sidebar). **No** width-based auto-collapse. | `App/Views/RootView.swift` 82–84, 181–198 |
| Sidebar width | Column constraints | Code: `min: 240, ideal: 280, max: 360`. **Doc §4.2 / §10:** 260 default, resizable 220–360; at 1400–1920 → 280; >1920 → 320; **<1080 → icon-only strip**. Icon-only / width breakpoints are **not implemented**. | `RootView.swift` 131; `UI_DESIGN.md` 482–483, 966–971 |
| Sidebar chrome | Background | `Theme.Palette.subtle` (same plane as composer). | `RootView.swift` 132 |
| Toolbar | Unified, title stripped | `.toolbarBackground(.hidden, for: .windowToolbar)` on split + detail. `RemoveWindowTitleModifier`: macOS 15+ `.toolbar(removing: .title)`; older relies on `WindowChromeAdjuster`. Sidebar column `.navigationTitle("")`. | `RootView.swift` 147–150, 189–200, 594–607 |
| Toolbar contents | Sidebar primary action only | `ToolbarItem(placement: .primaryAction)`: `square.and.pencil` → `app.newConversation()` + tab `.chat`. Help “New conversation (⌘N)”. **No** keyboardShortcut on the button (⌘N owned by File menu). System sidebar-toggle lives in the unified strip. **Doc §4.2** toolbar: model chip + search + settings + new — those are **not** in the window toolbar. `ToolbarModelChip` removed (comment 609–613). | `RootView.swift` 133–146, 609–613; `UI_DESIGN.md` 452, 485 |
| Window chrome | `WindowChromeAdjuster` | `titleVisibility = .hidden`, `title = ""`, transparent titlebar, `titlebarSeparatorStyle = .none`, `.fullSizeContentView`. Recursively sets AppKit `focusRingType = .none`. | `App/Theme/ViewExtensions.swift` 70–116; `RootView.swift` 335 |
| Focus rings | Hidden | `.hidesSystemFocusRing()` → `focusEffectDisabled()`. **Doc §8:** “Focus rings always visible (2 pt accent ring).” | `ViewExtensions.swift` 25–30; `VibeCoderApp.swift` 36; `UI_DESIGN.md` 944 |
| Overlay | Command palette | `ZStack` over the split when `showingCommandPalette`. Dim + 520-wide card. | `RootView.swift` 167–176 |
| Detail routing | `DetailPane` | If `app.openedProject != nil` → `ProjectFolderLandingView` **wins over tab**. Else: `.chat`/`.code` → chat workspace; `.projects` → `ProjectsView`; `.scheduled` → `ScheduledLandingView`; `.cluster` → `ClusterView` (tab **not** in live nav); `.notes` → `NotesLandingView`; `.models` → `ModelsLandingView`. | `RootView.swift` 494–527 |
| Chat empty | Zero visible convos | `NewTaskLandingViewV2` (not `EmptyDetailView`, which is unused). If selection missing/archived, first non-archived convo is shown and selected. | `RootView.swift` 537–564 |
| Overlay project | `openedProject` | Cleared when `selectedConversationID` or `selectedTab` changes. | `RootView.swift` 337–350 |
| Responsive | Chat column (detail only) | `Theme.ChatLayout.contentWidth` clamp 320–1040 with adaptive gutters 24–96. Window chrome itself does not change columns. **Doc:** >1920 max bubble width 1080. | `App/Theme/Theme.swift` 169–257; `UI_DESIGN.md` 971 |

---

## 3. Sidebar (live = `ZCodeSidebar`)

`SidebarShell` (dead): engine cells LMS/EXO/OMLX/OLLAMA/UNSLOTH, AGENTS toggle + orchestrator/worker pickers, workspace+library nav, time-grouped Recents, “Serving on :port”, footer Delete all + gear. **Doc §4.2** matches this older 4-icon-tab idea more than the live sidebar.

| Region | UI element | Behavior | Evidence |
|---|---|---|---|
| Which is live | `ZCodeSidebar` | Mounted from `RootView.sidebarColumn`. Comment: engine/agents moved to Settings → Model & Backend. | `RootView.swift` 90–130; `ZCodeSidebar.swift` 1–47 |
| Workspace header | Folder chip + name + path | Name: `openedProject?.name` else last path component of selected convo `projectRoot` else opened project path else **"Default Workspace"**. Path: selected convo `projectRoot` else opened project URL, monospace 10, middle-truncate. Tap → `selectedTab = .projects`. Chevron.up.chevron.down is **decorative** (no menu). | `ZCodeSidebar.swift` 351–394; `RootView.swift` 119–165 |
| Primary nav | 5 rows | `SidebarTab.sidebarTabs` = **Chat, Projects, Models, Notes, Scheduled**. Icons: `bubble.left.and.bubble.right`, `folder`, `cpu`, `note.text`, `calendar.badge.clock`. Selected: 12.5 medium + `Theme.Palette.hover` 8-pt rect. Models row shows capsule count of `app.availableModels.count` when > 0. **Doc:** 4 icon tabs Conversations / Projects / Skills / Models with accent underline. **No Skills tab.** Cluster exists on enum + DetailPane but is **not** in `sidebarTabs`. | `SidebarShell.swift` 17–30, 32–54; `ZCodeSidebar.swift` 91–113, 307–343; `UI_DESIGN.md` 172, 491 |
| Tasks section | Disclosure + New Task | Header **TASKS** (10 pt bold uppercase, tracking 0.8) + chevron. Persist collapse in `@AppStorage("sidebarRecentsCollapsed")`. **+ New Task** (accent, semibold 12) under header; help “Start a new task (⌘N)”; forces tab Chat and uncollapses. | `ZCodeSidebar.swift` 118–141, 470–498 |
| Search | None | No conversation search field. **Doc §7.2** placeholder “Search conversations”. `ProjectsView.searchQuery` is declared and unused. | `ZCodeSidebar.swift` (no search); `UI_DESIGN.md` 899; `ProjectsView.swift` 52 |
| Empty tasks | Copy | Collapsed-open + empty: 12 pt tertiary **“No tasks yet”**, 16 pt vertical pad. **Doc §4.6:** bubble icon + “No conversations yet.” + “⌘N to start one.” | `ZCodeSidebar.swift` 150–158; `UI_DESIGN.md` 630–637 |
| Unloadable | Banner | If `listDirectory()` failures: warning triangle, “N conversation(s) couldn't be loaded”, “Show in Finder” → `NSWorkspace.activateFileViewerSelecting`. | `ZCodeSidebar.swift` 143–147, 232–267 |
| Pinned | Nested group | Only if ≥1 pinned. Header “PINNED” + `@AppStorage("sidebarPinnedCollapsed")`. | `ZCodeSidebar.swift` 164–175 |
| Unpinned groups | Time buckets | Today / Yesterday / Past 7 days / Past 30 days / Older via `updatedAt`. | `ZCodeSidebar.swift` 177–184, 720–750 |
| Task row | Metadata | **No model chip. No cwd. No work-duration.** Shows: 6 pt status column (running = green filled circle + glow; error = `exclamationmark.triangle.fill` if `statusLine` contains `"error"`; idle = empty), title (empty → “Untitled”), preview = last transcript assistant else user line, chrome-stripped if `cleanModelChrome`, flattened, max 72 chars + “…”, relative time `now` / `Nm` / `Nh` / `yday` / `Nd` / `MMM d`. Selected only when `selectedTab.isWorkspaceTab` (Chat/Code). Hover + selected fill `Theme.Palette.hover`. | `ZCodeSidebar.swift` 396–618, 122–127; `RootView.swift` 122–127 |
| Doc row | §3.11 | 60 pt min, 2-line snippet, selected = `accent.subtle` + 3 pt leading accent bar. Code: ~single-line preview, hover grey, no accent bar. | `UI_DESIGN.md` 371–385 |
| Context menu | 6 actions | Move to project → sheet; Pin / Unpin; Rename (inline TextField, Return commit, Esc cancel, blur commit, select-all); Archive (hides from list); Delete (destructive); divider; Move down (swap `updatedAt` with next same-pin-group row). | `ZCodeSidebar.swift` 438–465; `ConversationCoordinator.swift` 166–187, 154–164 |
| Footer | Delete all + Settings | Full-width rows, not a compact gear. Delete all disabled if empty; alert “Delete all tasks?” / “This will permanently remove all N tasks.” Settings calls `onShowSettings`. | `ZCodeSidebar.swift` 196–227, 269–303 |
| Toolbar New | Duplicate affordance | Window toolbar pencil **and** in-list New Task **and** ⌘N / palette / `/new`. | `RootView.swift` 133–145 |

`SidebarTab.workspaceTabs` = `[.chat]` only. `.code` kept for decode; opening it still shows Chat (`RootView.swift` 510–513).

---

## 4. Navigation model (projects ↔ conversations)

| Region | UI element | Behavior | Evidence |
|---|---|---|---|
| Window model | Single-window tabs | One `WindowGroup` window’s sidebar tabs swap the **detail** pane. Not window-per-project. Not document windows. `WindowGroup` can spawn extra windows via system Window menu; there is no project/conversation scene identity. Replacing `.newItem` makes File → **New conversation**, not New Window. | `VibeCoderApp.swift` 26–67 |
| Selection SoT | Coordinator | `selectedConversationID` binds to `app.selectedConversationID`. On appear, seed first non-archived if nil. | `RootView.swift` 63–68, 280–285 |
| List order | `sidebarOrderedConversations()` | Non-archived; pinned first; then `updatedAt` desc. | `ConversationCoordinator.swift` 198–204 |
| New conversation | Unbound vs bound | `newConversation()`: empty `Conversation`, `modelID = selectedModelID`, insert 0, select, save. `newConversation(in:)` also sets `projectRoot = project.url`. | `ConversationCoordinator.swift` 91–110 |
| Projects tab | Grid | Header “Projects” + “New Project”. Empty: “Looking to start a project?” + folder.badge.plus + CTA (not doc “No projects bound / Bind a folder…”). Cards: folder, name, created date; chevron menu Rename/Delete; **double-click** or context Open → `app.openedProject`. Context also Reveal in Finder. | `ProjectsView.swift` 128–293; `UI_DESIGN.md` 639–647 |
| Project folder | Overlay landing | Back chevron clears `openedProject`. Composer “Start a new chat in this project”; send creates bound convo, `vm.send`, then clears overlay so Chat takes over. List “Chats in this project” filtered by standardized `projectRoot`. | `ProjectFolderLandingView.swift` 1–21, 73–171 |
| Bind from sidebar | `MoveToProjectSheet` | 520×560. Detach row (`projectRoot = nil`), pick existing, or create named project then bind. | `MoveToProjectSheet.swift` 1–51; `RootView.swift` 239–251 |
| Archive vs delete | Visibility | Archive sets `archived = true` and reselects next visible. Delete removes disk + VM + bg jobs. | `ConversationCoordinator.swift` 112–164 |

---

## 5. Menu bar & commands

Custom `.commands` on the `WindowGroup` only. System App / Edit / Window / Help remain.

| Menu | Item | Shortcut | Action |
|---|---|---|---|
| File (replaces `.newItem`) | New conversation | ⌘N | `Notification.Name.newConversationRequested` |
| App (after `.appSettings`) | Settings… | ⌘, | `.settingsRequested` |
| View (`CommandMenu`) | Command Palette | ⌘K | `.commandPaletteRequested` |
| View | Stop Agent | ⌘. | `.cancelAgentRequested` → selected chat `cancel()` |
| View (DEBUG only) | Show Patch Review (debug) | ⌘⇧P | debug sheet |
| View (DEBUG only) | Show Worktree Review (debug) | ⌘⇧W | sample worktree sheet |
| View (DEBUG only) | Show Tasks List (debug) | ⌘⇧T | `TasksListView` sheet |

Evidence: `App/VibeCoderApp.swift` 61–103; handlers `RootView.swift` 287–330.

No other app-level `CommandGroup`s. Settings Close uses `.cancelAction` (Esc). Settings Memory tab has ⌘S locally. Composer Stop uses Esc. New-task landing uses Return.

---

## 6. Global keyboard shortcuts (non-menu)

| Shortcut | Behavior | Evidence |
|---|---|---|
| ⌘N / ⌘, / ⌘K / ⌘. | See §5 | `VibeCoderApp.swift` 63–83 |
| Palette Return | Runs **first** filtered item, dismisses. Esc / click dim dismisses. **No** arrow-key highlight / typeahead ranking. | `CommandPaletteView.swift` 32–36, 107–114 |
| `/settings`, `/config`, `/prefs` | Posts `.settingsRequested` | `SlashCommandService.swift` 207–211; `RootView.swift` 293–296 |
| `/mcps` | Settings with `object` tab id `"mcp"` | `RootView.swift` 25–26, 293–296 |
| `/model` `/m` | Tab Chat + `ModelPickerSheet` | `RootView.swift` 297–300 |
| `/loop` no args | Tab Scheduled | `RootView.swift` 31–32, 301–303 |
| `/export` | ChatView save panel; RootView may switch to Chat / select id; **must not rebroadcast** | `RootView.swift` 37–57, 263–278 |
| `/new` `/home` | New conversation (via ChatViewModel posts) | `ChatViewModel.swift` 2206–2215 |
| Palette claims ⇧Tab | “Cycle Permission Mode … (⇧Tab)” — listed as copy; not an app `.commands` binding | `RootView.swift` 389–392 |
| **Doc** | “Every primary action has a shortcut.” Palette / sidebar search / new-from-doc “New” unlabeled in chrome. | `UI_DESIGN.md` 26, 873 |

---

## 7. Theme system

Applied at `RootView` via `.preferredColorScheme(resolvedColorScheme(app.settings.colorScheme))` where `"light"` / `"dark"` / else `nil` (System). Settings → Appearance (`GeneralSettingsView`) segmented System / Light / Dark + font Small 0.85 / Default 1.0 / Large 1.20 (`chatFontScale`).

| Token / rule | Doc (`UI_DESIGN.md`) | Code (`App/Theme/Theme.swift`) |
|---|---|---|
| Type | Geist Sans + Geist Mono | **SF Pro + SF Mono**. `Font.registerGeist()` is a no-op (`geistAvailable = false`). Comment: DEV PLAN reverted 2026-06-01. |
| Accent | §2.3 Azure `#2563EB` / `#60A5FA`; amendment log later Cobalt `#3385F2` + Ember send `#E75D3C` | **Orange** ≈ `#E48B46` dark / ~rgb(0.89,0.48,0.22) light. Same family for `sendAccent`. Comment: “sampled from ZCode”. |
| Canvas / surface / subtle | Warm paper `#FCFBF8` / `#FFFFFF` / `#F4F2EC`; dark `#181715` / `#22201D` / `#2A2724` | Light ~#F7F7F5 / controlBackground / ~#F0EFEC. Dark **#161616 / #222222 / #2B2B2B**. Text dark **#D2D2D2** not `#F2EFE8`. |
| Semantics | Green/amber/red/info named hexes | Calmer fixed RGB (not dynamic). Plus `violet`, diff greens/reds, `subagentType` blue. |
| Corners | Card 8, sheet 12, button 6, chip pill, bubble 12 | `Theme.Radius` matches those; **input card 18** extra. |
| Motion | quick 150 / standard 250 / gentle 300 / pulse spring / stream 80 | `Theme.Motion` matches. **No** `accessibilityDisplayShouldReduceMotion` usage in repo. **Doc §2.5 / §8** require it. |
| Spacing | 8-pt scale 2…96 | `Theme.Spacing` xxs…xxxl. |
| Shadows | Card 0 1 2; sheets 0 8 24 | Palette has no shadow tokens; palette overlay uses ad-hoc `.shadow` (e.g. command palette radius 24 y 8). |
| Icons | SF Symbols; tab icons 18 medium; vocab `bubble.left`, `wand.and.rays`, `cube` | Live tabs use 12 pt regular; different symbols (see §3). |
| Legacy colors | — | `ColorExtensions.swift` delegates `agentBackground` etc. to Palette. `sidebarBackground` → `muted` (sidebar itself uses `subtle`). |
| Shimmer | — | `ShimmerText`: 3.2 s left→right sweep for status labels. |

Evidence: `Theme.swift` 1–351, 399–413; `ColorExtensions.swift`; `FontExtensions.swift`; `AppearanceSettingsView.swift` 17–114; `RootView.swift` 336–366; `ShimmerText.swift` 11–20.

---

## 8. Onboarding / first run / empty / license

| Flow | Doc | Code |
|---|---|---|
| First launch §6.1 | Onboarding screen 1 Welcome+Hardware → screen 2 Pick starter model → main | **No onboarding views.** Flag forced true; land on RootView. |
| Chat zero-state §5.2 / landing | Centered “What are we working on?” 24 regular secondary; input focused | `NewTaskLandingViewV2`: outline monogram 88, **“Start a new task”** 24 semibold, “Click the button below to begin. Your new task will appear in Recents.”, 84 pt + circle, “Or press ↩ Return”. |
| Sidebar empty §4.6 | “No conversations yet. ⌘N to start one.” | “No tasks yet” (no shortcut hint). |
| Projects empty §4.6 | “No projects bound. Bind a folder…” | “Looking to start a project?” + New Project capsule. |
| Skills empty §4.6 | “182 bundled skills…” | Skills tab **gone**; Notes empty: “No notes yet” / “Click + to create one…” |
| Models empty §4.6 / §4.7 | “No models downloaded yet. [Browse catalog]” + Library/Discover HF browser | Models pane: backend card + “No models reported. Start Ollama or oMLX… then Refresh.” No catalog. |
| Scheduled | (not in §4.6) | “No schedules yet” + in-app-only caveat + New schedule. |
| License §4.3 Tab 4 / §6.6 | Trial/activate/buy sheet; Privacy & License | **No license UI** in `App/Views/Settings`. Privacy tab is “Data & backup”. `ARCHITECTURE.md` / `README.md`: MIT, no keys/trials. |

Evidence: `VibeCoderApp.swift` 4, 46–52; `NewTaskLandingViewV2.swift` 52–135; `ZCodeSidebar.swift` 150–157; `ProjectsView.swift` 176–221; `NotesLandingView.swift` 233–248; `ModelsLandingView.swift` 87–90; `ScheduledLandingView.swift` 90–126; `SettingsViewV2.swift` 14–32.

Settings sheet (window-level): ideal **980×700**, min 920×620, max 1100×820, nav 228. Search filters tab list. Close prominent. Deep-link `initialTabRaw`. **Doc §4.3:** 720×520, 5 tabs.

---

## 9. Command palette

Trigger: ⌘K / View → Command Palette / `.commandPaletteRequested`. Overlay in RootView ZStack. **Not specified in `UI_DESIGN.md`.**

| Element | Behavior | Evidence |
|---|---|---|
| Chrome | 35% black dim (tap dismiss), 520 wide, 12 continuous radius, `surface` fill, 0.5 divider stroke, shadow 24/8 | `CommandPaletteView.swift` 22–67 |
| Search | Placeholder **“Search commands…”**, focus on appear, query cleared each open | 28–36, 68–71 |
| Filter | Trim + lowercased; empty → all items in listed order. Else substring in title, subtitle, category, or any keyword | `CommandPaletteFilter.swift` 17–27 |
| Empty | “No matching commands” | `CommandPaletteView.swift` 43–47 |
| Row | Title 14 medium, subtitle 11 tertiary, category capsule 10 semibold | 75–105 |
| Run | Click or Return-first; then dismiss | 76–78, 107–111 |

Hard-coded items (`RootView.commandPaletteItems` 374–423):

| id | Title (dynamic) | Category | Effect (`runCommandPaletteItem`) |
|---|---|---|---|
| new-chat | New Conversation | Chat | `newConversation()` + tab Chat |
| clear-chat | Clear Conversation | Chat | `/clear` |
| compact | Compact Conversation | Chat | `/compact` |
| session-info | Session Info | Chat | `/session-info` → `statusLine` |
| fork-chat | Fork Conversation | Chat | `/fork` |
| toggle-safe-mode | Enable/Disable Safe Mode | Safety | If Plan → `.build`; else toggle `safeModeOn` |
| cycle-mode | Cycle Permission Mode | Safety | `cycleExecutionMode()` |
| mode-plan | Plan Mode | Safety | `executionMode = .plan` |
| open-settings | Open Settings | App | settings sheet |
| open-projects | Projects | App | tab Projects |
| open-scheduled | Scheduled Tasks | App | tab Scheduled |
| choose-model | Choose Model | Model | tab Chat + `ModelPickerSheet` (min 420×200) |

No palette entries for Notes, Models, Cluster, Export, New Project.

---

## 10. Window-level extras

| Extra | Behavior | Evidence |
|---|---|---|
| Notifications | `NotificationService.shared`. Kinds: completed (silent), looped / budgetExceeded / streamFailed (default sound). Titles `"VibeCoder task complete"` etc. Lazy `UNUserNotificationCenter` auth `.alert+.sound`. Skip if `NSApp.isActive` unless `bypassFrontmostCheck` (headless). Master `settings.notificationsEnabled` (default true; Appearance toggle). Posted from `ChatViewModel.notifyTerminal`. | `App/Services/NotificationService.swift`; `AppearanceSettingsView.swift` 114–124; `ChatViewModel.swift` 2105–2116 |
| Sleep | `SleepAssertionService`: `kIOPMAssertPreventUserIdleSystemSleep` while `beginHeadlessRun` refcount > 0. Display may dim. Released on last headless end / deinit. Reason: `"VibeCoder — scheduled tasks running"`. | `SleepAssertionService.swift`; `AppViewModel.swift` 138, 238–246 |
| Multi-window | No extra scenes. Additional `WindowGroup` instances possible via system Window menu; they each create a **new** `@StateObject AppViewModel` (not shared). No window-per-project. | `VibeCoderApp.swift` 12, 26 |
| Background / quit | Sleep assertion session-only. Scheduler starts in `boot()` (`conversationsCoordinator.startScheduler()`). Local API / Xcode MCP start if settings flags. | `AppViewModel.swift` 250–287 |
| Sheets on RootView | Settings; Model picker; debug Patch/Worktree/Tasks; Move-to-project | `RootView.swift` 204–251 |
| Open conversation | `.openConversationRequested` with UUID → select + Chat tab (used by Scheduled “view last run”) | `RootView.swift` 14–16, 317–321 |
| Open Models pane | `.openModelsPane` closes settings, tab Models | `RootView.swift` 304–307 |
| Cluster | Detail exists; **no live sidebar row**. If tab is cluster and backend ≠ exo, forced back to Chat. | `RootView.swift` 258–261, 521–522 |
| Tasks list | Full search UI exists but only DEBUG ⌘⇧T sheet, not a nav tab | `TasksListView.swift`; `VibeCoderApp.swift` 98–101 |
| Work duration | `WorkDurationFormat` is chat working-header copy, **not** sidebar metadata | `WorkDurationFormat.swift` |
| Reduced motion / contrast | Specified in §2.5 / §8; **no implementation** found | grep over `*.swift` |

---

## Live vs unused (quick)

| Symbol | Role |
|---|---|
| `ZCodeSidebar` | **Live** sidebar |
| `SidebarShell` + `EngineReachabilityProbe` | Compiled; unused by RootView (probe reused conceptually in Settings Model & Backend) |
| `ConversationCoordinator` | **Live** list/CRUD/selection |
| `ConversationListViewModel` | Unused |
| `NavigationState` | Unused |
| `DetailPlaceholder` / `EmptyDetailView` | Unused wrappers |
| `MockPickerData` popover in RootView | Dead type still in file; toolbar chip removed |

---

## Highest-signal doc/code drifts (shell only)

1. Onboarding + license specified, **retired/absent** in code.  
2. Accent/type: Azure+Geist vs **orange + SF**.  
3. Sidebar: 4 icon tabs + search + engine vs **workspace header + 5 text nav + Tasks tree**.  
4. Responsive icon-only sidebar + 1280×800 default: **not in code**.  
5. Focus rings required vs **explicitly stripped**.  
6. Command palette is a real global surface **not in UI_DESIGN**.

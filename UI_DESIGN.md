# UI DESIGN — VibeCoder 1.0.5

> Sibling document to `ARCHITECTURE.md`. Architecture says *what* exists; this says *how it looks, feels, and behaves*. **Live SwiftUI is the source of truth.** When a later PR disagrees with this file, amend §11 — do not invent Azure/Geist chrome that is not on screen.
>
> Read in order: §1 (principles) → §2 (foundations) → §3 (components) → §4 (screens) → §5 (states) → §6 (flows). Skim §7–§10 for reference. Sign off after §11.
>
> Identity (locked 2026-08-16): **orange accent + SF Pro / SF Mono**. Local-model-first. No onboarding, no license/trial chrome.

---

## 1. Design principles

Four locked decisions, updated to what 1.0.5 actually ships:

1. **Visual density: Claude.ai-spacious.** Generous whitespace, comfortable line height, large-ish text. Calm enough for 4-hour sessions. Built for big screens; graceful at the 960 × 620 minimum.
2. **Aesthetic: polished + warm.** System typography (SF Pro for UI and prose, SF Mono for code/data), one signature orange, subtle decorative touches only when they communicate something. Not minimalist-cold, not consumer-busy. Voice: “the senior engineer who keeps their workspace nice.”
3. **Color: single accent + neutrals.** One orange accent (§2.3). Grayscale everywhere else. Semantic green/red/amber/blue reserved for status. Dark-mode parity is enforced — every token has both appearances.
4. **Animation: restrained delight.** Functional motion as the baseline; signature moments only where they communicate state (shimmer on “Working…”, send-circle fill). 150–300 ms easeOut for most, spring for pulses. **Reduced motion:** `Theme.Motion` tokens query `NSWorkspace.accessibilityDisplayShouldReduceMotion` and collapse to zero-duration when set.

The principles that fall out:

- **Predictability over surprise.** Same gesture, same result, every time.
- **Latency disguised as design.** While the model thinks, fill the time with information (Working header, reasoning block, `Verb · Status` rows) — never a blank wait.
- **One affordance per action.** No button that does three things. Composer chips are single-purpose.
- **The model is the product.** Chrome (sidebar, settings, palette) gets out of the way during chat. Conversation typography is the centerpiece.
- **Hierarchical, never flat.** Every screen has primary / secondary / tertiary information.
- **Errors are conversation, not interruption.** Recoverable issues are dismissable banners or activity **Failed** rows. Approval sheets are the exception (fail-closed).
- **Keyboard is first-class.** File → New conversation (⌘N), Settings (⌘,), Command Palette (⌘K), Stop (⌘.), Esc dismisses sheets / stops generation.
- **Local-model-first.** First-run lands on the main window. Empty chat is a model-connect hero (loopback detect + **Open Connection settings**), not a download wizard and not a license gate.

Removed from the 2026-06 spec (do not resurrect): license/trial sheets, two-screen onboarding, Geist type, Azure/Cobalt accent, 4-icon sidebar tabs, icon-only sidebar collapse, per-hunk Accept/Reject, in-transcript ToolStub + PlanCard, docked iteration status bar.

Sources: `App/VibeCoderApp.swift`, `App/Theme/Theme.swift`, `App/Theme/FontExtensions.swift`

---

## 2. Visual foundations

### 2.1 Typography

Product type is **SF Pro** (`.system`, design `.default`) + **SF Mono** (design `.monospaced`). `Font.registerGeist()` is a no-op; `Font.geist(...)` stubs to system. Never mix `.serif` (no New York) into chrome or transcript.

| Role | Family | Size | Weight | Used for |
|---|---|---|---|---|
| **Display** | SF Pro | 32 pt | Semibold | Reserved scale (`Theme.Typography.display`); unused in live chrome |
| **Hero** | SF Pro | 24 pt | Semibold | New-task landing title; Models / Projects pane titles |
| **Title** | SF Pro | 20 pt | Semibold | Empty-chat hero titles |
| **Body** | SF Pro | 15 pt | Regular | Transcript prose, composer field (`ChatLayout.bodyFontSize`) |
| **Body emphasis** | SF Pro | 15 pt | Semibold / Medium | Section labels, button text |
| **UI** | SF Pro | 13 pt | Regular / Medium / Semibold | Sidebar rows, chips, dense chrome |
| **Caption** | SF Pro | 12 pt | Regular | Secondary labels |
| **Caption emphasis** | SF Pro | 12 pt | Medium / Semibold | Status, small badges |
| **Mono body** | SF Mono | 13 pt | Regular | Code blocks, tool I/O |
| **Mono small** | SF Mono | 12 pt | Regular | Paths, model IDs, hunk headers |

Ad-hoc 10 / 11 / 12.5 pt appear on timestamps, badges, and composer chips. Appearance scales chat type via `chatFontScale` (0.85 / 1.0 / 1.20). Markdown headings stay SF Pro (`markdownHeading(level:)`).

### 2.2 Spacing

8-pt base. Named scale in `Theme.Spacing`:

```
xxs 2    xs 4    s 8    m 12    ml 16    l 24    xl 32    xxl 48    xxxl 64
```

Inline icon↔text 6–8; row/card pad 12–16; section 24. Chat gutters 24–96 (6% of pane). Composer: 14 H / 14 V / 18 bottom lift. Transcript: 12 message gap, 20 after user, 8 before assistant. `96` is `ChatLayout.maxSideGutter`, not a Spacing token.

### 2.3 Color

Tokens below map 1:1 to `Theme.Palette`. Names keep the design-token convention; implementations are the `Palette.*` properties.

**Light mode**

| Token | Value | Usage |
|---|---|---|
| `bg.canvas` | `#F7F7F5` | Main chat / detail pane |
| `bg.surface` | system `controlBackground` (≈ `#FFFFFF`) | Cards, sheets, elevated chrome |
| `bg.subtle` | `#F0EFEC` | Composer card **and** sidebar (same plane) |
| `bg.muted` | `#F0EFEC` | Legacy elevated fill; prefer `bg.subtle` |
| `bg.hover` | black @ 5% | Selected / hover rows |
| `bubble.user` | black @ 6% | User message pill |
| `fg.primary` | `#1F1F1F` (white 0.12) | Body, titles |
| `fg.secondary` | `#595959` (white 0.35) | Captions, metadata |
| `fg.tertiary` | `#808080` (white 0.50) | Timestamps, idle chrome |
| `fg.muted` | `#8C8C8C` (white 0.55) | Placeholders |
| `divider` | black @ 8% | Hairlines |
| `accent` | `#E37A38` (rgb 0.89, 0.48, 0.22) | Signature orange — buttons, New Task, send |
| `accent.hover` | `#D16B2E` | Pressed / darker orange |
| `accent.subtle` | accent @ 12% | Tinted fills (workspace folder chip, open menus) |
| `semantic.success` | `#6BAD7D` | Ready, accepted, +lines |
| `semantic.warning` | `#D1B36B` | Non-fatal warnings |
| `semantic.error` | `#C97A7A` | Failures, Discard, stop-adjacent |
| `semantic.info` | `#7A9EBF` | Informational |
| `violet` | `#A68CD1` | Capability chips (tool / reason / vision) |
| `subagent` | `#337AD9` | SubAgent type label |

**Dark mode** — same roles, ZCode-sampled neutrals (soft gray text, not pure white):

| Token | Value |
|---|---|
| `bg.canvas` | `#161616` |
| `bg.surface` | `#222222` |
| `bg.subtle` | `#2B2B2B` |
| `bg.muted` | `#353535` |
| `bg.hover` | white @ 6% |
| `bubble.user` | white @ 6% |
| `fg.primary` | `#D2D2D2` |
| `fg.secondary` | `#9A9A9A` |
| `fg.tertiary` | `#797979` |
| `fg.muted` | `#6E6E6E` |
| `divider` | white @ 8% |
| `accent` | `#E48B46` |
| `accent.hover` | `#F59447` |
| `accent.subtle` | accent @ 14% |
| `semantic.*` / `violet` | same fixed RGB as light (not dynamic) |
| `subagent` | `#73ADF2` |

**Diff tokens** (chat edit cards, worktree, patch sheet): `diffAdd` `#6BCB8D`, `diffRemove` `#E07A7A`, fills @ 14% (`diffAddBg` / `diffRemoveBg`). Body text variants `#B8E6C8` / `#E8B0B0`.

`sendAccent` is the same orange as `accent`. Sampled from ZCode Full-access / send; Azure `#2563EB` and Cobalt/Ember are **retired**. Activity: verb = accent, status = secondary. Reasoning rail: accent @ 55% (live @ 85%).

### 2.4 Corners + shadows

| Use | Radius | Shadow |
|---|---|---|
| Cards, settings rows | 8 pt (`Radius.card`) | Hairline `divider` 0.5; no tokenized drop shadow |
| Sheets / palette / planner | 12 pt (`Radius.sheet`) | Palette: 0 8 24 black @ 20% |
| Composer input card | **18 pt** (`Radius.inputCard`) | 0 12  (focused: 0 18 8) black @ 10–12% |
| Chips, badges | pill (`999`) | none |
| Buttons | 6 pt | none |
| Code blocks | 6 pt | none — header/body fill only |
| User message pill | **16 pt** (live; `Radius.bubble` token is still 12) | none |
| Inline edit card | 12 pt continuous | hairline |
| Question card | 14 pt | accent stroke @ 25% |

### 2.5 Motion

| Name | Duration | Curve | Used for |
|---|---|---|---|
| `quick` | 150 ms | `easeOut` | Hover, button press, copy flash |
| `standard` | 250 ms | `easeOut` | Sheets, tab switch |
| `gentle` | 300 ms | `easeInOut` | Disclosure, patch file expand |
| `pulse` | spring | response 0.4, damping 0.65 | Chip / status pulses |
| `stream` | 80 ms | `easeOut` | Token insertion |

Sidebar column visibility uses a slightly longer spring (`response: 0.38, dampingFraction: 0.88`). Shimmer on live Working / Thinking labels is a 3.2 s left→right sweep (`ShimmerText`).

**Open item:** no call site reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (or increase-contrast). Documented in §8.

Animation budget: nothing longer than 350 ms unless it is communicating ongoing state (shimmer / pulse).

### 2.6 Iconography

SF Symbols only. Sidebar tabs are **12 pt regular** (not the old 18 medium). Composer chips 11–13 medium; timestamps 10–11; empty heroes 28–56; workspace folder 12 pt in a 28 pt accent-subtle tile.

| Region | Symbols |
|---|---|
| Sidebar nav | Chat `bubble.left.and.bubble.right` · Projects `folder` · Models `cpu` · Notes `note.text` · Scheduled `calendar.badge.clock` |
| Sidebar chrome | Workspace `folder.fill` + decorative `chevron.up.chevron.down` · New Task / attach `plus` · Settings `gearshape` · Delete `trash` · toolbar new `square.and.pencil` |
| Composer | Send `arrow.up` · Stop `stop.fill` · Think `brain.head.profile` · Web `globe` · Chat `bubble.left.and.bubble.right` · Agent `wrench.and.screwdriver` · Plan/Ask/Auto/Full `doc.text.magnifyingglass` / `shield.lefthalf.filled` / `pencil.and.ruler` / `bolt.fill` |
| Transcript | Explore `magnifyingglass` · Read `book` · Write `pencil` · Edit `pencil.and.outline` · Run `terminal` · Build `hammer` · Manage `folder` · Search `globe` · Ask `questionmark.bubble` · SubAgent `shippingbox` · Undo `arrow.uturn.backward` · error `exclamationmark.triangle.fill` |
| Other | Worktree `arrow.triangle.branch` · palette `magnifyingglass` · settings header `gearshape.2.fill` |

Retired: `bubble.left`, `wand.and.rays`, `cube`, composer `lock.shield`, ToolStub `arrow.right.circle.fill`.

Sources: `App/Theme/Theme.swift`, `App/Theme/FontExtensions.swift`, `App/Theme/ShimmerText.swift`, `App/Views/Sidebar/SidebarShell.swift` (`SidebarTab`), `App/Views/Sidebar/ZCodeSidebar.swift`

---

## 3. Component library

Mounted blocks only. Unmounted leftovers (`ToolCallView`, `ThoughtProcessBlock`, `SidebarShell`, `ProcessingStatusBar`, `ZCodeStatusBar`, `PermissionsSheetView`) are not spec. New components need a §11 amendment.

### 3.1 Chip

Pill used for execution mode, Chat/Agent, thinking effort, model picker.

```
┌──────────────────┐
│ ⊙ Ask            │
└──────────────────┘
```

- Height ~26 pt; padding 8 H × 5 V; capsule.
- Default: `fg.secondary`, **no fill**. Accent foreground + `accent.subtle` fill **only while the upward menu is open** — never a permanent per-mode color.
- Trailing chevron (`chevron.up.chevron.down`, 8 pt) on thinking + model chips.
- Disabled while the agent is running (mode / think).
- Model chip: pretty-printed name, or **“No model”** / **“Select model”**.

### 3.2 StatusDot

```
●  (6 pt filled circle — sidebar task row)
```

| State | Treatment |
|---|---|
| Running | 6 pt `semantic.success` + soft glow |
| Error | `exclamationmark.triangle.fill` (`statusLine` contains `"error"`) |
| Idle | empty 6 pt slot (no tertiary dot) |

Connection / Local API panes use a similar ready/stopped dot. Capability badges may use `violet`. Do **not** put a status dot on the model chip.

### 3.3 Card

**Default:** `bg.surface`, 8 pt radius, 0.5 `divider` hairline, 12–16 pt padding.

**Subtle / input:** `bg.subtle`, 18 pt radius on the composer only.

**Disclosure:** header row toggles body; chevron rotates; `gentle` animation.

**Workspace header:** 10 pt radius, `bg.hover` fill, 28 pt accent-subtle folder tile.

### 3.4 Banner

Non-modal, top of the chat column.

- Model-load error: `semantic.error` text + 8% tint, warning triangle, dismiss `xmark`.
- Unloadable conversations (sidebar): warning triangle, **“N conversation(s) couldn't be loaded”**, **Show in Finder**.
- Goal / stall / pause: `GoalStatusBanner` from `goalStatusText`.
- Background shell: **Background shell** + command + **Kill**.
- Transcript notices (`TranscriptNoticeCard`): compaction, goal, bg job, build verify — dismiss ×.

No “trial expires” / license banners.

### 3.5 MessageBubble

**User** — right-aligned pill, wrap cap **560 pt**, leading gutter 96. Fill `bubble.user` (neutral 6%, **not** `accent.subtle`). Radius 16, pad 14/10. Plain `Text` (no markdown), selection on. Hover **Copy** under the trailing edge.

**Assistant** — left, full column, **no bubble**. Chronological run: thought → tools → prose; consecutive assistants group into one turn. Markdown via `MarkdownTextView` (h1–6, p, fenced code, lists, tables, quote, hr; inline bold/italic/links/code). Hover **Copy** under the final answer (leading).

**Code block:** LANG + **Copy**/**Copied**; scrollable mono; dark fills ≈ `#1F1F1F`/`#141414`. **Wave U1:** `SyntaxHighlighter` keyword tables (~15 languages). Patch hunks stay unhighlighted.

### 3.6 ActivityRow (`Verb · Status`)

Replaces the retired ToolStub (`→ toolName  args≤60`).

```
  ⌕  Explore  ·  src/Auth.swift
  ✎  Edit     ·  1 edit
  [box] SubAgent  general-purpose  ·  list downloads
```

13 pt. Verb `accent` semibold · middot `fg.tertiary` · status `fg.secondary`. Copy: **Queued…** / ArtifactLabel / **Failed** / `1 file` · `1 command` · `1 edit` · `search done`. Running: mini ProgressView. Expand → Input/Output (600/800 cap + **Show full I/O**); `list_directory` → table. Consecutive non-edit tools collapse under **Tools · {summary}** (`N · M running` / `failed` / `N completed`); auto-expand while live. SubAgent: `shippingbox` + type in `subagent` blue + **Kill** while running. File edits use §3.7.

### 3.7 InlineEditCard

```
  ▾  App/Views/ChatView.swift     Applied    +24  −3    [Undo]
     │ − old line
     │ + new line
```

Path (12.5 mono) · status / **Undone** · `+N` `−M` · chevron. Expand → `CodeDiffBlock` (tinted `+`/`−`, cap 40). Auto-open if running or has removals. **Undo** when `hunk_id` present. Surface 12 pt, `bg.surface` + hairline.

**Wave U1 — turn-end change summary** (`TurnChangeSummaryView`): one card after a mutating turn (paths + +/−). **Review** opens the existing diff; **Undo** posts rewind / hunk-reject. Complements per-file Undo.

### 3.8 PatchFile

Per-**file** decision row in the Review patch sheet. Hunks are display-only.

- File header: chevron, `doc.text`, mono path, hunk-count capsule, **Reject** / **Accept** (toggle back to pending).
- 3 pt leading bar: divider / success / error by decision.
- Hunk: `@@ … @@` on `accent.subtle`; unified +/−/context at 10% semantic tint; 12 pt mono; **no line numbers**; **no syntax highlight**.
- **Intentionally no per-hunk Accept/Reject.** AgentCore applies whole files; hunk buttons would lie about granularity.

### 3.9 Button

| Variant | Treatment | Use |
|---|---|---|
| **Primary** | `accent` fill, white label (`PrimaryButtonStyle` / `.borderedProminent` tinted accent) | Apply selected, Accept, Approve & Run, Close (settings), Once |
| **Secondary** | bordered / `bg.muted` | Accept all, Always, Stay in Plan |
| **Plain** | transparent, `fg.primary` / secondary | Continue, Expand all, Cancel |
| **Destructive** | `semantic.error` text | Reject, Discard, Delete, Never |
| **Icon circle** | 32 pt circle | Send (`accent` if draft non-empty, else muted disabled); Stop (red `stop.fill`) |

Composer send is the circular icon, **not** a labeled “Send ↑”. Settings Close is prominent accent, Esc / `.cancelAction`.

### 3.10 InputBar (`InputBarViewV2`)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Ask for follow-up changes                                            │
│                                                                      │
│ [+] [Ask ▾] [🌐] [ Agent ]  ██ 23/32.8k · 0%     [brain Medium] [Select model ▾] (↑) │
└──────────────────────────────────────────────────────────────────────┘
```

- Fluid card, **18 pt** radius, `bg.subtle` + shadow; drop-target hairline.
- Control is SwiftUI **`TextField(..., axis: .vertical)`** — not `TextEditor`.
- Editor min 36 / max 100 / max 6 lines; card min height 76.
- Placeholder idle: **“Ask for follow-up changes”**. Running: **“Keep typing to queue a follow-up…”**.
- Keys: Return send; Shift+Return newline; ↑/↓ prompt history (or slash/mention nav); Esc clears slash draft.
- **Left chips:** `plus` (NSOpenPanel **Attach files or folders**) · mode chip (Plan / Ask / Auto / Full) · web `globe` · Chat/Agent capsule · context meter.
- **Right chips:** thinking (`brain.head.profile` + Off/Low/Medium/High/Max, only if `ThinkingCapability`) · model chip · send/stop circle.
- Running + non-empty draft: red Stop **and** accent **Send interjection** (mid-turn steer, not a queued next user turn).
- @ mentions: popup **“@ context — ↑/↓ Enter pin · Esc dismiss”**. Slash: upward menu of 30+ commands.

### 3.11 Sidebar Row

```
  ●  Please implement login                         4h
     previous answer
```

- 6 pt status slot + title (1 line, empty → **Untitled**) + preview (1 line, 72 chars + “…”) + relative time (`now` / `Nm` / `Nh` / `yday` / `Nd` / `MMM d`) at 10 pt tertiary.
- Preview = last visible assistant (chrome-stripped) else last user.
- Selected / hover: 8 pt `bg.hover` fill. **No** accent leading bar. **No** 2-line snippet.
- Context menu: Move to project · Pin/Unpin · Rename · Archive · Delete · Move down.
- Rename is an inline `TextField` (Return commit, Esc cancel, blur commit).

### 3.12 QuestionCard + approval sheet

`ask_user` is an inline card **above the composer** (not an alert): 16 pt question, option capsules, **Type your answer…** / **Or type a custom answer…**, queue badge **N more question(s) waiting**.

`ShellApprovalSheet` titles: **Allow shell command?** / **Dangerous command** / **Allow MCP tool?** / **Allow subagent?** / **Allow {tool}?** Reason + mono detail. **Once** / **Always** · **Never** / **Deny**. Dangerous: Always/Never disabled — **Dangerous commands are never remembered — Always acts as Once.** Esc/dismiss → deny + drain.

**Wave U1:** **Allow for session** (`SessionGrantStore`); Tab/arrows + Enter; prefix chips; subagent origin line. Existing four buttons and dangerous rules stay.

Sources: `App/Views/Chat/InputBarViewV2.swift`, `MessageBubbleViewV2.swift`, `ZCodeActivityLineView.swift`, `InlineEditCardView.swift`, `CodeBlockView.swift`, `PatchReviewSheetV2.swift`, `QuestionCardView.swift`, `ShellApprovalSheet.swift`, `App/Views/Sidebar/ZCodeSidebar.swift`

---

## 4. Screens

### 4.1 First launch (no onboarding)

Onboarding Screen 1 (Welcome + Hardware) and Screen 2 (Pick a starter model) are **retired**. `VibeCoderApp` forces `hasCompletedOnboarding = true` and paints `RootView`.

1. Brief clear splash while `SettingsStore` loads.
2. Main window (min 960 × 620). No default size is set — first-open size is AppKit/SwiftUI default (the old “opens at 1280 × 800” is not implemented).
3. After the conversation store loads, the first visible task is created automatically (same as ⌘N) so the first screen is the empty-chat hero (§4.6) + composer — not a plus-button landing. If no backend is up: **Connect a model server** + **Open Connection settings** / loopback **Use**.

License / trial lock screens do not exist (MIT; no key field).

### 4.2 Main window

Single `NavigationSplitView` (sidebar + detail). No inspector column. No width-based collapse.

```
┌──────────────────┬────────────────────────────────────────────────────┐
│ [📁] Default     │  Please implement login                        ▾   │
│     Workspace    │                                                    │
│ Chat             │           [VB outline]                             │
│ Projects         │        Pick a model to start                       │
│ Models        15 │        Detected on this Mac                        │
│ Notes            │        ● Ollama          :11434   Use              │
│ Scheduled        │                                                    │
│ TASKS          ▾ │                                                    │
│ + New Task       │  ┌──────────────────────────────────────────────┐  │
│ Yesterday        │  │ Ask for follow-up changes                    │  │
│  Please impl… 4h │  │ +  Ask  🌐  Agent  23/32.8k · 0%   Select ▾ ↑│  │
│                  │  └──────────────────────────────────────────────┘  │
│ Delete all       │                                                    │
│ Settings         │                                                    │
└──────────────────┴────────────────────────────────────────────────────┘
```

**Chrome:** `WindowGroup`, empty title, unified toolbar, transparent titlebar, `fullSizeContentView`. Min 960 × 620. Sidebar 240 / 280 / 360, `bg.subtle`. Toolbar = system sidebar toggle + `square.and.pencil` only (**no** model/search/settings chips). Detail: Chat (legacy `.code` too), Projects, Models, Notes, Scheduled, Cluster (EXO backend only: read-only `/state` + pin Model ID). `openedProject` overlay wins.

**ZCodeSidebar**

1. **Workspace header** — folder tile + name (`openedProject` / last path component / **Default Workspace**) + mono 10 path + decorative chevron. Tap → Projects.
2. **Primary nav** (text rows, 12–12.5 pt): Chat / Projects / Models (count capsule when `availableModels > 0`) / Cluster (EXO only) / Notes / Scheduled. Selected = `bg.hover` 8 pt rect, **no** accent underline.
3. **TASKS** disclosure (10 pt bold small-caps, tracking 0.8) + accent **+ New Task**. Collapse persists in `@AppStorage("sidebarRecentsCollapsed")`.
4. **Pinned** disclosure (if any), then time buckets: Today · Yesterday · Past 7 days · Past 30 days · Older.
5. **Footer:** **Delete all** (alert **Delete all tasks?** / **Delete All**) + **Settings**.

New Task / ⌘N / toolbar immediately create + select a conversation. After store load, a first task is seeded if Recents is empty so first-run is the connect-hero, not `NewTaskLandingViewV2`.

**Chat surface:** slim title + chevron → Rename, Duplicate, Export/Copy as Markdown, Isolate work in git worktree / Review worktree… / Edit main tree…, Delete. **Edit main tree…** persists worktree opt-out (later sends stay on the main checkout); it does not discard the disk worktree — Merge/Discard stay on the review sheet. A **Worktree** chip (when isolated) or **Isolate in worktree** (when a folder is bound) sits on the title row so merge/review is not header-menu-only. LAN / phone QR remote control is off — not in the title menu. No header model/project/Safe pills. Transcript + composer share `contentWidth` (320–1040, gutters 24–96). Live turn: **Working for Ns** / **Worked for Ns** (seconds, then whole minutes) → orch caption → `ReasoningBlockView` (**Thinking · Ns** / **Thought for Ns** / **Thought**) → activity / edit cards → answer. Plan is a **floating** 200–320 card (`StickyPlannerView`): STEPS/COMPLETE + todos; idle Plan + todos show **Review checklist, then Approve to implement (Ask mode) or Stay in Plan.** · **Stay in Plan** / **Approve & Run**. `ask_user` sits above the composer; patch / approval / worktree are sheets.

### 4.3 Settings sheet

Modal sheet on `RootView` (⌘,, sidebar **Settings**, palette, `/settings`). **Not** a `Settings` scene.

- Size: min 920 × 620, ideal **980 × 700**, max 1100 × 820. Nav column 228.
- Header: gear tile + **Settings** / **Configure VibeCoder for your Mac** + **Search settings**.
- Footer: **Close** (Esc). Default tab: **Agent**. Deep-link via `initialTabRaw` (`connection`, `mcp`, …).

**11 tabs in 4 groups** (`SettingsTab`):

| Group | Label | `rawValue` | Icon | Subtitle |
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

**What they host:** Agent = system-instructions editor. Connection = LM Studio / EXO / oMLX / Ollama / Unsloth / Custom / Local API (+ Xcode MCP) — no llama.cpp spawn, no MLX pane. Model & Backend = engine strip + Two-Model Mode (**no** load/sampling sliders). MCP = list/probe/OAuth. Tools = Plan/Ask/Auto/Full, Safe/Headless, seatbelt, verify, Chat mode, allow-lists, grants. Context = max tokens + compact slider. Memory = MEMORY.md / DECISIONS.md. Appearance = theme + type + notifications. Privacy = issue link + export/import/clear (**no license**). Advanced = clean model chrome. About = version + credit (**no Sparkle**).

**Wave U1 — Hooks** (`hooks`, Workspace, “Lifecycle scripts”): `HooksSettingsView` + `HooksConfigStore`. Seven events (matcher / command / args / timeout / background) at project `.vibecoder/hooks.json` and user `~/.vibecoder/hooks.json`. Applies to **new sessions**.

Retired 5-tab set: General / Connection / Models (load+inference) / Privacy & License / About.

### 4.4 Patch Review Sheet

Trigger: Ask mode (`ExecutionMode.build`) + `apply_patch` → `PatchReviewCoordinator.pendingBatch`. Esc / dismiss = reject all (fail-closed).

```
┌ Review patch                          [Reject all] [Accept all] ┐
│  N files · M hunks (read-only) · K of N files decided           │
│  ▾  Sources/…/ReadFile.swift          1 hunk   [Reject][Accept] │
│     @@ -42,7 +42,7 @@                                           │
│     − do { data = try Data(contentsOf: url) }                   │
│     + do { data = try Data(contentsOf: url, options: .mapped) } │
│                         [Cancel]  [Always allow folder] [Apply selected] │
└─────────────────────────────────────────────────────────────────┘
```

- min **760 × 540** (not 880 × 640).
- Status: `N files · M hunks (read-only) · K of N files decided`.
- Footer: **Cancel** · **Always allow folder** (optional, `RememberedGrants`) · **Apply selected** (disabled if 0 accepted) · “N files will be applied”.
- **Decision (locked):** file-level only. Per-hunk Y/N, ⌘A/⌘R, ←/→ hunk step **removed** because apply is per file.

### 4.5 Worktree Review Sheet

Header worktree toggle **on** → enable; **off tap** → this sheet (`git status` / `diff`).

- 720 × 600. Title **Worktree review** + branch mono. **Expand all** / **Collapse all**.
- Rows: kind icon + path + new/deleted/modified pill + +N −M; expand inline +/− diff (no syntax highlight).
- Commit field **“Commit message…”**. Actions: **Continue** (dismiss) · **Discard** (confirm) · **Merge into main** (⌘↩, confirm). Errors: alert **Worktree error** / OK.

### 4.6 Empty states

| Surface | Copy |
|---|---|
| Sidebar tasks | **No tasks yet** (12 pt tertiary). No ⌘N hint, no bubble icon |
| Zero conversations (detail) | Outline mark 88 · **Start a new task** 24 semibold · **Click the button below to begin. Your new task will appear in Recents.** · 84 pt + circle · **Or press ↩ Return** |
| Chat, no backend | Outline 112 · **Connect a model server** · **Start LM Studio, Ollama, oMLX, Unsloth Studio, or EXO on this Mac, then open Settings → Connection and Test.** · **Detected on this Mac** rows (**Use**) · **Open Connection settings** |
| Chat, backend, no selection | **Pick a model to start** · **Use the model chip in the composer (bottom-right) to select a tool-capable coding model.** |
| Chat, model ready | **What are we working on?** · **Bind a project folder, describe a task, and the agent will plan, edit, and verify on your machine.** |
| Projects | **Looking to start a project?** + `folder.fill.badge.plus` + **New Project** capsule |
| Notes | **No notes yet** / **Click + to create one. Notes are markdown — …** |
| Scheduled | **No schedules yet** + in-app-only caveat + **New schedule** |
| Models | **No models reported. Start Ollama or oMLX (or another backend), then Refresh.** |
| Palette | **No matching commands** |
| Settings search | **No matching settings** |

Retired empty copy: “No conversations yet. ⌘N to start one.” / “No projects bound.” / “182 bundled skills.” / “No models downloaded yet. [Browse catalog]”.

### 4.7 Models pane

`ModelsLandingView` — **not** Library / Discover / HuggingFace.

- Header **Models** + **Refresh**. Blurb: models come from the active HTTP backend.
- Active-backend card + selected id. Rows: display name, wire id, **Use** / **Active**.
- Catalog.json, GGUF download lifecycle, split-file SHA, hardware-fit badges: **not implemented**. Cluster/EXO catalog lives in `ClusterView`, mounted in the sidebar when EXO is the active backend.

### 4.8 Command palette

⌘K / View → Command Palette. Dim 35% black, 520-wide, 12 pt continuous card, `bg.surface`, shadow 24/8. Placeholder **Search commands…**. Esc / click dim dismisses.

**1.0.5 baseline:** 12 flat items; Return runs the first match; category shown as a trailing capsule; no arrow highlight.

**Wave U1 (current spec):** section headers by category, arrow-key selection + Enter, ~22 items.

| Category | Items |
|---|---|
| Chat | New Conversation · Clear Conversation · Compact Conversation · Session Info · Fork Conversation · Export conversation · Stop agent |
| Safety | Enable/Disable Safe Mode · Cycle Permission Mode (⇧Tab) · Plan Mode |
| App | Open Settings · Projects · Scheduled Tasks · Notes · Models · New project |
| Model | Choose Model |
| Navigation | Previous task · Next task |
| Appearance | Toggle theme |

Filter: substring on title, subtitle, category, keywords. Empty query lists all, grouped.

Sources: `App/Views/RootView.swift`, `App/Views/Sidebar/ZCodeSidebar.swift`, `App/Views/ChatView.swift`, `App/Views/Settings/SettingsViewV2.swift`, `App/Views/CommandPalette/CommandPaletteView.swift`, `App/Views/Chat/NewTaskLandingViewV2.swift`, `App/Views/Common/BrandMarkOutline.swift`, `App/VibeCoderApp.swift`

---

## 5. States — empty / loading / error / success

### 5.1 Model picker chip

| State | Visual |
|---|---|
| Nothing available | **No model**, `fg.tertiary` |
| Available, none selected | **Select model** + chevron |
| Selected | Pretty name (`.gguf` / split-file / quant trimmed) |
| Two-model orchestration | Read-only pill `orch → worker` (picker hidden) |
| Unreachable | Surfaces as the empty-chat hero / Connection Test, not a chip error string |

No animated “loading 73%” fill on the chip. oMLX load failure is the red banner under the header.

### 5.2 Chat transcript

| State | Visual |
|---|---|
| Empty | §4.6 hero (title depends on backend/model) |
| First tokens | `PendingAssistantBubble`: **Working for Ns** (shimmer) → **Thinking…** (or playful phrase every 4.2 s if `playfulWaitingLabels`) → reasoning → activity/edits → answer |
| Tools live | Activity stack auto-expands; edit cards auto-open |
| User stopped | `TurnEndedByUserLabel` under the assistant |
| Model load error | Red banner, dismiss × |
| Goal stall / pause | Top `GoalStatusBanner` |
| Finished | Working header flips to **Worked for …**; no docked “Finished: stop” line (`statusLine` / `ProcessingStatusBar` are not mounted) |

`humanStatus` maps “Iteration N…” → **Working…**; turn-limit → **Stopped — turn limit reached**.

### 5.3 InputBar

| State | Visual |
|---|---|
| Idle, empty | Placeholder **Ask for follow-up changes**; send muted / disabled |
| Has content | `fg.primary`; send accent circle enabled |
| Running | Placeholder **Keep typing to queue a follow-up…**; red Stop; extra Send = **interjection** (applied on next step) |
| No model | Field stays editable; empty hero carries the “pick a model” guidance — the field does **not** say “Pick a model to start.” |

### 5.4 Sidebar

| State | Visual |
|---|---|
| Empty tasks | **No tasks yet** |
| Unloadable JSON | Warning banner + Show in Finder |
| Running row | Green 6 pt glow |
| Error row | Warning triangle |
| Selected | `bg.hover` fill, no accent bar |

No skeleton shimmer, no “Showing N of M” project filter.

### 5.5 Settings — Test connection

| State | Visual |
|---|---|
| Idle | **Test Connection** (LM Studio / oMLX / Ollama / Unsloth / Custom). EXO uses **Connect** |
| Testing | **Testing…**, disabled |
| Success | **Connected — N models** (or EXO pins the typed id) |
| Fail | Inline `semantic.error` message until the next action |

### 5.6 Patch Review

| State | Visual |
|---|---|
| Pending | `K of N files decided` in secondary |
| Mixed | Same counter; badges Accepted / Rejected |
| Ready | Counter in `semantic.success`; **Apply selected** enabled |
| Zero accepted | Apply disabled |

No “hunk no longer applies” conflict chrome.

Sources: `App/Views/Chat/PendingAssistantBubble.swift`, `App/Views/Chat/InputBarViewV2.swift`, `App/Views/Chat/ModelPickerButton.swift`, `App/Views/Settings/ConnectionSettingsView.swift`

---

## 6. User flows

### 6.1 First launch → first conversation

App opens on `RootView` (no Welcome, no starter cards). Empty chat: **Connect a model server** with loopback **Use** rows or **Open Connection settings**. Test → pick from the composer chip → hero becomes **What are we working on?** → Return. 2–3 clicks if a local server is already up. Downloads are out of band (Ollama / LM Studio / oMLX) — no in-app catalog.

### 6.2 Bind project → agentic task

Projects → **New Project** (scratch or existing) or task menu **Move to project**. Opening a project shows `ProjectFolderLandingView` (**Start a new chat in this project**). Send creates a bound conversation, then Chat takes over. Worktree / export live in the title menu — no header “Bind project” chip. @-mentions search that tree.

### 6.3 Worktree + patch review

Title menu → **Isolate work in git worktree**. In **Ask** mode, `apply_patch` opens **Review patch** (file Accept/Reject → **Apply selected**). Toggle worktree off → **Worktree review** (**Continue** / **Discard** / **Merge into main**). Plan never opens the sheet; Auto / Full apply without it.

### 6.4 Settings: backend + sampling

⌘, → Connection (Test / Connect / **Use this backend**) then Model & Backend (engine strip, optional Two-Model). 2026-06 load/sampling sliders **do not exist**. Context window + compact live under **Context**.

### 6.5 Connect Xcode via Local API

Settings → Connection → **Local API Server**: **Run on app launch**, optional agent-loop, port 11435, **Start Server**, **Copy URL** (`http://localhost:{port}/v1`). Same pane: **Enable Xcode MCP tools**. Not a separate tab.

### 6.6 License activation — removed

No trial lock, no activation sheet, no key field. Privacy is export / import / clear. Do not reintroduce.

Sources: `App/VibeCoderApp.swift`, `App/Views/Projects/ProjectsView.swift`, `App/Views/Projects/ProjectFolderLandingView.swift`, `App/Views/Settings/ConnectionSettingsView.swift`, `App/Views/Chat/ChatTitleDropdown.swift`

---

## 7. Microcopy

### 7.1 Buttons

**Send** / **Stop** / **Send interjection** · **New conversation** / **New Task** · **Settings** / **Close** · attach panel **Attach files or folders** · patch **Reject all** / **Accept all** / **Reject** / **Accept** / **Apply selected** / **Always allow folder** / **Cancel** · worktree **Continue** / **Discard** / **Merge into main** / **Expand all** · plan **Stay in Plan** / **Approve & Run** · approval **Once** / **Always** / **Never** / **Deny** / Wave U1 **Allow for session** · connection **Test Connection** / **Connect** / **Use this backend** / **Start Server** / **Copy URL** · models **Refresh** / **Use** · **New Project** / **New schedule** · alert **Delete all tasks?** / **Delete All** · hero **Use** / **Open Connection settings**.

### 7.2 Placeholders

| Field | Placeholder |
|---|---|
| Composer, idle | **Ask for follow-up changes** |
| Composer, running | **Keep typing to queue a follow-up…** |
| Palette | **Search commands…** |
| Settings search | **Search settings** |
| Untitled task | **Untitled** |
| Worktree commit | **Commit message…** |
| ask_user field | **Type your answer…** / **Or type a custom answer…** |
| @ popup header | **@ context — ↑/↓ Enter pin · Esc dismiss** |

Removed: “Ask the agent…”, “Pick a model to start.” (field), “Search conversations”, license-key mask.

### 7.3 Status phrases

**Thinking…** (optional 4.2 s playful rotation, off by default) · **Working for Ns** / **Working for N minutes** · **Worked for …** · **Thinking · Ns** / **Thought for Ns** / **Thought** · **Plan approved — continuing in Ask mode…** · **Staying in Plan mode — revise the plan or Approve when ready.** · **Interjection sent — applied on next step.** · **Cancelling…** · **Stopped — turn limit reached**. Hidden `statusLine` maps “Iteration N…” → **Working…**. Do not invent a “Reading the project…” rotation.

### 7.4 Error + destructive copy

| Scenario | Message |
|---|---|
| Unloadable JSON | **N conversation(s) couldn't be loaded** · **Show in Finder** |
| Delete all | **This will permanently remove all N tasks.** |
| Dangerous shell | **Dangerous commands are never remembered — Always acts as Once.** |
| Worktree discard | **All uncommitted changes in the worktree will be permanently removed.** |
| Worktree fail | alert **Worktree error** |
| Models empty | **No models reported. Start Ollama or oMLX (or another backend), then Refresh.** |
| No backend on send | **No models from {backend} — open Settings → Connection…** |

Never blame the user. Suggest the running server or Settings → Connection.

Sources: `App/Views/Chat/InputBarViewV2.swift`, `App/Views/ChatView.swift`, `App/Views/Chat/WorkingHeader.swift`, `App/Views/Chat/ReasoningBlockView.swift`, `App/ViewModels/ChatViewModel.swift`

---

## 8. Accessibility

**Shipped:** VoiceOver labels on send/stop, New Task, Delete all, Settings, unloadable banner, web/Chat-Agent, Working header, Undo. Status is never color-only (glow **dot**, **triangle**, verb+icon, `+`/`−`). Shortcuts: ⌘N, ⌘,, ⌘K, ⌘., Esc, Return, ⇧Tab, Shift+Return, ↑/↓. Text selection on pills, prose, code, approval detail.

**Deliberate: focus rings hidden.** `hidesSystemFocusRing()` → `focusEffectDisabled()` on the `WindowGroup` and composer; `WindowChromeAdjuster` sets AppKit `focusRingType = .none`. Rationale: designed hover / open-menu / hairline already mark focus; the system blue ring is not part of the UI. Composer focus is a stronger **neutral** hairline + shadow, not an orange ring.

**Open items:** reduced motion (`Theme.Motion` always runs; no `accessibilityDisplayShouldReduceMotion`); increased contrast (no token swap); visible FKA ring (conflicts with hide-rings — revisit if testing demands a 2 pt accent ring); conversation rotor; WCAG AAA.

Sources: `App/Theme/ViewExtensions.swift`, `App/VibeCoderApp.swift`, `App/Views/Chat/InputBarViewV2.swift`

---

## 9. Dark mode parity rules

1. **Every color token has a dark counterpart** in `Theme.Palette` (`dynamicLight` / `dynamicDark`, or fixed RGB for semantics/diffs). No raw marketing hex in views.
2. **No setting exists only in light.** Appearance is System / Light / Dark (`colorScheme`); both palettes cover every role.
3. **Hierarchy is role, not lightness.** Primary chrome is `accent` in both modes — the *which orange* changes (`#E37A38` light / `#E48B46` dark), the *role* does not. User pills stay neutral 6% in both.
4. **Sidebar and composer share `bg.subtle`** so the two columns feel like one plane (dark `#2B2B2B`).
5. **Text is soft gray in dark (`#D2D2D2`)**, not label-white.

User preference is Settings → Appearance. Applied via `RootView` `.preferredColorScheme`.

Sources: `App/Theme/Theme.swift`, `App/Views/Settings/AppearanceSettingsView.swift`

---

## 10. Responsive behavior

Two-column only. The window chrome does **not** grow a third column and does **not** collapse the sidebar to icons.

| Constraint | Value |
|---|---|
| Window min | 960 × 620 |
| Default open size | **unset** (system default) |
| Sidebar | 240–360, ideal 280. No breakpoint at 1080 / 1400 / 1920 |
| Icon-only sidebar | **Removed from spec** — not implemented; do not add width-based auto-collapse |
| Chat column | `contentWidth = min(1040, pane − 2×gutter)`; gutter = clamp(6% pane, 24, 96); floor 320 when it fits |
| User pill | wrap at 560, independent of column |
| Settings sheet | 920–1100 × 620–820 |
| Patch sheet | min 760 × 540 |
| Worktree sheet | 720 × 600 |
| Palette | 520 wide, list max 320 tall |
| Plan overlay | 200–320, tracks column |

Hide Sidebar is the system split control (animated spring), not an icon strip.

Sources: `App/VibeCoderApp.swift`, `App/Views/RootView.swift`, `App/Theme/Theme.swift` (`ChatLayout`)

---

## 11. Sign-off

Read §1 first. The locked identity is **orange + SF**, local-model-first, two-column `NavigationSplitView`.

Most consequential sections:

1. **§2.3 color** — `#E48B46` family. Azure / Cobalt / Ember-send are historical only.
2. **§3 components** — ActivityRow + InlineEditCard + file-level PatchFile + TextField composer. Do not re-spec ToolStub, in-transcript PlanCard, or per-hunk Accept.
3. **§4.3 / §4.8** — 11-tab settings (plus Wave U1 Hooks) and the command palette are real surfaces; they were missing or wrong in the 2026-06 draft.

Once §1, §2.3, and §3 match the running app, the rest is execution.

### Amendments log

| Date | Section | Change | Reason |
|---|---|---|---|
| 2026-06-02 | (initial) | Drafted | First version; four design decisions via sign-off question |
| 2026-06-02 | §2.3 | Accent Ember → Azure (`#2563EB` / `#60A5FA`) | Then-current preference for blue |
| 2026-06-02 | §4.7 (new) | Models Library / Discover (HF browser + catalog) | Hybrid catalog + power-user browse |
| 2026-06-02 | §4.1, §4.7 | Removed “recommended for your Mac” framing | Voice / support burden |
| 2026-06-02 | §2.3 | Azure → Cobalt (`#3385F2`) + Ember send (`#E75D3C`) + extra semantics | DEV PLAN palette pass — **superseded** |
| 2026-08-16 | **all** | **Rewritten to match shipped 1.0.5 code; identity confirmed as orange accent + SF (was Azure/Geist spec). Wave U1 additions recorded: syntax-highlighted chat code blocks; turn-end change-summary card with Undo; session-scoped permission grant + keyboard nav in approval sheet; command palette sections/arrow-key selection (~22 items); Settings → Hooks editor tab.** | UI parity wave — live app is source of truth. Also recorded as **removed** (do not resurrect): onboarding, license/trial, Geist, Azure/Cobalt, 4-icon sidebar, icon-only collapse, 1280×800 default, per-hunk Accept/Reject, ToolStub, in-transcript PlanCard, Library/Discover, load sliders, visible focus rings, docked status bar |

**Intentionally not in this spec (compiled leftovers):** `SidebarShell` engine strip, `ToolCallView` / `ThoughtProcessBlock` / `StepperRailSpec`, `ProcessingStatusBar` / `ZCodeStatusBar`, `PermissionsSheetView`, `ConversationListViewModel`, `NavigationState`, `EmptyDetailView`. Do not treat them as UX requirements.

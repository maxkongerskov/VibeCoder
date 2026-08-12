# UI DESIGN — NEW DAY

> Sibling document to `ARCHITECTURE.md`. The architecture says *what* exists; this says *how it looks, feels, and behaves*. When tactical UI work disagrees with this doc, this doc wins (amendments via §15).
>
> Read in order: §1 (principles) → §2 (foundations) → §3 (components) → §4 (screens) → §5 (states) → §6 (flows). Skim §7–§10 for reference. Sign off after §11.

---

## 1. Design principles

Four locked decisions from the sign-off question, plus the values that fall out of them:

1. **Visual density: Claude.ai-spacious.** Generous whitespace, comfortable line height, large-ish text. Calm enough for 4-hour sessions. Built for big screens but graceful at 1280-wide.
2. **Aesthetic: polished + warm.** Mixed typography (Geist Sans for UI, Geist Mono for code/data), purposeful use of accent color, subtle decorative touches where they communicate something. Not minimalist-cold, not consumer-busy. The voice is "the senior engineer who keeps their workspace nice."
3. **Color: single accent + neutrals.** One signature accent (§2.3), grayscale everywhere else. Semantic colors (green/red/amber) reserved for status communication. Dark mode parity is enforced; no setting exists only in light.
4. **Animation: Claude.ai-level nice.** Restrained delight — functional motion as the baseline, signature moments where they matter (model ready pulse, build pass confirmation, message send), nothing decorative. 150–300 ms easeOut for most, spring physics for chip pulses.

The principles that fall out:

- **Predictability over surprise.** Same gesture, same result, every time.
- **Latency disguised as design.** When the model is loading or thinking, that time is filled with information (load progress, status line, thinking chip), not a blank wait.
- **One affordance per action.** No button that does three things. No menu hidden inside a chip.
- **The model is the product.** Chrome (sidebar, toolbar, settings) gets out of the way during chat. Conversation typography is the centerpiece.
- **Hierarchical, never flat.** Every screen has primary / secondary / tertiary information.
- **Errors are conversation, not interruption.** No modal alerts for recoverable issues. Inline status, dismissable banners.
- **Keyboard is first-class, not afterthought.** Every primary action has a shortcut. Power users live in the keyboard.

---

## 2. Visual foundations

### 2.1 Typography

Two families, three roles:

| Role | Family | Size | Weight | Line height | Used for |
|---|---|---|---|---|---|
| **Display** | Geist Sans | 32 pt | Semibold | 1.15 | Welcome screens, "AgentOS NEW DAY" wordmark, large empty states |
| **Title** | Geist Sans | 20 pt | Semibold | 1.25 | Chat header titles, sheet headers, sidebar section labels |
| **Body** | Geist Sans | 14 pt | Regular | 1.55 | Conversation prose, settings forms, descriptions, most UI |
| **Body emphasis** | Geist Sans | 14 pt | Semibold | 1.55 | Section labels in dense UI, button text |
| **Caption** | Geist Sans | 12 pt | Regular | 1.4 | Timestamps, secondary labels, metadata |
| **Caption emphasis** | Geist Sans | 12 pt | Medium | 1.4 | Status line, small badges, kbd shortcuts |
| **Mono body** | Geist Mono | 13 pt | Regular | 1.5 | Tool args, code snippets in chat, tool result content |
| **Mono small** | Geist Mono | 12 pt | Regular | 1.4 | Model IDs in picker, file paths, JSON in cards |

Geist Sans is the default; Mono only appears where the content *is* code or code-like data. Never mix in the same sentence.

### 2.2 Spacing

8-pt base unit. The canonical scale:

```
2   4   6   8   12   16   24   32   48   64   96
```

- **Inline gaps (icon ↔ text):** 6 or 8
- **Item padding (rows, cards):** 12 or 16
- **Section padding (between groups):** 24 or 32
- **Window margins:** 24 (content edges from window frame)
- **Sheet padding:** 32 (sheets get more breathing room)

Generous, not cramped. If two elements feel close, double the gap.

### 2.3 Color

**Light mode**

| Token | Hex | Usage |
|---|---|---|
| `bg.canvas` | `#FCFBF8` | Main background (warm off-white, not pure white) |
| `bg.surface` | `#FFFFFF` | Cards, sheets, sidebar |
| `bg.subtle` | `#F4F2EC` | Tool result cards, code blocks, input bar |
| `bg.muted` | `#EAE6DC` | Hover/pressed states, dividers' fill |
| `fg.primary` | `#1B1A17` | Body text, headings |
| `fg.secondary` | `#5C5851` | Metadata, captions, less-important labels |
| `fg.tertiary` | `#8B867D` | Placeholders, disabled, very-low-emphasis labels |
| `fg.muted` | `#B8B3A8` | Decorative outlines, separators |
| `accent` | `#2563EB` | **Azure** — the signature blue |
| `accent.hover` | `#1D4ED8` | Buttons on hover |
| `accent.subtle` | `#EFF4FF` | Accent-tinted backgrounds (user message bubble fill, selected row) |
| `semantic.success` | `#2D7D32` | Build pass, ready state |
| `semantic.warning` | `#B86E00` | Reload-to-apply banner, non-fatal warnings |
| `semantic.error` | `#B91C1C` | Build fail, tool error, license expired |
| `semantic.info` | `#1E5AB8` | Informational notices |

**Dark mode** — semantic role-equivalents, no setting exists only in light:

| Token | Hex |
|---|---|
| `bg.canvas` | `#181715` |
| `bg.surface` | `#22201D` |
| `bg.subtle` | `#2A2724` |
| `bg.muted` | `#34302B` |
| `fg.primary` | `#F2EFE8` |
| `fg.secondary` | `#B5AFA3` |
| `fg.tertiary` | `#857F73` |
| `fg.muted` | `#544F47` |
| `accent` | `#60A5FA` |
| `accent.hover` | `#93C5FD` |
| `accent.subtle` | `#1E3A5F` |
| `semantic.success` | `#4ADE80` |
| `semantic.warning` | `#FBBF24` |
| `semantic.error` | `#F87171` |
| `semantic.info` | `#60A5FA` |

**Why Azure?** Confident, modern blue (Tailwind blue-600 light / blue-400 dark — values used across Linear, Vercel, GitHub's newer surfaces). Strong dark-mode parity. Pairs cleanly with macOS native chrome (vibrancy materials, sidebar tinting) without competing. Reads professional rather than playful — fits the "senior engineer next to you" voice from §16 of `ARCHITECTURE.md`. Note: it's intentionally NOT macOS system blue (`#007AFF`) — that's the default everywhere and would make NEW DAY visually generic.

### 2.4 Corners + shadows

| Use | Radius | Shadow |
|---|---|---|
| Cards, tool result cards | 8 pt | `0 1px 2px rgba(0,0,0,0.04)` (light) / none (dark) |
| Sheets | 12 pt | `0 8px 24px rgba(0,0,0,0.12)` (light) / `0 8px 24px rgba(0,0,0,0.40)` (dark) |
| Chips, badges | full pill | none |
| Buttons | 6 pt | none |
| Modals (license activation) | 12 pt | `0 16px 48px rgba(0,0,0,0.16)` (light) / `0 16px 48px rgba(0,0,0,0.60)` (dark) |
| Code blocks | 6 pt | none — defined by background only |
| Message bubbles | 12 pt (full-corner) | none |

### 2.5 Motion

Five named animations, used consistently across the app:

| Name | Duration | Curve | Used for |
|---|---|---|---|
| `quick` | 150 ms | `easeOut` | Hover states, focus rings, button press feedback |
| `standard` | 250 ms | `easeOut` | Sheet present/dismiss, sidebar selection change, settings tab switch |
| `gentle` | 300 ms | `easeInOut` | Disclosure expansion (tool result cards), patch hunk accept/reject |
| `pulse` | 800 ms | spring(damping: 0.65, response: 0.4), repeating | Model ready chip, build pass status line, send button on ⌘⏎ |
| `stream` | per-token | `easeOut` 80 ms on insertion | Streaming content delta — each new chunk gently slides in |

**Reduced Motion** (Accessibility): pulse → static color change; gentle → instant; stream → instant render. We respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

Animation budget rule: **no animation longer than 350 ms unless it's a `pulse` (which is communicating state, not transitioning).** Anything slower than 350 ms feels sluggish during a coding session.

### 2.6 Iconography

SF Symbols only, never custom raster icons. Sizes:

| Use | Size | Weight |
|---|---|---|
| Inline (in body text) | 14 pt | regular |
| Toolbar buttons | 16 pt | regular |
| Sidebar tab icons | 18 pt | medium |
| Chat input bar action icons | 16 pt | regular |
| Status line icons | 12 pt | medium |
| Empty state icons | 32 pt | light |

Icon vocabulary (locked, used consistently):

| Concept | Symbol |
|---|---|
| New conversation | `square.and.pencil` |
| Settings | `gearshape` |
| Search | `magnifyingglass` |
| Project bind | `folder` / `folder.badge.plus` |
| Worktree on | `shield.fill` |
| Worktree off | `shield` |
| Safe Mode | `lock.shield` |
| Send | `arrow.up` |
| Stop | `stop.fill` |
| Build pass | `checkmark.circle.fill` |
| Build fail | `xmark.octagon.fill` |
| Model load progress | `circle.dashed` (animated rotation) |
| Model ready | `circle.fill` |
| Reload to apply | `arrow.clockwise` |
| Tool call | `arrow.right.circle.fill` |
| Tool result success | `checkmark.circle.fill` |
| Tool result error | `xmark.circle.fill` |
| Plan card | `list.bullet.rectangle` |
| Sidebar tabs | `bubble.left`, `folder`, `wand.and.rays`, `cube` |

---

## 3. Component library

Reusable building blocks. Defined once here, used everywhere. Adding a new component requires §15 amendment.

### 3.1 Chip

Pill-shaped, used for model picker, attached-skill display, status indicators, project bind.

```
┌─────────────────────────────┐
│ ● Qwen2.5-Coder 32B ▾       │
└─────────────────────────────┘
```

- Height: 28 pt
- Padding: 10 pt H × 5 pt V
- Background: `bg.muted`
- Border: 1 pt `fg.muted`, only on hover/focus
- Status dot (when applicable): 8 pt circle, leading edge, 6 pt gap
- Trailing chevron only when interactive (opens menu)
- States: idle / hover (background shifts to `bg.subtle` in light, `bg.canvas` in dark) / pressed / disabled (opacity 0.5)

### 3.2 StatusDot

```
●  (8 pt filled circle)
```

Semantic colors only:
- `semantic.success` — ready, build pass, license valid
- `semantic.warning` — reload needed, trial expiring soon
- `semantic.error` — backend unreachable, build fail, license expired
- `semantic.info` — informational state
- `fg.tertiary` — idle / unconfigured

The model picker chip uses a StatusDot at its leading edge.

### 3.3 Card

Generic container for grouped content. Variants:

**Default card:** `bg.surface` background, 8 pt radius, optional 1-pt `fg.muted` border, 16 pt padding, no shadow in dark mode, subtle shadow in light.

**Subtle card (tool result):** `bg.subtle` background, 8 pt radius, no border, 12 pt padding. Code-like content inside.

**Disclosure card (expandable):** Subtle card with a header row that toggles content visibility on click. Animation: `gentle` (300 ms easeInOut). Chevron rotates 90° → 0° on expand.

### 3.4 Banner

Non-modal hint, sits at top of content area. Used for "Reload model to apply", "Backend unreachable", "Trial expires in 4 days."

```
⚠ Reload model to apply load changes              [Reload now] [Apply on restart] [×]
```

- Background: `accent.subtle` for info, semantic-tinted for warnings
- Padding: 12 pt
- Dismissable with × on right (unless action-required)
- Animation: `standard` slide-in from top

### 3.5 MessageBubble

Three role variants:

**User:**
```
                                        ┌─────────────────────────────┐
                                        │ summarize the project       │
                                        └─────────────────────────────┘
```
- Right-aligned, max 75% width
- Background: `accent.subtle`
- Padding: 12 pt
- Radius: 12 pt
- Selection enabled

**Assistant:**
```
The project has three top-level targets: AgentCore, MLXBackend,
and AgentCLI…

  → read_file path: README.md
  → grep_code pattern: "InferenceBackend"
```
- Left-aligned, full width minus 80 pt right margin
- No bubble background (just inline text)
- Tool call stubs inline as part of the message
- Selection enabled, markdown rendered

**Tool result (DisclosureCard variant):**
```
  ✓ tool result · tc_4cd2                                            ▾
  ┌─────────────────────────────────────────────────────────────────┐
  │     1 | # AgentOS                                                │
  │     2 |                                                          │
  │     3 | A local macOS coding agent…                              │
  └─────────────────────────────────────────────────────────────────┘
```
- DisclosureCard format
- Status icon (`checkmark.circle.fill` semantic.success / `xmark.octagon.fill` semantic.error)
- Tool call ID in mono caption
- Content in mono body inside subtle card
- Expandable; collapsed by default after 5+ tool results have been added

### 3.6 ToolStub (inline)

Compact representation of a tool call within an assistant message:

```
  → read_file  path: README.md
```

- `arrow.right.circle.fill` icon, accent color
- Tool name in mono caption emphasis
- Args truncated (first 60 chars) in mono caption
- Click to expand args + result inline (rare — usually the result card has it)

### 3.7 PlanCard

Visual step tracker rendered when the agent calls `create_plan`:

```
┌──────────────────────────────────────────────────────────┐
│ ▾ Plan                                                    │
├──────────────────────────────────────────────────────────┤
│ ✓ Read project README                                     │
│ ✓ List Sources/ directory                                 │
│ ◯ Identify backend protocol               ← in progress   │
│ ◯ Summarize architecture                                  │
└──────────────────────────────────────────────────────────┘
```

- DisclosureCard with header "Plan" + step count
- Each step: icon (filled = done, ring = pending, half-filled = in-progress)
- In-progress step pulses gently (subtle accent tint background)
- Updates animate `gentle` when `update_todo` is called

### 3.8 PatchHunk

Per-hunk diff view used in the Patch Review Sheet:

```
┌──────────────────────────────────────────────────────────────┐
│ Sources/AgentCore/Tools/ReadFileTool.swift                    │
│ @@ -42,7 +42,7 @@                                             │
│  42      let url = resolvePath(path, base: context.workingDirectory) │
│  43      let data: Data                                       │
│- 44      do { data = try Data(contentsOf: url) }              │
│+ 44      do { data = try Data(contentsOf: url, options: .mappedIfSafe) } │
│  45      catch { return ToolResult(content: "...", isError: true) } │
│                                          [Reject hunk] [Accept] │
└──────────────────────────────────────────────────────────────┘
```

- File path header in mono caption emphasis
- Line numbers in `fg.tertiary`, mono small
- Added lines: `semantic.success` background tint (10% opacity)
- Removed lines: `semantic.error` background tint (10% opacity)
- Syntax highlighting via SwiftTreeSitter (P1 polish if Tree-sitter ships on time; plain mono otherwise)
- Per-hunk Accept / Reject buttons

### 3.9 Button

Three variants by emphasis:

| Variant | Background | Foreground | Use |
|---|---|---|---|
| **Primary** | `accent` | `#FFFFFF` | One per view max — Send, Continue, Buy a license |
| **Secondary** | `bg.muted` | `fg.primary` | Multiple per view OK — Cancel, Reload, Apply on restart |
| **Plain** | transparent | `fg.primary` | Inline actions — Bind project, Edit title |
| **Destructive** | transparent → `semantic.error.subtle` on hover | `semantic.error` | Delete, Discard worktree, Reject patch |

All buttons: 32 pt height, 16 pt horizontal padding, 6 pt radius, 14 pt body weight medium. Disabled = opacity 0.5, no hover.

### 3.10 InputBar

The chat composer.

```
┌──────────────────────────────────────────────────────────────────┐
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Ask the agent…                                                │ │
│ │                                                                │ │
│ └──────────────────────────────────────────────────────────────┘ │
│ [⌘ Plan] [⌘ Safe Mode]                                  [Send ↑] │
└──────────────────────────────────────────────────────────────────┘
```

- TextEditor in `bg.subtle` card, 8 pt radius
- Min height: 56 pt (single line padding); grows to max 200 pt then scrolls
- Placeholder in `fg.tertiary`, fades on focus
- Attached skill chips above the editor as a horizontally-scrolling row
- Below editor: row of toggles (Plan mode, Safe Mode) on the left, Send button on the right
- Send button: primary, 36 pt height, `arrow.up` icon. Replaced with red Stop button while running.

### 3.11 Sidebar Row

```
   ✦ Conversation title here                  4m ago
     First user message snippet that wraps…
```

- 60 pt minimum height, 12 pt vertical padding
- 16 pt horizontal padding
- Hover: `bg.muted` fill
- Selected: `accent.subtle` fill, 3 pt accent leading edge bar
- Title in body emphasis, single line, truncated
- Snippet in caption, 2-line max, `fg.secondary`
- Right side: relative timestamp in caption, `fg.tertiary`
- Optional leading icon if conversation has special state (worktree active, etc.)

---

## 4. Screens

Every screen specified with layout, primary actions, and where the visual hierarchy puts emphasis.

### 4.1 Onboarding (2 screens after the cut)

**Screen 1: Welcome + Hardware**

```
┌───────────────────────────────────────────────────────────────┐
│                                                                │
│                      AgentOS NEW DAY                           │
│            Local-first coding agent · v0.1.0                   │
│                                                                │
│      Nothing leaves your Mac. Ever.                            │
│                                                                │
│      Your Mac: M3 Max · 128 GB unified memory                  │
│      You can run any model in the catalog smoothly.            │
│                                                                │
│              [ Send anonymous crash reports ☐ ]                │
│                                                                │
│                                          [ Continue ]          │
│                                                                │
└───────────────────────────────────────────────────────────────┘
```

- Display title centered
- Hardware detected automatically, shown as static line (not editable)
- Crash reports toggle off by default, label in caption explaining what's sent
- Continue → primary button, bottom-right

**Screen 2: Pick a starter model**

```
┌───────────────────────────────────────────────────────────────┐
│  Pick a model to start with                                    │
│  You can change this anytime in the model picker.             │
│                                                                │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │  Small          │ │  Medium         │ │  Large           │  │
│  │  fastest        │ │  most capable   │ │  for big Macs    │  │
│  │  Qwen2.5-Coder  │ │  Qwen3.6 35B-A3B│ │  Qwen3-Coder-Next│  │
│  │  7B MLX         │ │  MLX MoE        │ │  80B GGUF        │  │
│  │                 │ │                 │ │                 │  │
│  │  4 GB · tool✓   │ │  17 GB · tool✓  │ │  48 GB · tool✓  │  │
│  │                 │ │                 │ │                 │  │
│  │  [ Download ]   │ │  [ Download ]   │ │  [ Download ]   │  │
│  └─────────────────┘ └─────────────────┘ └─────────────────┘  │
│                                                                │
│  [ Skip — I'll connect to LM Studio or EXO ]      [ Continue ] │
│                                                                │
└───────────────────────────────────────────────────────────────┘
```

- Three cards presented as equals — no "recommended" framing. Cards that won't fit in the detected RAM are dimmed with an inline "needs <X> GB" note, but the card itself is not hidden or de-prioritized
- Each card: size category + honest one-line descriptor + model name + capability badges + primary Download button
- Skip option as plain text button below cards
- Continue is enabled either when a model is downloading (background) or Skip is hit

### 4.2 Main window (the workspace)

```
┌─────────────────┬──────────────────────────────────────────────┐
│ AgentOS         │ ● Qwen2.5-Coder 32B ▾    🔍   ⚙️   ✎          │
├─────────────────┼──────────────────────────────────────────────┤
│ [💬][📁][✦][🧊] │ Project audit                    📁 my-app   🛡 │
│                 │                                               │
│ Conversations   │  ┌───────────────────────────────────────┐   │
│                 │  │ summarize the project                 │   │
│ ✦ Project audit │  └───────────────────────────────────────┘   │
│   4m ago        │                                               │
│   summarize…    │  The project has three top-level targets:    │
│                 │  AgentCore, MLXBackend, AgentCLI.            │
│   Refactor      │                                               │
│   2h ago        │  → read_file  path: Package.swift            │
│   replace the…  │                                               │
│                 │  ✓ tool result · tc_4cd2              ▾     │
│                 │                                               │
│                 │  → grep_code  pattern: "InferenceBackend"    │
│                 │                                               │
│                 │  ✓ tool result · tc_4cd3              ▾     │
│                 │                                               │
│                 │  The AgentCore target has 30 Swift files…    │
│                 │                                               │
│                 ├──────────────────────────────────────────────┤
│                 │ ⚡ Iteration 4/30 · grep_code ✓ · build ✓     │
│                 │ ┌───────────────────────────────────────────┐ │
│                 │ │ Ask the agent…                            │ │
│                 │ └───────────────────────────────────────────┘ │
│                 │ [Plan] [Safe]              [Send ↑]           │
└─────────────────┴──────────────────────────────────────────────┘
```

Layout proportions:
- Sidebar: 260 pt wide (resizable 220 – 360 pt)
- Detail pane: fills remaining
- Top toolbar: 44 pt high
- Chat header: 56 pt high (model chip + title + project chip + safe mode toggle)
- Transcript: fills, scrolls
- Status line: 28 pt high
- Input bar: 88 pt high baseline, grows up to 200 pt

Sidebar tab strip (top): four icon tabs (Conversations / Projects / Skills / Models). Selected tab gets accent underline + accent foreground. Tab content fills the rest of sidebar.

### 4.3 Settings sheet (5 tabs after the cut)

Tabs along the top, content fills below. 720 × 520 pt default size, resizable.

**Tab 1: General**

- Appearance: System / Light / Dark (segmented)
- Font size: Small / Default / Large (segmented)
- Agent trace: toggle off; below in caption: "writes per-iteration JSONL trace to ~/Library/Application Support/…"

**Tab 2: Connection**

- Active backend: picker (LM Studio / EXO / llama.cpp / MLX)
- For each backend, host + port + "Test connection" button with inline status
- llama.cpp section: optional path override for `llama-server` binary

**Tab 3: Models** (NEW — load + inference + system prompt nested here)

```
┌───────────────────────────────────────────────────────────────┐
│  Model: [Qwen2.5-Coder 32B Instruct ▾]                         │
├───────────────────────────────────────────────────────────────┤
│  ⚠ Reload model to apply load changes      [Reload now] [×]   │
├───────────────────────────────────────────────────────────────┤
│  LOAD SETTINGS  (require reload)                               │
│   Context length        [────────●──] 32,768  / 262,144 max    │
│   GPU offload layers    [─────────●─] 99 / 99                  │
│   Flash attention                          [✓]                  │
│   KV cache type         ( f16 │ q8_0 │ q4_0 )                  │
│                                                                │
│  INFERENCE SETTINGS  (apply next turn)                         │
│   Temperature           [──●────────] 0.30                     │
│   Top-P                 [─────────●─] 0.95                     │
│   Top-K                 [──●────────] 40                       │
│   Repeat penalty        [──●────────] 1.05                     │
│   [ Reset to Coder defaults ]  [ Reset to Balanced ]           │
│                                                                │
│  SYSTEM PROMPT OVERRIDE                                        │
│   ┌──────────────────────────────────────────────────────┐    │
│   │ [empty — uses global system prompt]                  │    │
│   │                                                       │    │
│   └──────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────┘
```

Sliders use the `accent` thumb, `bg.muted` track, `accent.subtle` fill on left of thumb. Live value to the right in mono caption.

Reload banner appears only when a load setting is dirty (changed from current spawned value). Dismiss with × means "don't reload now; will apply on next launch."

**Tab 4: Privacy & License**

- License key field + status (Trial: 13 days remaining / Valid through forever / Expired)
- "Deactivate this Mac" button (v1.1; placeholder text in v1)
- Crash reporting toggle with detailed caption: what's sent, what's never sent, link to privacy policy
- Conversation backup: Export all / Import / Clear all

**Tab 5: About**

- App icon (large) + version + build
- "Check for updates" button (triggers Sparkle check)
- Credits: open source dependencies (mlx-swift, llama.cpp, SwiftUI, Sparkle, etc.)
- Legal: privacy policy link, terms link

### 4.4 Patch Review Sheet

Full-window sheet, modal to its parent window.

```
┌────────────────────────────────────────────────────────────────┐
│ Review patch                              [Reject all] [Accept]│
├────────────────────────────────────────────────────────────────┤
│ Sources/AgentCore/Tools/ReadFileTool.swift  (1 hunk)            │
│ ┌──────────────────────────────────────────────────────────┐   │
│ │ @@ -42,7 +42,7 @@                                         │   │
│ │  let url = resolvePath(path, base: cwd)                   │   │
│ │  let data: Data                                            │   │
│ │- do { data = try Data(contentsOf: url) }                  │   │
│ │+ do { data = try Data(contentsOf: url, options: .mapped)} │   │
│ │  catch { return ToolResult(content: "...", isError: true)}│   │
│ └──────────────────────────────────────────────────────────┘   │
│                                          [Reject hunk] [Accept] │
│                                                                 │
│ Sources/AgentCore/Tools/WriteFileTool.swift  (1 hunk)           │
│ ┌──────────────────────────────────────────────────────────┐   │
│ │ @@ -28,3 +28,3 @@                                         │   │
│ │- try content.write(to: url, atomically: true)             │   │
│ │+ try content.write(to: url, atomically: true, encoding:.utf8) │
│ │  return ToolResult(content: "Wrote …", mutatedPaths:[path])│   │
│ └──────────────────────────────────────────────────────────┘   │
│                                          [Reject hunk] [Accept] │
└────────────────────────────────────────────────────────────────┘
```

Layout:
- 880 × 640 default, resizable to as big as the screen
- Top bar: title + global Reject all / Accept buttons
- Scrollable list of file sections, each containing one or more PatchHunk components
- Accept all / Reject all keyboard: ⌘A / ⌘R
- Per-hunk Accept/Reject: ←/→ to step through hunks, Y/N to decide
- Dismiss: Esc rejects all unsaved decisions

### 4.5 Worktree Review Sheet

Similar layout to Patch Review but shows worktree-vs-main state.

```
┌────────────────────────────────────────────────────────────────┐
│ Worktree: agentos/a4f2c3                  4 files modified     │
├────────────────────────────────────────────────────────────────┤
│ Sources/AgentCore/Tools/ReadFileTool.swift                      │
│   +12  −3                                                       │
│   [ View diff ]                                                 │
│                                                                 │
│ Sources/AgentCore/Tools/WriteFileTool.swift                     │
│   +5   −1                                                       │
│   [ View diff ]                                                 │
│                                                                 │
│ Tests/AgentCoreTests/NewToolsTests.swift  (new file)            │
│   +48                                                           │
│   [ View diff ]                                                 │
│                                                                 │
│ DEBT.md  (new file)                                             │
│   +3                                                            │
│   [ View diff ]                                                 │
├────────────────────────────────────────────────────────────────┤
│                  [Discard]  [Continue working]  [Merge into main]│
└────────────────────────────────────────────────────────────────┘
```

- Merge = `git merge --squash`, prompts for commit message
- Discard = delete worktree + branch
- Continue working = dismiss; worktree stays for next agent turn

### 4.6 Empty states

Every list has an empty state that's helpful, not just blank:

**Conversations sidebar (empty):**
```
       💬

   No conversations yet.

   ⌘N to start one.
```

**Projects sidebar (empty):**
```
       📁

   No projects bound.

   Bind a folder to a conversation
   from the chat header.
```

**Skills sidebar (empty):**
```
       ✦

   182 bundled skills.

   They auto-attach based on what you're
   working on. Pin one to keep it active.
```

**Models sidebar (empty):**
```
       🧊

   No models downloaded yet.

   [ Browse catalog ]
```

All centered, icon at 32 pt in `fg.tertiary`, body text in caption-emphasis. One action where it makes sense.

---

### 4.7 Models sidebar tab

Two sub-tabs at the top: **Library** (your downloaded models) and **Discover** (HuggingFace browser).

**Library** — your downloaded models. Nothing more, nothing less. No "recommended for you" section, no curated suggestions — we trust the user to find what they want via Discover or have already picked from the onboarding starter cards.

- Each row shows: status dot (ready / downloading / paused / error), display name, backend tag (MLX / GGUF), size, primary action (Use), secondary actions (Settings — opens the Models settings tab pre-selected to this model; ··· menu = Delete, Reveal in Finder, Show metadata)
- Active model highlighted with accent leading bar (same pattern as conversation row selection)
- Empty Library state per §4.6 — points to Discover

**Discover** — HuggingFace browser. Power user surface.

- Search bar at top — free text
- Filter chips: Backend (All / GGUF / MLX) · Size (Any / <10GB / 10–30GB / 30+) · Sort (Most downloaded / Recent / Trending)
- Results render as repo cards, expandable to show all available quantizations
- Per-quantization row: file name, size, hardware-fit indicator (✓ green if fits / ⚠ amber if tight / ✗ red if won't fit), Download button
- Community uploads (anyone not on our curated whitelist) carry a "⚠ Community upload — use at your own risk" line in `semantic.warning`
- Split-file GGUF auto-detected (looks for `-00001-of-N` pattern); on download, fetches all parts as a single job
- Auto-config behavior: known model families (Qwen, Gemma, Llama, DeepSeek, Mistral, Phi) get pre-configured context length, sampling defaults, chat template, stop sequences. Unknown families fall back to sensible generic defaults with a "Verify settings in Models tab" hint shown after download completes.

**Compatibility detection (honest scope):**

| Detection | How |
|---|---|
| Fits in your RAM | file size + safety margin vs. detected memory |
| Tool calling supported | model family heuristic (allow-list of families known to handle function-calling cleanly) |
| Split-file | filename pattern check before download |
| Chat template available | embedded GGUF metadata if present |
| Vision capability | tagged in HF metadata when present; otherwise "unverified" |

For unknown families, badges read "unverified" — no false confidence.

**Download lifecycle in both tabs:**

- Click Download → row transitions to in-progress state with Cancel + Pause buttons
- Download progress shown as filled bar with bytes/total + ETA
- Chunked, parallel (4 chunks per file for big files), SHA-256 verified on completion
- Pause/resume survives app restart (resume data persisted)
- Failed downloads: row turns `semantic.error`, error message inline, Retry button
- Completed downloads: row moves from in-progress section to DOWNLOADED in Library

**Sources policy:**

- Library curated entries come from `agentos.tools/catalog.json` (refreshed at app launch, stale-while-revalidate)
- Discover hits the public HuggingFace API (`https://huggingface.co/api/models`)
- No auth required for either; both work fully offline once models are downloaded

---

## 5. States — empty / loading / error / success

For every interactive surface, the four states are explicit.

### 5.1 Model picker chip

| State | Visual |
|---|---|
| **No model selected** | `fg.tertiary` dot, "no model" in mono small, `fg.tertiary` |
| **Loading (% progress)** | `accent` dot animated rotation, "Qwen2.5-Coder 32B · loading 73%" in mono small. Background subtly fills `accent.subtle` from left → right matching progress. |
| **Ready** | `semantic.success` dot, single `pulse` animation on transition, then static. Model name only. |
| **Active (currently streaming)** | `semantic.success` dot with subtle continuous pulse |
| **Unreachable** | `semantic.error` dot, "backend unreachable" in `semantic.error`. Click → opens Connection settings. |

### 5.2 Chat transcript

| State | Visual |
|---|---|
| **Empty (new conversation)** | Centered: "What are we working on?" Geist Sans 24pt regular `fg.secondary`. No buttons. Input bar is focused. |
| **Loading (first response streaming)** | Last message bubble shows streaming chunks `stream` animation. Status line: "Iteration 1/30 · model thinking…" |
| **Tool dispatch in progress** | Status line: "Iteration 4/30 · running read_file" with mini-spinner |
| **Build verifying** | Status line: "Iteration 4/30 · verifying build" with mini-spinner |
| **Build pass** | Status line momentarily: "✓ build passed" in `semantic.success`, then resumes normal |
| **Build fail** | Status line: "✗ build failed — agent will retry" in `semantic.error` |
| **Stalled** | Yellow banner above input: "Agent is repeating itself. Continue, revise, or stop?" with action buttons |
| **Finished** | Status line: "Finished: stop" in `fg.secondary` |

### 5.3 InputBar

| State | Visual |
|---|---|
| **Empty + focused** | Placeholder "Ask the agent…" in `fg.tertiary`, cursor blinks |
| **Empty + unfocused** | Same placeholder, no cursor |
| **Has content** | Body text in `fg.primary`, send button enabled |
| **Running** | Editor still editable (queue next message), send button replaced by Stop button (red) |
| **Disabled (no model)** | Editor `fg.tertiary`, placeholder "Pick a model to start.", send button disabled |

### 5.4 Sidebar

| State | Visual |
|---|---|
| **Conversations empty** | §4.6 empty state |
| **Loading conversations** | Skeleton rows (3) with `bg.muted` shimmer for 200 ms or until load finishes (whichever first) |
| **Filtering by project** | "Showing 8 of 42 conversations" caption above list, "Clear filter" plain button |

### 5.5 Settings sheets

| State | Visual |
|---|---|
| **Test connection: idle** | Button "Test connection" |
| **Test connection: testing** | Button "Testing…" with mini-spinner, disabled |
| **Test connection: success** | Button text reverts; inline `semantic.success` checkmark + "Connected. 3 models." for 4 seconds, then fades |
| **Test connection: fail** | Inline `semantic.error` X + "Could not connect — timed out." Stays until next action. |

### 5.6 Patch Review Sheet

| State | Visual |
|---|---|
| **All hunks pending** | Header: "0 of N decided" |
| **Mixed decided/pending** | "5 of 12 decided · 4 accepted · 1 rejected" |
| **All decided, ready to apply** | "12 of 12 decided" + primary Apply button at bottom |
| **Conflict (hunk no longer applies)** | Conflict icon on hunk, "File changed since patch was generated — refresh" inline |

---

## 6. User flows

The six journeys the user will take most often. Each described as click-by-click.

### 6.1 First launch → first conversation

1. App opens → Onboarding Screen 1 (Welcome + Hardware)
2. Click Continue → Onboarding Screen 2 (Pick model)
3. Click Download on a card → background download starts, button changes to progress
4. Click Continue → Main window opens with welcome message, model picker chip shows download progress
5. User waits or types into input bar (queued until model ready)
6. Model ready → chip pulses, status line: "Model ready"
7. User hits Send (⌘⏎)
8. Streaming starts immediately; status line updates per iteration
9. Conversation auto-saves; new entry appears in sidebar

**Total clicks to first conversation: 3** (Continue, Download, Continue, then type + Send).

### 6.2 Bind project → agentic coding task

1. In an existing conversation, click "📁 Bind project" in chat header
2. NSOpenPanel opens, user picks a folder, hits Bind
3. Chat header now shows project name as a chip
4. User types "audit the codebase, find any TODOs, summarize what's missing"
5. Send. Agent reads MEMORY.md/DECISIONS.md from project, loads skills, starts iterating
6. Tools dispatch, results appear inline as tool result cards
7. After completion, agent's final message + status line "Finished"
8. User can immediately ask follow-up — context preserved

### 6.3 Worktree mode + patch review

1. Toggle worktree icon in chat header (shield)
2. Banner appears: "Worktree mode on. Agent will work in agentos/a4f2c3."
3. User asks for a code change
4. Agent makes the change in the worktree; on `apply_patch`, Patch Review Sheet appears
5. User reviews hunks: Accept some, Reject one, click Apply
6. Sheet dismisses; tool result shows "Patched X (2 hunks applied, 1 rejected)"
7. After agent finishes, click worktree shield → Worktree Review Sheet
8. Click Merge into main; commit message prompt; merge happens
9. Worktree shield turns off, banner: "Merged a4f2c3 into main."

### 6.4 Settings: change model load parameters

1. ⌘, → Settings sheet
2. Click Models tab
3. Model dropdown: already on active model
4. Drag Context length slider from 32,768 → 65,536
5. Reload banner appears: "Reload model to apply load changes"
6. Click "Reload now"
7. Banner replaced with progress: "Reloading model…" with mini-spinner
8. After ~10s: "Model ready" success flash
9. Close sheet (Done or ⌘W)
10. Back in chat — context usage chip now shows "/ 65,536" denominator

### 6.5 Connect Xcode to NEW DAY

1. Settings → Connection (or System Prompt? — Local API lives in §4.3 Tab 2 Connection sub-section)
2. Toggle "Run OpenAI-compatible server on app launch" on
3. Confirmation: "Server running on http://localhost:11435/v1"
4. Click "Copy Xcode setup steps" — copies a snippet
5. Open Xcode → Settings → Intelligence → Add provider
6. Paste; Save
7. Xcode now uses NEW DAY's **Local API proxy** for inline completions (backend chat only — not the full in-app agent tool loop)

### 6.6 License activation

1. Trial expired → main window locked, single sheet appears: "Your trial has expired."
2. Sheet offers: "Enter license key" / "Buy a license" / "Continue trial" (greyed, "0 days left")
3. User clicks Buy → browser opens to agentos.tools/buy with prefilled discount code if any
4. User completes purchase, gets license via email
5. Back in NEW DAY, click "I have a license"
6. Paste key, click Activate
7. Verification (offline, ~50ms), success → sheet dismisses, app unlocks
8. Settings → Privacy & License now shows license status

---

## 7. Microcopy

Every primary-action label and important status message locked here.

### 7.1 Buttons

| Action | Label |
|---|---|
| Send message | "Send" (icon `arrow.up`) |
| Cancel running agent | "Stop" (icon `stop.fill`) |
| New conversation | "New" / ⌘N |
| Continue from onboarding | "Continue" |
| Download model | "Download" |
| Bind project folder | "Bind project" |
| Toggle worktree | "Worktree" |
| Toggle Safe Mode | "Safe Mode" |
| Apply patch | "Apply" |
| Reject all hunks | "Reject all" |
| Reload model | "Reload now" |
| Apply on next start | "Apply on restart" |
| Test backend connection | "Test connection" |
| Delete conversation | "Delete" (destructive) |
| Merge worktree | "Merge into main" |
| Discard worktree | "Discard" (destructive) |
| Buy a license | "Buy a license" |
| Enter license key | "Activate" |

### 7.2 Placeholders

| Field | Placeholder |
|---|---|
| Input bar (model ready) | "Ask the agent…" |
| Input bar (no model) | "Pick a model to start." |
| Conversation title (editing) | "Untitled" |
| System prompt override | "Inherits global prompt — type to override" |
| License key | "AGENTOS-XXXX-XXXX-XXXX" |
| Search conversations | "Search conversations" |

### 7.3 Status line phrases

Rotated through during long pauses (Claude.ai-style):

- "Thinking…"
- "Reading the project…"
- "Planning the next step…"
- "Verifying the build…"
- "Calling tools…"
- "Composing the response…"
- "Searching the codebase…"
- "Applying the patch…"
- "Checking memory…"

Pick one based on actual state (don't randomize when state is known). Random rotation only when "thinking" without active tool.

### 7.4 Error messages

Never blame the user. Suggest the fix.

| Scenario | Message |
|---|---|
| Backend unreachable | "Couldn't reach the model server at localhost:1234. Is LM Studio running?" |
| Build fail injected as tool result | "BuildGuard: build failed. The agent will read the errors and try to fix them." (in tool card) |
| Tool throws unexpected | "Tool `<name>` returned an error: <message>. The agent will see this and decide what to do." |
| Stall detected | "The agent is repeating the same action. You can continue (give it another try), revise (edit the last message), or stop." |
| License invalid | "That license key doesn't look right. Double-check the email it came in." |
| License expired | "This license expired on <date>. Renew at agentos.tools/buy." |
| Trial expired | "Your 14-day trial is over. Continue with a license, or close the window." |
| Disk full | "Disk is nearly full. NEW DAY can't write conversation history. Free up some space." |

---

## 8. Accessibility baseline

v1 commitments:

- **Reduced motion respected** (§2.5).
- **Increased contrast respected** — color tokens swap to higher-contrast variants when `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` is on.
- **VoiceOver labels** for every interactive control. Custom rotor for navigating conversation messages.
- **Full keyboard access** — every action has a kbd shortcut or is reachable via Tab.
- **No color-only signaling** — status uses icon + color, never color alone.
- **Min text size 13 pt** in any control; user can scale up via Settings → General.
- **Focus rings** always visible (2 pt `accent` ring at 6 pt radius).

Not v1: full WCAG AAA audit, screen reader scripting tests, low-vision UI alternate. v1.1 polish.

---

## 9. Dark mode parity rules

Three rules, no exceptions:

1. **Every color token has a dark-mode counterpart.** No raw hex literals in code; everything reads from the design token table.
2. **No setting exists only in light mode.** If a feature looks wrong in dark, redesign it for both — don't ship light-only.
3. **Visual hierarchy is preserved by token roles, not by lightness.** A primary button is `accent` in both modes; the *which orange* changes, the *role* doesn't.

Test policy: every screen has a dark-mode snapshot test in the test suite. Dark drift fails CI.

---

## 10. Responsive behavior

Window size: minimum 960 × 620 pt, opens at 1280 × 800 pt, fully resizable up to screen size.

| Window width | Sidebar | Detail | Notes |
|---|---|---|---|
| < 1080 pt | collapsed (icon-only) | full | Sidebar tabs become a compact icon strip |
| 1080–1400 pt | 260 pt | flex | Default layout |
| 1400–1920 pt | 280 pt | flex | Sidebar gets slightly wider |
| > 1920 pt | 320 pt | flex with max content width 1080 pt | Prevents stupidly-wide message bubbles |

Patch Review sheet and Worktree Review sheet: independently resizable to any size up to screen.

---

## 11. Sign-off

Read §1 (principles) first. If those four locked decisions still feel right, the rest follows.

The single most consequential section: **§2.3 (color)** — Azure as the accent color. Lock it now or lock something else now, but it has to lock before any chrome work begins. Changing accent later means revisiting every screen.

Second-most: **§3 (components)**. If any component shape is wrong, downstream screens get it wrong too.

Once §1, §2.3, and §3 are signed off, the rest is execution.

### Amendments log

| Date | Section | Change | Reason |
|---|---|---|---|
| 2026-06-02 | (initial) | Drafted | First version, locked four design decisions via sign-off question |
| 2026-06-02 | §2.3 | Accent color: Ember (warm orange) → Azure (modern blue, `#2563EB` light / `#60A5FA` dark) | User preference for blue accent over warm orange |
| 2026-06-02 | §4.7 (new) | Models sidebar tab spec with Library/Discover sub-tabs (LM-Studio-style HF browser + curated catalog) | DEV PLAN's catalog-only approach was too restrictive; hybrid pattern serves both safe-default and power-user audiences |
| 2026-06-02 | §4.1, §4.7 | Removed "recommended for your Mac" framing — Library shows only downloaded models; onboarding cards presented as equals with honest one-line descriptors | Patronizing to senior-dev audience; conflicts with BRAND voice; reduces support burden ("why isn't X recommended?") |
| 2026-06-02 | §2.3 | Palette adoption from DEV PLAN: primary accent Azure (`#2563EB`) → Cobalt (`#3385F2`); added Ember orange (`#E75D3C`) for send button, plus 5 semantic chromatic tokens (green/amber/red/blue/violet) and three-tone Claude.ai-style surfaces (canvas / sidebar / input) | DEV PLAN's palette is proven, looks polished + warm. NEW DAY's iteration-1 palette was correct in concept but visually sparse. Full adoption produces immediate visual richness without sacrificing the locked decisions. |

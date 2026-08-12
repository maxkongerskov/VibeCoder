# ARCHITECTURE — NEW DAY as a Finished Product

> This file describes what AgentOS NEW DAY *is* when complete. Not the path to get there, not what fits in a week — the target itself. Every other doc (`ROADMAP.md`, `WEEK_PLAN.md`, `SPRINT.md`) is a tactical projection of this.
>
> When tactical work and this document disagree, this document is the rail. Amendments require a written justification logged under §17.

---

## 1. The one-paragraph product

NEW DAY is a native macOS coding agent that runs on your own hardware **against a bring-your-own local OpenAI-compatible model server**. **Working backends today:** LM Studio, oMLX, Ollama, EXO, and custom `/v1` (all HTTP). **In-process Swift MLX** is an adapter **stub** (`mlx-swift` not wired — generation throws). **Bundled llama.cpp/GGUF** was a planned path and is **removed as a product** (no vendored binary; no `LiteLocalBackend`; legacy settings migrate to Ollama). The agent iterates plan → tool calls → verify → repeat, edits via SEARCH/REPLACE and unified diffs, isolates work in git worktrees (`<project>-agentcore-<id>` / `agentcore/<id>`), and can verify mutations with builds. It also exposes an OpenAI-compatible HTTP server on loopback for Xcode Intelligence — **v1 is a backend proxy** (`tools: []`); full agent-loop routing on that endpoint is not the default. Closed-source. No product license key or trial. No subscription. Model weights leave the Mac only if **you** point at a remote endpoint. Apple Silicon.

## 2. Target user (precise)

The person who buys NEW DAY for $430:

- Owns an Apple Silicon Mac with **≥32 GB unified memory** (the 7B floor) and aspires to 64–128 GB (the 32B/70B target).
- Writes **Swift or Apple-platform code primarily**, with secondary work in TypeScript, Python, Rust, or Go.
- Already runs **LM Studio, Ollama, or EXO** on their own machine. Knows what GGUF, Q4_K_M, and `-ngl 99` mean without looking them up.
- **Privacy non-negotiable.** Either professional (legal, medical, defence-adjacent) or temperamental.
- Already pays for **Cursor or Claude Code** today and is fatigued by subscription pricing + cloud dependency.
- Wants the agent loop, not just chat. Has hit the wall on raw LM Studio for real coding work.
- Solo or 1–5 person team. Not enterprise.

NEW DAY is **explicitly not for**: web developers who only touch HTML/CSS/JS, beginners learning to code, anyone whose codebase doesn't need privacy, hobbyists with <32 GB RAM (LM Studio is free, that's the floor for them).

## 3. Positioning

| If they say... | We answer... |
|---|---|
| "Why not Cursor?" | Subscription, cloud, your code goes to a third party. NEW DAY runs entirely on your Mac. Worktree isolation is real. |
| "Why not Claude Code?" | Same — cloud and subscription. Plus NEW DAY is native macOS, not Node/CLI-first. |
| "Why not LM Studio?" | LM Studio is chat. NEW DAY is the *agent on top of* LM Studio (and we can use it as a backend). |
| "Why not Ollama + Cursor with a self-hosted endpoint?" | That stack doesn't have a real agent loop with tools, build verification, or worktree isolation. NEW DAY is that layer, designed for it. |
| "Why not free / open-source?" | Closed-source means we ship a polished single binary. The economics fund continuous development. Free alternatives exist; we're the polished one. |
| "Why one-time and not subscription?" | We bet that "buy once, own it" is a defensible position against the entire competitive set. It's also honest — local-first software doesn't have ongoing cloud cost. |

Distribution/pricing TBD. **No product license keys, trials, or activation gate in the app.**

## 4. Product surface (every screen, every modal)

### 4.1 First launch

**Target design (below) is not the current app path.** As of 2026-07-23 the app opens straight into the main UI (onboarding flag is force-completed; no in-app weight download). **Practical first run:** install and start a local model server (LM Studio recommended), load a tool-capable model, then Settings → Connection → Test. See README “First-run: start a model server”.

**Aspirational wizard (future):**

1. **Welcome.** "AgentOS NEW DAY. Local-first coding agent. Nothing leaves your Mac *when you use a local server*." Hardware detected inline. No crash-reporting SDK shipped (Sentry removed). Continue.
2. **Connect a server / pick a model.** Prefer detecting LM Studio / oMLX / Ollama / EXO on loopback over promising in-app GGUF/MLX downloads. Optional curated cards remain valid as *catalog infrastructure*, not “we host the engine.”

Lands in a new conversation with Coder defaults once a backend answers `/v1/models`.

### 4.2 Main window

NavigationSplitView. Three columns conceptually, two visually (sidebar + detail; the third column is the inline patch/worktree review sheet when triggered).

**Sidebar** (~260 pt, claude.ai-style):
- **Conversations** (default) — list, newest first, with relative timestamp + first user message snippet. Right-click: rename, delete, export, duplicate.
- **Projects** — folder bindings. Each shows project name, last activity, conversation count. Click to filter conversations to that project.
- **Skills** — bundled + user-added. Pinned skills section + available. Click to inspect / pin / unpin.
- **Models** — Library (downloaded + catalog browse) + Developer tab (server status, port, logs, endpoint). Live download progress for in-flight downloads.

Sidebar has a segmented tab bar pinned to its top to switch between these four lists. ⌘N anywhere → new conversation.

**Detail pane**, top to bottom:

- **Chat header.** Editable title (click to rename). Project chip ("⌘-K Bind project" if unbound). Worktree toggle (shield icon — off / "agentos/abc123" on). Safe Mode toggle. Context usage chip ("4,649 / 32,768 (14%)" — green/yellow/red). Stop button when running.
- **Transcript.** Scrollable. User bubbles right-aligned accent; assistant content left-aligned with inline tool call stubs; tool result cards expandable showing the full output. Plan cards render as visual step trackers when the agent makes a plan. Streaming tokens render live with smooth replace. Auto-scroll to bottom on new content.
- **Status line.** One row: spinner (when running) + iteration count + last tool + build status. "Iteration 4/30 · apply_patch ✓ · build ✓".
- **Input bar.** Multi-line `TextEditor` with placeholder "Ask the agent…". Enter sends; Shift-Enter newline. Attached skills appear as removable chips above the input. Model picker chip floats top-right (mirrors the toolbar one).

**Toolbar:**

- **Left:** Model picker chip (backend + model + load progress). Click → pick backend + model. Green/orange/red status dot.
- **Right:** Settings (gear), History search (magnifier), New conversation (square.and.pencil).

### 4.3 Settings sheet (5 tabs)

Per-model load + inference + system prompt all live under **Models**, alongside a Connection tab for backend wiring. Top-level Sampling/SystemPrompt tabs are intentionally absent — sampling belongs to a specific model, not the app.

1. **General** — appearance (light/dark/system), font size, agent trace toggle.
2. **Connection** — active backend picker; per-backend host/port + "Test connection" button; Local API server toggle + port + "Run on app launch" + Xcode setup instructions.
3. **Models** — see §4.3.1 below. The fattest tab; covers per-model load + inference + system prompt + reload-banner UX.
4. **Privacy** — Sentry opt-in (with full explanation of what's sent), conversation backup (export/import/clear all).
5. **About** — version, build, credits, legal. (No Sparkle auto-update.)

#### 4.3.1 Models tab (the load-settings home)

```
┌────────────────────────────────────────────────────────────────┐
│ Model: [Qwen2.5-Coder 32B Instruct ▾]                           │
├────────────────────────────────────────────────────────────────┤
│ ⚠ Reload model to apply load changes   [Reload now] [×]        │  ← only when dirty
├────────────────────────────────────────────────────────────────┤
│ LOAD SETTINGS  (require reload)                                 │
│   Context length         [────────●──] 32,768 / 262,144 max     │
│   GPU offload layers     [─────────●─] 99 / 99                  │
│   Flash attention                          [✓]                   │
│   KV cache type          ( f16 │ q8_0 │ q4_0 )                  │
│                                                                 │
│ INFERENCE SETTINGS  (apply next turn — no reload)               │
│   Temperature            [──●────────] 0.30                     │
│   Top-P                  [─────────●─] 0.95                     │
│   Top-K                  [──●────────] 40                       │
│   Repeat penalty         [──●────────] 1.05                     │
│   [Reset to Coder defaults]  [Reset to Balanced defaults]       │
│                                                                 │
│ SYSTEM PROMPT OVERRIDE  (per-model; falls back to global)       │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │ [empty — inheriting global system prompt]                │  │
│   └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

Rules:

- **Per-model JSON** at `~/Library/Application Support/AgentOS-NewDay/model-settings/<modelId>.json` is the canonical store. UI reads + writes it; never bypasses.
- **Catalog-recommended defaults** populate the JSON on first activation per model — smart defaults out of the box.
- **Load setting changes** mark the model dirty → non-modal "Reload model to apply" banner appears at top of the tab + on the chat header. Two actions: `Reload now` (5-second downtime) / `Apply on restart`.
- **Inference setting changes** apply on the next agent turn — no reload, no banner.
- **System prompt override** is optional; empty means "inherit global." Token count shown below the editor.
- **Sliders** use Azure thumb on `bg.muted` track; live value to the right in mono.
- **Per-backend constraints**: load fields that don't apply to a backend (e.g., `--cache-type-k` is only llama.cpp) are hidden when the active model belongs to that backend.

### 4.4 Modals & sheets

- **Patch review sheet.** Side-by-side syntax-highlighted diff (Tree-sitter). Per-hunk Accept/Reject. "Apply all" / "Reject all" shortcuts. Triggered for every `apply_patch` in Safe Mode; opt-in elsewhere.
- **Worktree review sheet.** Live worktree status + file-by-file diff vs main. Merge / Discard / Continue working buttons.
- **No product license / trial UI.** The app does not require a license key.
- **Updates.** Manual DMG / GitHub Releases (Sparkle removed).
- **Onboarding wizard.** §4.1.
- **Project bind dialog.** Native NSOpenPanel for folder selection.

### 4.5 Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New conversation |
| ⌘W | Close window |
| ⌘, | Settings |
| ⌘K | Bind project to active conversation |
| ⌘L | Toggle worktree mode |
| ⌘⇧L | Toggle Safe Mode |
| ⌘⏎ | Send (also: ⏎ alone in the input) |
| ⌘. | Cancel running agent |
| ⌘F | Search conversation history |
| ⌘⇧F | Global search across all conversations |
| ⌘1/2/3/4 | Switch sidebar tab (Conversations / Projects / Skills / Models) |
| ⌘[ / ⌘] | Previous/next conversation |
| Esc | Dismiss sheet |

## 5. System architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  Surfaces (3, sharing one core)                  │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────┐ │
│  │ AgentOS.app  │    │ agentos CLI  │    │ LocalAPIServer     │ │
│  │ (SwiftUI)    │    │ (executable) │    │ (OpenAI-compat)    │ │
│  └──────┬───────┘    └──────┬───────┘    └─────────┬──────────┘ │
└─────────┼──────────────────────┼──────────────────────┼──────────┘
          ▼                      ▼                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                  AgentCore (Swift library)                       │
│                                                                  │
│  Orchestration:                                                  │
│    AgentLoop ──▶ Planner ──▶ Compactor ──▶ Verifier (BuildGuard)│
│                                                                  │
│  Capability layer:                                               │
│    ToolRegistry (single protocol, dynamic dispatch)              │
│       ├─ Filesystem tools                                        │
│       ├─ Shell + Build + Test tools                              │
│       ├─ Git + Worktree tools                                    │
│       ├─ Web + Documentation tools                               │
│       ├─ PDF/OCR tools (App-hosted offline; PDFToolRegistration) │
│       ├─ Planning + Memory tools                                 │
│       ├─ find_symbol (LSP when SourceKit present; else text)     │
│       └─ Agent tools (tool_search, task family, ask_user)        │
│                                                                  │
│  Inference layer:                                                │
│    InferenceBackend protocol                                     │
│       ├─ LMStudioBackend / OMLXBackend / OllamaBackend (HTTP)  ✓ │
│       ├─ EXOBackend (HTTP + /state topology)                   ✓ │
│       ├─ OpenAICompatibleBackend (custom /v1)                  ✓ │
│       ├─ MLXBackend (in-process — STUB; mlx-swift not wired)     │
│       └─ LlamaCppBackend (REMOVED as product; use Ollama/custom) │
│                                                                  │
│  Stores:                                                         │
│    ConversationStore · ProjectStore · NoteStore                  │
│    ModelCatalog · ModelSettingsStore · DiagnosticsHub            │
│    SkillDiscovery (SKILL.md index; not a SkillStore marketplace) │
│    MemoryBackend (keyword/FTS + extractive dream — no embeddings)│
│                                                                  │
│  Cross-cutting:                                                  │
│    PatchEngine · WorktreeService · find_symbol (lsp|text-index)  │
│    HardwareInfo · TokenEstimator · Tracer · SafeBash seatbelt    │
│    (optional sandbox-exec for run_shell children — NOT App Sandbox)│
└─────────────────────────────────────────────────────────────────┘
```

### 5.1 The agent loop, complete

```
INPUT: user message + conversation + active model + ToolContext
OUTPUT: updated conversation, persisted

loop while iteration < cap:
    1. System prompt assembly
         ├─ baseline editing rules
         ├─ active workflow preset prologue
         ├─ project root + worktree status notice
         └─ Safe Mode allow-list summary (if active)
         (v1: skills are user-attachable in the UI but not
          injected into the prompt; memory tools deferred to v2.0
          so cold-start latency stays in budget for small models.)

    2. History compaction (tiered)
         ├─ recent 10 turns verbatim
         ├─ turns 11-30 semantically summarized (auxiliary model)
         └─ 31+ collapsed to "what happened / what was decided" bullets

    3. Tool subset selection
         ├─ core tools always
         ├─ conversation.unlockedDeferredTools (revealed by tool_search)
         └─ deferred tools hidden by default

    4. Stream model call
         ├─ via active backend
         ├─ emit content deltas + tool call deltas to UI
         └─ collect into ChatMessage

    5. If tool_calls present:
         ├─ parallel dispatch for read-only tools
         ├─ serial dispatch for mutating tools
         ├─ permission check (Safe Mode allow-lists)
         ├─ append results as tool messages
         └─ goto 6

    6. If file-mutating tools were called:
         └─ BuildGuard.verify(workspace)
              ├─ swift build / xcodebuild / cargo / npm / pytest
              ├─ if fail: inject build log as tool message, goto 2
              └─ if pass: continue

    7. Anti-confabulation gates:
         ├─ if model declared "done" after failed tool: force verification turn
         ├─ if model edited files but didn't read them back: force read turn
         └─ if 3 identical tool signatures in last 3 turns: stall, break

    8. If no tool calls: 
         ├─ persist conversation
         ├─ emit .finished event
         └─ break

cap reached: emit .iterationCapHit, break
```

### 5.2 BuildGuard taxonomy

Detect-and-run, in order:

1. `Package.swift` → `swift build`
2. `*.xcworkspace` → `xcodebuild -workspace ... -scheme <auto> build`
3. `*.xcodeproj` → `xcodebuild -project ... -scheme <auto> build`
4. `Cargo.toml` → `cargo check`
5. `tsconfig.json` → `npx tsc --noEmit`
6. `pyproject.toml` or `setup.py` → `python -m py_compile` over touched files
7. None of the above → log "no build system, skipping" and continue

Output: pass / fail / no-build-system. Fail injects truncated stderr (8 KB cap) back into the loop.

### 5.3 Backend completeness matrix

| Backend | Inference | Tool calls | Streaming | Load / list | Model download | Notes |
|---|---|---|---|---|---|---|
| **LM Studio** | ✓ HTTP | function calling | SSE | loaded-only via `/api/v0/models` | via LM Studio app | Strongest day-1 path |
| **oMLX** | ✓ HTTP | function calling | SSE | load/unload + status API | via oMLX | Separate process, not in-process MLX |
| **Ollama** | ✓ HTTP | function calling | SSE | `/v1/models` (all tags; no loaded filter yet) | via Ollama | Replaces removed llama.cpp product |
| **EXO** | ✓ HTTP | function calling | SSE | pin Model ID in Settings | n/a | `/state` topology; avoid full catalog flood |
| **Custom** | ✓ HTTP | function calling | SSE | `/v1/models` | n/a | Any OpenAI-compat base URL |
| **MLX (in-process)** | ❌ stub | Route B target | throws | HF cache helpers only | `MLXHubDownloader` real; UI not product path | `Package.swift`: mlx-swift not wired |
| **llama.cpp (bundled)** | ❌ removed | — | — | — | — | No LiteLocalBackend; no vendored binary |

All **HTTP** adapters implement the same `InferenceBackend` protocol; the agent loop never branches on backend type for streaming.

### 5.4 Tool surface (v1)

**Honesty rule:** names below match `ToolRegistry.registerBuiltins()` as of 2026-07-24. Do not invent aliases (`build_xcode`, `git_log`, …) for marketing — check the registry.

**Filesystem (core)**
- `read_file`, `write_file`, `edit_file` (SEARCH/REPLACE primary), `apply_patch`
- `delete_file`, `move_file`, `create_directory`, `list_directory`, `glob_files`, `grep_code`

**Shell (core)**
- `run_shell` — synchronous, bounded output; optional **seatbelt** (`sandbox-exec`) for child processes when Settings enable it — **not** macOS App Sandbox for the app binary

**Git (core)**
- `git_status`, `git_diff` only (no registered `git_log` / `git_show` / `git_blame` / `git_commit` tools)

**Build / Xcode (core)**
- `xcode_build`, `xcode_project_editor` (not a full build-matrix tool family)

**Web / docs (core — registered)**
- `web_search`, `fetch_url`, `fetch_rss`, `apple_docs`

**Planning (core)**
- `create_plan`, `update_todo`, `revise_plan`

**Memory (registered)**
- `memory`, `memory_search`, `memory_get` — keyword/FTS recall; **extractive** dream when `dreamEnabled` (not embedding/MMR vectors)

**Checkpoints / skills**
- `restore_checkpoint` — filesystem turn restore (code-aware `/rewind`)
- `load_skill` — SKILL.md progressive load

**Worktree (service + task isolation — not worktree_* tools)**
- `WorktreeService`: path `<project>-agentcore-<shortid>`, branch `agentcore/<shortid>`.
- `task` supports `isolation: worktree`. **No** registered `worktree_create` / `worktree_merge` tools.

**Agent meta (core)**
- `tool_search`, `ask_user`, `task` / `get_task_output` / `wait_tasks` / `kill_task`, `find_symbol` (labels `backend: lsp|text-index` — not a full IDE LSP suite)

**Code navigation / LSP (partial — not a full IDE)**
- `find_symbol` (`FindSymbolTool` + `CodeNavService` + optional `Sources/AgentCore/LSP/*`).
- **When SourceKit-LSP is on PATH**, may call `textDocument/definition`, `textDocument/references`, or `workspace/symbol`.
- **Otherwise** (or on empty/error): `SymbolIndex` text substring scan.
- **Every tool result** includes `backend: lsp` or `backend: text-index` plus an honesty line. Do **not** market as multi-language IDE host, diagnostics UI, or permanent language-server pool (spawn-per-call today).

**Honesty:** count tools from `ToolRegistry.registerBuiltins()` plus App-hosted dynamic tools (e.g. `PDFToolRegistration`) — do not hardcode marketing numbers that drift.  
**Defined but intentionally unregistered:** `text_edit`, `notebook`, `porting`.  
**App-hosted offline PDF (registered at boot via `PDFToolRegistration`):** core `extract_pdf_text`, `ocr_image`, `create_pdf`; deferred `manipulate_pdf`, `fill_pdf_form`, `sign_pdf`. Bundled skill `pdf`. No network permission.

**Still incomplete / not full product:**
- Full LSP product surface (persistent host, didChange, multi-server registry, IDE-grade nav) — **partial SourceKit bridge only**
- Skills **marketplace / attach UI** (SKILL.md discovery + `load_skill` **are shipped** — see §5.5)
- In-process MLX generation (stub only)
- Zero-deps / auto-spawn model runner (bundled llama.cpp **removed**)
- LocalAPI multi-step agent-loop is **opt-in** (D1; default still proxy — §5.7)
- Grok-class **`monitor_*` tool product** (`JobMonitor` is a thin BackgroundJob listing helper only)
- macOS **App Sandbox** entitlements redesign (current app entitlements are empty; seatbelt ≠ App Sandbox)
- First-run Connection wizard (app currently skips onboarding)

MCP client, sub-agents (`task`), plan tools, checkpoints, and skills index are present beyond older “deferred” lists.

### 5.4.1 Model catalog (infrastructure, not recommendations)

Curated catalog data in-tree (e.g. MLX/GGUF seed entries, hardware-fit helpers) is **infrastructure**, not a promise that the app downloads and runs those weights itself.

1. **BYO server remains the v1 download path** — models are loaded in LM Studio / oMLX / Ollama / EXO; the app lists what the server exposes.
2. **Tested model configs** — known families may carry sampling / context defaults when ids match.
3. **Hardware-fit hints** — RAM-aware helpers exist for future wizard / Discover; do not claim an in-app GGUF/MLX storefront is shipping.

We do not market a “bundled GGUF catalog ships weights” story. Discover/Library UX should only claim what the active HTTP backend can list.

### 5.5 Skills system — **partially shipped (corrected 2026-07-24)**

> **Older claim (2026-06-10):** “skills are NOT built; no SKILL.md loader.” **Code reality today:** `SkillDiscovery` + registered `load_skill` tool are live. There is still **no** Skills sidebar tab, **no** SkillStore marketplace, and **no** user attach-chip UI of the aspirational design below.

**What ships:**

| Piece | Status |
|-------|--------|
| `SkillDiscovery` | Scans `.vibecoder/skills`, `.grok/skills`, `.claude/skills`, **`.cursor/skills`** under project/worktree + user home |
| Prompt index | Name + description only (metadata-first; bodies not loaded until `load_skill`) |
| `load_skill` tool | Full SKILL.md body injected as a tool result envelope |
| Bundled skills | Small in-code set (e.g. `verify`, `commit`) — **not** 182 marketplace packages |
| Disk override | Project/user SKILL.md packages override bundled names |

**What does not ship:** Settings → Skills catalog UI, pin/attach chips, skill marketplace, 182 DEV-PLAN packages, launch-time SkillStore preload of every body.

**Latency posture:** index is metadata-only so large SKILL.md files do not tax every turn; full body loads on demand via `load_skill`. Prefer that over always-on injection of multi-KB skill markdown into small local models.

**Deferred / product UI:** auto-attach by trigger, pinned-skill chips, export marketplace (v1.2+ narrative below still aspirational).

### 5.6 Memory system — **partially shipped (corrected 2026-07-23 / P7 2026-07-24)**

Older docs claimed memory was cut from v1 and unregistered. **Code reality:** `memory` / `memory_search` / `memory_get` are registered; `MemoryBackend` + optional project-memory inject are wired via `AgentLoop.Config` (defaults on for memory/dream/inject flags).

**Dream honesty (P7):** `dreamEnabled` runs **extractive** consolidation (`MemoryDream` — regex/line heuristics over session logs into MEMORY.md). Search is **keyword/FTS-style** (`MemoryIndex`). There is **no** embedding model, sqlite-vec, or MMR vector store in-tree. Do not market “semantic embeddings dream” or Grok-class memory.

**Latency note (still valid):** large always-on MEMORY tails hurt small local models. Prefer selective inject and tools over dumping multi-KB logs into every system prompt.

**What this means for users:** within a chat, the context window still dominates. Across chats, memory tools can persist/recall when enabled — best-effort, not a guaranteed long-term knowledge base.

**Honesty rule:** do not re-state "memory deferred / unregistered" in marketing or README.

### 5.7 LocalAPIServer (the moat)

OpenAI-compatible HTTP server, default port 11435, **bound to loopback only**.

> **D1 (2026-07-24) reality:** `LocalAPIServer` is **opt-in dual-mode**:
>
> | Mode | When | Behavior |
> |------|------|----------|
> | **Proxy (default)** | `agentToolsEnabled == false` | Stream completions from the active backend with **`tools: []`**. Xcode-safe. |
> | **Agent loop (opt-in)** | `agentToolsEnabled == true` | Run a **bounded multi-step `AgentLoop`** (model → tools → model): tools **execute** server-side and the model is re-prompted. Hard-capped at `LocalAPIServer.agentLoopMaxIterations` (8). |
>
> Default remains **off**. Do not claim “Xcode is always agentic” — users
> must enable the Settings toggle. Reasons default stays off: Xcode’s own
> editor tools conflict; large local models may choke on tool catalogs;
> unbounded agent loops on an open HTTP port would be unsafe even on
> loopback without a cap.

Endpoints:
- `GET /v1/models` — proxies the active backend's model list
- `POST /v1/chat/completions` — **default:** proxy with **`tools: []`**; **opt-in:** bounded AgentLoop SSE (content deltas + final `[DONE]`)
- `POST /v1/embeddings` — not implemented on this server (docs that claim it are aspirational; expect 404/501)

**Headless serve (`AgentOSServeServer`):** same OpenAI-compat routes. When
`configure(backend:)` is set, completions proxy that backend; when unset,
responses use the intentional **`agentos-echo`** stub (not a real model).
`agentToolsEnabled` default-off; agent-loop multi-step is the LocalAPI
opt-in path (serve may still be proxy/schemas-oriented — check configure).

Usage: Xcode 16 → Settings → Intelligence → Add provider → `http://localhost:11435/v1`. With the agent-loop toggle **off** (default), completions are a plain proxy. With it **on**, clients that can tolerate multi-step tool latency get a capped agent turn. The full in-app chat remains the primary agent surface (worktrees, review UI, MCP).

**The local server is started from the app (Settings → Local API → Start).** Headless automation can construct `AgentOSServeServer` / `LocalAPIServer` with an explicit backend.

### 5.8 CLI surface

**Removed.** Development focuses on the native macOS app (`App/VibeCoder.xcodeproj`). Headless/eval runners may appear under `Evals/` or scripts; do not document a shipping `agentos` CLI unless it is reintroduced.

## 6. Data architecture

### 6.1 Persistence layout

```
~/Library/Application Support/AgentOS-NewDay/
├── settings.plist                          # UserDefaults wrapper
├── conversations/<uuid>.json               # one file per conversation, atomic write
├── projects/<sha256-of-path>.json          # per-project settings + memory paths
├── model-settings/<modelId>.json           # per-model: context, GPU layers, sampling
├── skills/                                 # user-created skills
├── catalog.cached.json                     # last-fetched catalog (stale-while-revalidate)
├── traces/<conversation-id>.jsonl          # agent trace, opt-in
└── logs/                                   # LocalAPIServer access log, llama-server stderr

~/.cache/huggingface/hub/                   # MLX + GGUF model weights (HF-standard layout)
~/Library/Logs/AgentOS-NewDay/              # standard macOS logs (not in App Support)
```

### 6.2 Conversation schema

Codable JSON, every field has `decodeIfPresent` + default. Adding fields never breaks existing files.

```swift
struct Conversation {
    let id: UUID
    var title: String
    var createdAt, updatedAt: Date
    var messages: [ChatMessage]
    var modelID: String?
    var projectRoot: URL?
    var worktreeBranch: String?
    var pinnedSkills: [String]
    var systemPromptOverride: String?
    var samplingOverride: SamplingParams?
    var unlockedDeferredTools: [String]
    var preset: WorkflowPreset?
}
```

### 6.3 Settings cascade (2-layer in v1)

```
conversation override > global
```

Per-model settings are orthogonal: tracked per `<modelId>`, applied whenever the model is active, regardless of cascade.

**v1 is 2-layer (global + conversation)** because the target user is a solo developer (§2). 3-layer cascade with project-level `.agentos/settings.json` for team git-trackability lands in **v1.1** when teams become a real buyer segment. Reducing layers in v1 also reduces "which setting wins?" debugging surface.

### 6.4 Migrations

`Migration.swift` actor with a version field in `settings.plist`. Each schema bump adds one migration function. Runs silently at launch. Users see nothing.

Compatibility with DEV PLAN: NEW DAY can read DEV PLAN's `conversations/` directory verbatim (same Codable shape, NEW DAY just adds fields). One-shot import on first launch if DEV PLAN's App Support dir is detected.

## 7. Performance budget

Target hardware: M3 Max with 64 GB unified memory. Sustained workload.

| Metric | Target | Hard floor |
|---|---|---|
| MLX 7B Q4 streaming | 80–120 tok/s | 50 tok/s |
| MLX 32B Q4 streaming | 25–40 tok/s | 18 tok/s |
| llama.cpp 32B Q4_K_M w/ Metal | 25–40 tok/s | 18 tok/s |
| llama.cpp 70B Q4_K_M (M3 Max 128 GB) | 8–12 tok/s | 6 tok/s |
| Cold app launch | <2 s | 4 s |
| First-token latency (warm model) | <500 ms | 1500 ms |
| Cold model load (32B MLX) | <30 s | 60 s |
| Cold model load (32B GGUF) | <40 s | 90 s |
| App memory footprint (no model loaded) | <500 MB | 800 MB |
| UI frame rate during streaming | 60 fps | 30 fps |
| Tool dispatch overhead (single tool) | <5 ms | 20 ms |
| Context compaction (per turn, cached) | <50 ms | 200 ms |
| Build verification (Swift Package) | dominated by `swift build` itself | n/a |

Speculative decoding (when draft model is set) target: **1.5×–2× throughput** on common code completions.

## 8. Quality bar (definition of "shipped")

- **~300+ tests, all passing.** No flakiness in CI for 7 consecutive days before release.
- **Zero `try?` in production code paths.** Audited in CI via grep.
- **Crash-free rate >99.5%** (via Sentry opt-in telemetry, anonymized stack traces only).
- **Notarized, hardened runtime, signed with Developer ID.**
- **All four backends end-to-end-validated** with at least one real model each.
- **LocalAPIServer validated against Xcode Intelligence + curl + Postman.**
- **First-launch onboarding completes in <60 seconds on a fresh Mac.**
- **No memory leaks under 4-hour sustained use** (verified via Instruments).
- **All keyboard shortcuts (§4.5) work and are documented.**
- **The DMG installs cleanly on a clean Mac** with no Gatekeeper warnings.

## 9. Distribution architecture

### 9.1 Build & ship pipeline

```
git push → CI (macos-14)
  ├─ swift build --configuration release
  ├─ swift test
  ├─ xcodebuild -workspace ... -configuration Release archive
  ├─ codesign with Developer ID Application
  ├─ notarytool submit + wait
  ├─ stapler staple
  ├─ create-dmg → AgentOS NEW DAY-<version>.dmg
  ├─ codesign DMG + notarize DMG + staple DMG
  ├─ generate Sparkle appcast entry
  └─ upload to agentos.tools/releases/
```

### 9.2 License system (removed)

> **Removed from the product.** There is no product license key, trial, or activation gate. Historical notes below are obsolete.

### 9.2 (historical) License system (v1)

- **Ed25519 signed offline.** Public key embedded in the app. Private key on a Cloudflare Worker connected to Paddle (or LemonSqueezy — TBD).
- **14-day trial** activated on first launch, no email required.
- **License key = <user-email-hash>.<base64-payload>.<base64-signature>**. Payload includes email, purchase date, license type, and optional expiry.
- **Offline verification.** No phone-home ever. License works on aircraft.
- **Unlimited installs per user (honor system in v1).** The license key works wherever the user installs it; we track activations server-side and soft-flag abuse via Paddle data. **Hardware binding + deactivation flow is v1.1** — added only if piracy becomes a measurable revenue leak. Trade-off: v1 ships simpler, friendlier (no "I got a new Mac" support tickets); v1.1 hardens if needed.

### 9.3 Updater

Sparkle 2.x with `SUFeedURL = "https://agentos.tools/appcast.xml"`. Delta updates when possible. EdDSA-signed appcast.

### 9.4 Telemetry

Sentry SDK, **off by default**. Opt-in in onboarding step 4 and Settings → Privacy. When enabled:

- Anonymized stack traces only
- No conversation content
- No model data
- No file paths from user's project
- DSN-locked to NEW DAY's project; Sentry's data retention is 90 days

### 9.5 Distribution sites

- `agentos.tools` — landing page, download, docs, buy button (Paddle/LemonSqueezy checkout)
- `agentos.tools/appcast.xml` — Sparkle feed
- `agentos.tools/catalog.json` — model catalog (refreshed at app launch, stale-while-revalidate)

## 10. Integration architecture

### 10.1 Xcode Intelligence (loopback completions proxy)

`http://localhost:11435/v1` set as a custom provider in Xcode 16 → Settings → Intelligence. By **default**, Xcode's completions **proxy to the active backend** with **`tools: []`**. Optionally enable **Agent loop on Local API** in Settings for a **bounded** multi-step tool loop (capped iterations; still not full worktree/UI parity with in-app chat).

**Why it matters:** one local OpenAI-compatible base URL. Default path is safe for Xcode. Opt-in path is for clients that want server-side tool execute without using the SwiftUI app. See §5.7.

**Honesty (PB7):** do not market this as “Cursor-level agentic Xcode.” Opt-in `agentToolsEnabled` only attaches tool **schemas** to the proxy request; it is not a full agent gateway. Multi-step tool execution stays in-app.

### 10.2 MCP (Model Context Protocol) — shipped client

Anthropic's MCP is the plugin protocol for AI coding agents. NEW DAY ships an **MCP client** (stdio + HTTP/SSE, Settings → MCP) so users can plug in third-party MCP servers. Tools appear as `server__tool` in the agent registry when servers are enabled.

Exporting NEW DAY's own tools as an **MCP server** for other hosts remains a future option, not a v1 claim.

### 10.3 Skill marketplace — v1.2

User skills (markdown files with front matter) get an export bundle format (`.agentos-skill` = zip). A community page at `agentos.tools/skills` hosts shared skills with browse, install, rate.

Skills can declare dependencies on tools (or MCP servers); installer verifies tool availability before activating.

### 10.4 Other (post-v1)

- **Linear / GitHub / Jira tool integrations** as bundled MCP servers
- **Voice transcription input** (whisper.cpp via subprocess) — possibly v2
- **Plugin SDK** for native Swift extensions — v2

## 11. Cross-cutting concerns

### 11.1 Diagnostics

All failure paths route through `DiagnosticsHub`. UI surfaces severe events in a "Recent issues" panel. CLI prints to stderr. Optional log file at `~/Library/Logs/AgentOS-NewDay/diagnostics.log`.

### 11.2 Worktree safety

Toggle on the chat header creates a real `git worktree` at `<project>-agentcore-<id>` on branch `agentcore/<id>` (see `WorktreeService`). All file mutations route to the worktree when active. Review sheet shows the diff vs main; merge/discard dispose the branch + worktree.

### 11.3 Safe Mode + shell seatbelt (not App Sandbox)

**Safe Mode** (when configured): path / shell allow-lists consulted during tool authorization (`ToolAuthorization` / Safe Mode config) before mutating or executing tools. Product UI: shield / settings — defaults and exact chip wiring may vary; do not invent keybindings in marketing.

**Shell seatbelt (PB8 / PC2):** optional `sandbox-exec` profile around **`run_shell` child processes** (`SafeBash`) when Settings set seatbelt preference (default: Auto/edit mode only). Apple marks `sandbox-exec` **deprecated**; this is a **write fence for shell children**, not a substitute for shipping under the macOS **App Sandbox** entitlement.

**App Sandbox honesty (P7):** `App/VibeCoder.entitlements` is currently an **empty** entitlement set — the app is **not** sandboxed as an App Store-style container. LocalAPIServer loopback + free filesystem access assume direct distribution. Do not claim “App Sandbox hardened” for the product binary. Seatbelt ≠ App Sandbox.

### 11.4 Headless mode

App “Headless” / unattended posture (notifications, conservative system prompt). The interactive **`agentos` CLI was removed** — do not document `agentos run --headless` as a shipping CLI. Headless eval/script paths live under `Evals/` and scripts when present. Pairs with Safe Mode for unattended work.

### 11.5 Job monitor (not Grok monitor product)

`JobMonitor` / scheduler status snapshots list **background jobs** already tracked by `BackgroundJobManager` / scheduled tasks. This is **lightweight observability** (status strings for UI/settings). There is **no** registered agent tool named `monitor` / `monitor_*`, no continuous stdout streaming product, and no claim of Grok Build monitor parity. See polish P9 for UI copy.

### 11.6 Agent trace

Off by default. When enabled (Settings → General), writes one JSONL entry per loop iteration under Application Support traces (`VibeCoder` folder name in code). Useful for debugging tool selection or model behavior.

### 11.7 Token estimation

`TokenEstimator` provides approximate counts (English-text heuristic + per-backend tokenizer when available). Used for context-usage chip and compaction triggers. Approximate is fine; this isn't billing.

## 12. Failure modes (and what we do)

| Failure | Behavior |
|---|---|
| Model server unreachable | Picker chip turns red. Modal: "Backend unreachable. Check that LM Studio is running, or switch backend." |
| Model load fails | Diagnostics event + chip stuck on `.failed` with reason. User can retry or switch model. |
| Tool throws | Result message marked as error; agent sees it and can decide to recover or escalate via `ask_user`. |
| Build fails (BuildGuard) | Truncated stderr injected; agent retries on next turn. After 3 consecutive build failures: stall trigger, halt loop, surface to user. |
| Disk full | Diagnostics fatal. App refuses to write conversation; user prompted. |
| (removed) Product license expired | N/A — no product license gate. |
| Network unavailable | **Local tools + local model server on loopback still work.** Public-net tools (`web_search`, `fetch_url`, …) fail. App does not need cloud for the agent loop. Sparkle update check fails gracefully. (No product license phone-home.) |

## 13. The 10 explicit non-goals

These are decisions, not omissions:

1. **No cloud sync of conversations.** Strikes against "100% local."
2. **No team / multiplayer features in v1.** Solo dev focus. v2 might revisit.
3. **No cross-platform.** macOS Apple Silicon only. Linux/Windows is not on the roadmap.
4. **No model training.** Inference only. No fine-tuning UI.
5. **No voice / audio in v1.** Whisper/TTS deferred to v2.
6. **No translation / localization.** English-only at launch. Adding later is cheap if there's demand.
7. **No free tier.** Trial + paid. A free tier would dilute the price anchor and the "ownership" pitch.
8. **No open-source plugin marketplace.** Closed-core, possibly with curation if a marketplace emerges in v1.2.
9. **Not a replacement for Xcode.** We integrate via Intelligence; we don't rebuild the IDE.
10. **Not a generic macOS assistant.** Coding-focused. No "what's the weather" surface.

## 14. Roadmap from v1.0 to v2.0

| Version | Theme | Major adds |
|---|---|---|
| **v1.0** | Foundation | Live backends: **LM Studio, oMLX, Ollama, EXO, custom HTTP**. In-process MLX = stub; bundled GGUF/llama = **removed**. Worktree (`agentcore/`), scheduled runs, per-project instructions, LocalAPIServer as **backend proxy**, Notes instead of Skills. Tool/memory surface: see `ToolRegistry` + §5.4/§5.6 honesty updates (2026-07-23). |
| **v1.1** | Polish + MCP | MCP client + server, per-hunk patch review polish, WorktreeReviewSheet → real `git diff`, Settings cascade UI refinement, performance tuning |
| **v1.2** | Skills marketplace | User skill creation UI, export bundle, marketplace listing at agentos.tools/skills, rating + install |
| **v1.3** | Catalog expansion | Auto-update catalog with monthly model curation, hardware-tier suggestions, draft-model speculative decoding for all GGUF models |
| **v1.4** | LSP polish | **Partial today:** optional SourceKit-LSP via `find_symbol` + text-index fallback. Still open: persistent host, multi-language registry, didChange after edits |
| **v1.5** | Sub-agent + planner depth | Better planner outputs, sub-agent inheritance refinement, parallel investigation patterns |
| **v2.0** | Cross-chat intelligence + collaboration | **MemoryTool + MEMORY.md / DECISIONS.md** auto-inject with embedding-based skill auto-attach (cheap context patterns suited to small models — see V2 ARCHITECTURE), Route B MLX, shared MEMORY.md sync, team license, collaboration session, shared skill libraries |

## 15. Pricing & business model

- **No product license key.** App is not gated by trial or activation.
- **No subscription, ever.**
- **Refund policy:** 30 days, no questions asked.

Distribution: Paddle or LemonSqueezy as merchant of record. Sales tax / VAT handled. Apple App Store **not** used (would forbid the LocalAPIServer behavior under sandbox rules). Direct distribution from agentos.tools.

## 16. Brand & voice

- Name: **AgentOS NEW DAY** (full), **AgentOS** (short).
- Tagline: "Local-first coding agent. Nothing leaves your Mac."
- Voice: precise, technical, dry. No hype. Talk to developers like developers.
- Visual: Geist Mono + Geist Sans. Minimal chrome. Dark mode parity with light. SF Symbols. No animation for animation's sake.
- The product personality is "the senior engineer who sits next to you" — not "AI assistant."

## 17. Amendments log

When this doc is amended, log the change here with date + reason. The doc itself is the rail; amendments are how the rail bends.

| Date | Section | Change | Reason |
|---|---|---|---|
| 2026-07-24 | §5 diagram, §5.4, §5.6, §11.3–11.5, §17 | **P7 docs honesty:** tool names match `registerBuiltins`; seatbelt ≠ App Sandbox; no Grok monitor product; dream is extractive not embeddings; diagram drops SkillStore; headless without fake `agentos` CLI | Polish P7 |
| 2026-07-24 | §5.5, §5.4 incomplete list, §10.1 | Skills honesty: `SkillDiscovery` + `load_skill` + `.cursor/skills` + metadata index shipped; marketplace/UI still deferred. §10.1 no longer claims Xcode runs full agent loop (proxy only). | Phase A PA9 / T4+T10 finish-lane lies |
| 2026-07-23 | §1, §4.1, §5 diagram, §5.3, §12, §14 | Wave B W14 honesty: BYO HTTP only; oMLX/Ollama first-class; MLX stub; llama product **removed** (not “scaffold”); first-run server guidance; no LiteLocalBackend | Sweep C-OFFLINE / W14-sweep; DESIGN/README aligned |
| 2026-07-23 | §1, §5.3–5.8, §10 worktree, §14 | Honesty pass: MLX/llama not bundled-ready; LocalAPI is proxy; memory tools registered; worktree names `agentcore`; CLI removed; tool counts from registry | Wave A #10 docs oversell; align with code |


| Date | Section | Change | Reason |
|---|---|---|---|
| 2026-06-02 | (initial) | Drafted | First version, cold-drafted from DEV PLAN analysis + today's conversation |
| 2026-06-02 | §4.1 | Onboarding 4 → 2 screens (welcome+hardware inline, pick model). Workflow presets deferred to v1.1. | Coder is 95% target; preset choice adds drop-off without value. |
| 2026-06-02 | §4.3 | Settings tabs 9 → 5. Sampling + System Prompt nested under new Models tab. Local API moved into Connection. License merged into Privacy. Agent tab dropped (defaults are right). | Over-categorization was opposite of "smart defaults" goal. Per-model settings belong with the model. |
| 2026-06-02 | §4.3.1 | Added Models tab spec — load + inference + system prompt per-model with reload-banner UX. | Closed the load-settings UX gap surfaced during review. DEV PLAN's BACKEND_PLAN proved the pattern; we kept it verbatim. |
| 2026-06-02 | §5.4 | Tool surface ~50 → ~35. Deferred to v1.1: `dispatch_task`, all 5 LSP tools, `git_stash`, `git_branch_create`, `search_man_pages`, `search_docc_archive`, `extract_citations`, `run_shell_long`, `ask_user`. | DEV PLAN's `dispatch_task` was under-utilized; LSP integration is design-heavy; the rest are niche. Saved ~1.5 days of v1 work + stronger v1.1 narrative. |
| 2026-06-02 | §6.3 | Settings cascade 3 → 2 layers (global + conversation). Project-level `.agentos/settings.json` deferred to v1.1. | v1 target is solo developer; 3-layer cascade serves teams. Reduces "which setting wins?" debugging surface. |
| 2026-06-02 | §9.2 | License hardware-bind deferred to v1.1. v1 ships unlimited installs per user (honor system + server-side activation tracking). | Hardware binding adds complexity + support burden; honor system + Paddle data is good enough at v1 scale. Add binding only if piracy becomes measurable revenue leak. |
| 2026-06-02 | §4.1, §5.4.1 (new) | Reframed catalog as infrastructure (not "recommended models"). Onboarding starter cards presented as equals; Library tab shows only downloaded models. | Patronizing to senior-dev audience; aligns with BRAND voice. Catalog still drives onboarding + tested configs + hardware-fit hints, silently. |
| 2026-06-09 | §5.7 | LocalAPIServer documented as v1 = backend proxy (loopback-only, no agent loop); agent-loop routing moved to v1.1 as an opt-in setting. | Code review found docs claiming the agent loop while the implementation passes `tools: []` — llama-server 400s on 15+ schemas and Xcode's own editor tools conflict. Honesty over aspiration; README aligned same day. |
| 2026-06-09 | §5.1, §5.4 | §5.1's compaction + anti-confabulation gates are now actually wired into `AgentLoop` (they existed as unused `ChatLoop` helpers). v1 registered tool surface is 17 tools (filesystem ×8, grep, shell, git status/diff, web ×3, apple_docs, tool_search); plan/build/worktree/memory tools listed in §5.4 are defined-or-planned but NOT registered in v1. | DEV PLAN port shipped the helpers unwired and the doc described the target, not the build. Memory injection stays out per §5.6 (off-by-default config flag now exists as the v2.0 switch). |
| 2026-06-09 | §11.3 | Safe Mode path checks canonicalize (absolute/`~`/`..`/symlinks) on both sides and cover `source`/`destination`/patch targets; shell allow-list is word-bounded and rejects metacharacters (`; & \| $( > <` backtick, newline). | Review found three path-escape classes plus chaining bypasses. Conservative posture: quoted metacharacters are also rejected in v1; quote-aware parsing is v1.1 polish. |
| 2026-06-10 | §5.4, §5.5 | Tool count stated honestly as **19 registered** (added xcode_build + xcode_project_editor; the rest of the "~35/~40" surface is unregistered). Skills system documented as **not built in v1** (replaced by Notes). | Audit found docs/website overstating tools ~2× and citing 131/182 nonexistent skills. Marketing must not cite a skill count or claim >19 tools. |
| 2026-06-10 | (new features) | **Scheduled tasks** are now real end-to-end: SchedulerService runs at boot, a "Scheduled" sidebar pane + New Schedule form with time-of-day, fired runs go **headless** (sleep assertion + summary + notification). **Per-project instructions** (`.agentos/instructions.md`) inject into every chat in a project. **Crash reporting** wired opt-in (Sentry, off by default, PII-scrubbed). `headlessMaxIterations` (default 100) gives overnight runs a long horizon. | Turned the decorative Tasks/Projects-instructions/crash toggles into working features; foundation for the EXO-cluster autonomy arc. |

---

## 18. Sign-off

Before this becomes the rail:

1. Read §1 (one-paragraph product). If that's not what you want NEW DAY to *be*, the rest of the doc is irrelevant — fix §1 first.
2. Read §2 (target user). If your real buyer is different, every product decision below changes.
3. Skim §4 (product surface). Anything that's wrong should be redlined.
4. Read §13 (non-goals). These are the easiest to disagree with — if any of these 10 should be in scope, the roadmap changes shape.
5. Read §15 (pricing). One-time vs subscription is the biggest single business decision.

Once §1, §2, §13, and §15 are signed off, the rest follows. Tactical docs (`ROADMAP.md`, `WEEK_PLAN.md`, `SPRINT.md`) get rewritten as projections of this rail.

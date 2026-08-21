# ARCHITECTURE — VibeCoder (rail)

> **Current product (claim freeze 2026-08-20):** VibeCoder is a native macOS **BYO OpenAI-compatible HTTP** coding agent. MIT, no license gate, no Sparkle, no Sentry. Binding a **git** project **enables worktree isolation by default** (escape hatch: edit main tree; merge is user-driven). Historical “AgentOS NEW DAY” / `$430` / wizard / `agentos` CLI copy below is **not** current — treat it as target archaeology unless a later §17 row says otherwise. Interactive **`vibecoder` REPL is C1** (same AgentCore; not agentos; not eval-runner). Daily-driver bar: `docs/RELEASE_BAR.md`.
>
> When tactical work and this document disagree, **shipped-status claims in §1 and §17 win**. Amendments require a written justification logged under §17.

---

## 1. The one-paragraph product

**VibeCoder** is a native macOS coding agent that runs on your own hardware **against a bring-your-own local OpenAI-compatible model server**. **Working backends today:** LM Studio, oMLX, Ollama, **Unsloth Studio**, EXO, and custom `/v1` (all HTTP). **In-process Swift MLX** is an adapter **stub** (`mlx-swift` not wired — generation throws). **Bundled llama.cpp/GGUF** was a planned path and is **removed as a product** (no vendored binary; no `LiteLocalBackend`; legacy settings migrate to Ollama). The agent iterates plan → tool calls → verify → repeat, edits via SEARCH/REPLACE and unified diffs, isolates work in git worktrees (`<project>-agentcore-<id>` / `agentcore/<id>`) **by default when a git project is bound** (escape hatch: edit main tree; merge/discard are user-driven), and can verify mutations with builds. It also exposes an OpenAI-compatible HTTP server on loopback for Xcode Intelligence — **default is a backend proxy** (`tools: []`); **opt-in** Settings toggle runs a **bounded multi-step AgentLoop** (cap 8) against the **bound project** (no worktree/review/MCP parity with in-app chat). **LAN/phone remote control (`RemoteControlServer`) is OFF** — not password-gated, not a shipping feature. MIT-licensed. No product license key or trial. No subscription. No Sparkle. No Sentry. Model weights leave the Mac only if **you** point at a remote endpoint. Apple Silicon.

## 2. Target user (precise)

**(Historical persona — not current pricing.)** The original NEW DAY draft pictured a buyer at $430. **There is no $430 product, trial, or paid SKU.** The user we still design for:

- Owns an Apple Silicon Mac with **≥32 GB unified memory** (the 7B floor) and aspires to 64–128 GB (the 32B/70B target).
- Writes **Swift or Apple-platform code primarily**, with secondary work in TypeScript, Python, Rust, or Go.
- Already runs **LM Studio, Ollama, or EXO** on their own machine. Knows what GGUF, Q4_K_M, and `-ngl 99` mean without looking them up.
- **Privacy non-negotiable.** Either professional (legal, medical, defence-adjacent) or temperamental.
- Already pays for **Cursor or Claude Code** today and is fatigued by subscription pricing + cloud dependency.
- Wants the agent loop, not just chat. Has hit the wall on raw LM Studio for real coding work.
- Solo or 1–5 person team. Not enterprise.

VibeCoder is **explicitly not for**: web developers who only touch HTML/CSS/JS, beginners learning to code, anyone whose codebase doesn't need privacy, hobbyists with <32 GB RAM (LM Studio is free, that's the floor for them).

## 3. Positioning

**Current answers use VibeCoder (MIT, BYO HTTP).** Rows that still say “NEW DAY” are the 2026-06 draft voice.

| If they say... | We answer... |
|---|---|
| "Why not Cursor?" | Subscription, cloud, your code goes to a third party. VibeCoder runs on your Mac against a local model server you run. Binding a git project isolates edits in a sibling worktree by default. |
| "Why not Claude Code?" | Same — cloud and subscription. Plus VibeCoder is native macOS, not Node/CLI-first. |
| "Why not LM Studio?" | LM Studio is chat. VibeCoder is the *agent on top of* LM Studio (and we can use it as a backend). |
| "Why not Ollama + Cursor with a self-hosted endpoint?" | That stack doesn't have a real agent loop with tools, build verification, or worktree isolation. VibeCoder is that layer. |
| "Why not free / open-source?" | **It is.** MIT as of 2026-08-15. The closed-source / $430 pitch below this table is historical. |
| "Why one-time and not subscription?" | **Historical.** There is no paid SKU. The app is MIT; no license key. |

**No product license keys, trials, or activation gate.** MIT; distribution is GitHub Releases / DMG (no Sparkle feed). `$430` / Paddle / LemonSqueezy copy elsewhere in this file is historical.

## 4. Product surface (every screen, every modal)

### 4.1 First launch

**Target design (below) is not the current app path.** As of 2026-07-23 the app opens straight into the main UI (onboarding flag is force-completed; no in-app weight download). **2026-08-20 freeze:** there is **no** current onboarding wizard, **no** in-app weight download, **no** Sentry. **Practical first run:** install and start a local model server (LM Studio recommended), load a tool-capable model, then Settings → Connection → Test. See README “First-run: start a model server”.

**Aspirational wizard (not current product — do not market):**

1. **Welcome.** Local-first coding agent. Nothing leaves your Mac *when you use a local server*. Hardware detected inline. No crash-reporting SDK. Continue.
2. **Connect a server / pick a model.** Prefer detecting LM Studio / oMLX / Ollama / Unsloth Studio / EXO on loopback over promising in-app GGUF/MLX downloads. Optional curated cards remain valid as *catalog infrastructure*, not “we host the engine.”

Lands in a new conversation with Coder defaults once a backend answers `/v1/models`.

### 4.2 Main window

`NavigationSplitView`. Sidebar + detail; patch / approval / worktree review are **sheets**, not a third column. Visual rail: `UI_DESIGN.md` (orange + SF). Do not resurrect 2026-06 chrome (4-icon sidebar, Geist/Azure, license, onboarding, header Safe/model pills).

**Sidebar** (Claude-style, not a 4-list segmented bar):
- **Chat** — Recents / tasks. ⌘N new task.
- **Projects** — folder bindings.
- **Models** — active HTTP backend's list (not Library/Discover/GGUF download).
- **Notes**, **Scheduled**.
- **Cluster** — mounted only when the active backend is EXO (read-only `/state` + pin Model ID).

Footer: Delete all + **Settings**. Command palette is ⌘K (not a sidebar row).

**Chat surface** (`UI_DESIGN` §4 / chat header):
- Slim title + chevron: Rename, Duplicate, Export/Copy as Markdown, Isolate work in git worktree / Review worktree… / Edit main tree…, Delete.
- **Worktree** chip when isolated, or **Isolate in worktree** when a git folder is bound. Merge/Discard/Continue live on the review sheet. LAN/phone remote control is **off** — not in the title menu.
- No header model / project / Safe pills. Model picker lives on the composer.
- Transcript + composer share content width. Plan is a floating card, not an in-transcript PlanCard.

**Composer:** multi-line field; Return sends; Shift-Return newline; ⌘. stops. Empty-chat copy names LM Studio / Ollama / oMLX / Unsloth / EXO — not "Ask the agent…".

### 4.3 Settings sheet (grouped tabs)

Modal sheet on `RootView` (⌘,, sidebar Settings, palette, `/settings`). **Not** a `Settings` scene. Default tab: **Agent**. Search field in the header.

**Do not restyle this back to the 2026-06 five-tab set** (General / Connection / Models load-sliders / Privacy & License / About). Shipped `SettingsTab` is grouped:

| Group | Tabs |
|---|---|
| Agent | Agent, Skills, Subagents, Commands, Hooks |
| Models & network | Connection, Model & Backend, MCP Servers |
| Workspace | Tools, Context, Memory |
| System | Appearance, Privacy, Advanced, About |

Connection hosts BYO HTTP (LM Studio / oMLX / Ollama / Unsloth Studio / EXO / custom `/v1`) plus Local API (proxy default; opt-in bounded AgentLoop). Model & Backend is providers/sampling — **no** GGUF load sliders, **no** GPU offload, **no** in-app weight download. Privacy is export/import/clear (**no license**). About is version/credits (**no Sparkle**). Hooks: project `.vibecoder/hooks.json` + user `~/.vibecoder/hooks.json`.

#### 4.3.1 Model & Backend (not a llama load panel)

The 2026-06 ASCII "LOAD SETTINGS / GPU offload / KV cache" panel is **retired**. BYO HTTP lists what the server exposes. Per-model files, if present, live under `~/Library/Application Support/VibeCoder/` — not `AgentOS-NewDay`. Reload-banner / `--cache-type-k` copy is historical llama.cpp product and must not return.

### 4.4 Modals & sheets

- **Patch review sheet.** Side-by-side syntax-highlighted diff (Tree-sitter). Per-hunk Accept/Reject. "Apply all" / "Reject all" shortcuts. Triggered for every `apply_patch` in Safe Mode; opt-in elsewhere.
- **Worktree review sheet.** Live worktree status + file-by-file diff vs main. Merge / Discard / Continue working buttons.
- **No product license / trial UI.** The app does not require a license key.
- **Updates.** Manual DMG / GitHub Releases (Sparkle removed).
- **Onboarding wizard.** §4.1.
- **Project bind dialog.** Native NSOpenPanel for folder selection.

### 4.5 Keyboard shortcuts

Match `UI_DESIGN.md`. ⌘K is the **command palette**, not bind-project.

| Shortcut | Action |
|---|---|
| ⌘N | New task / conversation |
| ⌘, | Settings |
| ⌘K | Command palette |
| ⌘. | Stop generation |
| ⏎ | Send |
| ⇧⏎ | Newline |
| ⇧Tab | Cycle permission / execution mode |
| Esc | Dismiss sheet / stop generation |
| ↑ / ↓ | Prompt history (composer) |

Project bind is the folder picker / Projects pane — not ⌘K. Palette items include Open Settings, Projects, Models, New Conversation, Stop agent (`UI_DESIGN` §4.8).

## 5. System architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  Surfaces                                        │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────┐ │
│  │ VibeCoder.app│    │ vibecoder    │    │ LocalAPIServer     │ │
│  │ (SwiftUI) ✓  │    │ REPL (C1)    │    │ (proxy default;    │ │
│  │              │    │              │    │  AgentLoop opt-in) │ │
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
│       ├─ UnslothStudioBackend (HTTP + load/unload)             ✓ │
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
| **Unsloth Studio** | ✓ HTTP | function calling | SSE | Studio folder + cache; load/unload | via Studio | Default `:8888/v1`; bearer or local agent key |
| **EXO** | ✓ HTTP | function calling | SSE | pin Model ID in Settings | n/a | `/state` topology; avoid full catalog flood |
| **Custom** | ✓ HTTP | function calling | SSE | `/v1/models` | n/a | Any OpenAI-compat base URL |
| **MLX (in-process)** | ❌ stub | Route B target | throws | HF cache helpers only | `MLXHubDownloader` real; UI not product path | `Package.swift`: mlx-swift not wired |
| **llama.cpp (bundled)** | ❌ removed | — | — | — | — | No LiteLocalBackend; no vendored binary |

All **HTTP** adapters implement the same `InferenceBackend` protocol; the agent loop never branches on backend type for streaming.

### 5.4 Tool surface (v1)

**Honesty rule:** names below match `ToolRegistry.registerBuiltins()` as of 2026-08-20. Do not invent aliases (`build_xcode`, `git_log`, …) for marketing — check the registry.

**Filesystem (core)**
- `read_file`, `write_file`, `edit_file` (SEARCH/REPLACE primary), `apply_patch`
- `delete_file`, `move_file`, `create_directory`, `list_directory`, `glob_files`, `grep_code`

**Shell (core)**
- `run_shell` — synchronous, bounded output; optional **seatbelt** (`sandbox-exec`) for child processes when Settings enable it — **not** macOS App Sandbox for the app binary

**Git (core)**
- `git_status`, `git_diff`, **`git_commit`**, **`create_pull_request`** (no registered `git_log` / `git_show` / `git_blame`)

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
- **Default (2026-08-20):** binding a **git** project creates/reuses that worktree. Not a repo → bind still works, no worktree. Escape hatch: edit main tree. Merge/discard remain user actions. Contract: §11.2 and `docs/RELEASE_BAR.md`.
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
- Grok-class process-watch **monitor product** — registered `list_background_jobs` / `monitor_jobs` list **in-app** jobs only (`JobMonitor`); not arbitrary stdout watch
- macOS **App Sandbox** entitlements redesign (current app entitlements are empty; seatbelt ≠ App Sandbox)
- First-run Connection wizard (app currently skips onboarding)

MCP client, sub-agents (`task`), plan tools, checkpoints, and skills index are present beyond older “deferred” lists.

### 5.4.1 Model catalog (infrastructure, not recommendations)

Curated catalog data in-tree (e.g. MLX/GGUF seed entries, hardware-fit helpers) is **infrastructure**, not a promise that the app downloads and runs those weights itself.

1. **BYO server remains the v1 download path** — models are loaded in LM Studio / oMLX / Ollama / Unsloth Studio / EXO; the app lists what the server exposes.
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
`agentToolsEnabled` default-off. **LocalAPI** (`LocalAPIServer`) is the
in-app path whose Settings toggle maps `true → .agentLoop` (execute +
re-prompt, cap 8). Headless serve is **not** the same: it may still attach
schemas or proxy depending on `configure` — check the server you started.
Do **not** document serve as “schemas-only Local API”; that was PB7 and is
**wrong** for the Settings opt-in (D1).

Usage: Xcode 16 → Settings → Intelligence → Add provider → `http://localhost:11435/v1`. With the agent-loop toggle **off** (default), completions are a plain proxy. With it **on**, the request runs a **bounded AgentLoop** against the bound project: tools **execute** server-side (PathConfinement to that root; no worktree, no patch-review sheet, no shell-approval coordinator — shell/MCP `.ask` hard-deny). Still **not** “Xcode is Cursor.” The full in-app chat remains the primary agent surface (worktrees, review UI, MCP).

**The local server is started from the app (Settings → Local API → Start).** Headless automation can construct `AgentOSServeServer` / `LocalAPIServer` with an explicit backend.

### 5.8 CLI surface

Interactive **`vibecoder`** REPL is **C1** (`Sources/VibeCoderCLI` + `VibeCoderCLILib`). Same `AgentCore` / BYO HTTP backends / `ConversationStore` as the app; TTY y/n/always approvals (empty/`n`/unknown deny); worktree bind on git projects. **Not** `agentos`. **Not** `eval-runner` (`Evals/` stays separate). Native app remains the primary surface.

**C2:** EventPrinter colors TTY roles; `NO_COLOR` or non-TTY = C1 plain text (no escapes). **C3:** SIGINT during a turn cancels `AgentLoop` via `TurnCancelHandle` (no `AgentLoop.swift` growth); idle Ctrl+C still exits. TTY `always` is durable; patch `always` → directory grant.

Do not document `agentos run` / `agentos serve` as shipping. The historical `agentos` CLI remains removed.

## 6. Data architecture

### 6.1 Persistence layout

Canonical root is **`~/Library/Application Support/VibeCoder/`** (`AppSupport.folderName`). Conversations are atomic JSON at `conversations/<uuid>.json`. Legacy `AgentOS-NewDay` / `AgentOS` trees migrate one-shot into `VibeCoder`.

```
~/Library/Application Support/VibeCoder/
├── conversations/<uuid>.json               # one file per conversation, atomic write
├── projects/                               # per-project bindings
├── notes/
├── scheduledTasks/ + scheduledTaskArchive.json
├── traces/<conversation-id>.jsonl          # agent trace, opt-in (Settings → Appearance)
└── …                                       # other AppSupport children

~/Library/Logs/VibeCoder/                   # standard macOS logs (not in App Support)
```

Do not document `~/Library/Application Support/AgentOS-NewDay/` as the live path. HuggingFace hub / GGUF cache is **not** a v1 product path (bundled llama.cpp removed; MLX is a stub).

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
- **Crash-free rate >99.5%** — **no Sentry**; this bar is process/quality, not a shipping telemetry SDK.
- **Notarized, hardened runtime, signed with Developer ID.**
- **HTTP backends end-to-end-validated** with at least one real model each (LM Studio / oMLX / Ollama / Unsloth / EXO / custom as applicable).
- **LocalAPIServer validated against Xcode Intelligence + curl + Postman.**
- **First-launch:** no wizard. Empty chat + Settings → Connection is the path (not a 60-second onboarding SLA).
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
  ├─ create-dmg → VibeCoder-<version>.dmg
  ├─ codesign DMG + notarize DMG + staple DMG
  └─ publish DMG (e.g. GitHub Releases) — **no Sparkle appcast**
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

**Removed.** Sparkle is not in the shipping package. `Release/appcast.xml` is a **tombstone** (historical AgentOS feed; not consumed by VibeCoder). Users install new DMGs manually. Do not invent a replacement updater in this rail.

### 9.4 Telemetry

**Removed.** No Sentry SDK. Settings `crashReportingEnabled` is unused schema compatibility. Do not claim opt-in crash reporting as current.

### 9.5 Distribution sites

- GitHub Releases (or any host) for signed DMGs — **current**
- `agentos.tools` / Paddle / LemonSqueezy / Sparkle appcast — **historical, not current**

## 10. Integration architecture

### 10.1 Xcode Intelligence (loopback completions proxy)

`http://localhost:11435/v1` set as a custom provider in Xcode 16 → Settings → Intelligence. By **default**, Xcode's completions **proxy to the active backend** with **`tools: []`**. Optionally enable **Agent loop on Local API** in Settings for a **bounded** multi-step tool loop (capped iterations; still not full worktree/UI parity with in-app chat).

**Why it matters:** one local OpenAI-compatible base URL. Default path is safe for Xcode. Opt-in path is for clients that want server-side tool execute without using the SwiftUI app. See §5.7.

**Honesty (2026-08-20, supersedes PB7 “schemas-only”):** do not market this as “Cursor-level agentic Xcode.” Default remains proxy `tools: []`. Opt-in `agentToolsEnabled` runs a **bounded AgentLoop** (execute + re-prompt, cap 8) on the bound project — **not** schemas-only (that mapping is leftover `ServeToolsPolicy.schemasOnly`, unused by the Settings flag). It is still **not** a full agent gateway: no worktree, no review UI, no MCP/Xcode-bridge by default. See §5.7.

### 10.2 MCP (Model Context Protocol) — shipped client

Anthropic's MCP is the plugin protocol for AI coding agents. NEW DAY ships an **MCP client** (stdio + HTTP/SSE, Settings → MCP) so users can plug in third-party MCP servers. Tools appear as `server__tool` in the agent registry when servers are enabled.

Exporting NEW DAY's own tools as an **MCP server** for other hosts remains a future option, not a v1 claim.

### 10.3 Skill marketplace — **not v1**

There is **no** v1 skill marketplace, **no** `agentos.tools/skills`, **no** `.agentos-skill` storefront or ratings. Shipped: `SkillDiscovery` + `load_skill` + Settings → Skills. Export-bundle / community listing is post-v1 (non-goal §13.8). Do not market 182 packages.

### 10.4 Remote control — **OFF (not shipping)**

`RemoteControlServer` / LAN / phone QR is **shut down as a product**. It is **not** password-gated and is **not** a shipping feature. Do not document QR remote, Tailscale probe, or “mobile parity” as current. Code may still exist in-tree while Lin/Pixel disable the surface; treat any remaining UI as dead until a later §17 row says otherwise.

### 10.5 Other (post-v1)

- **Linear / GitHub / Jira tool integrations** as bundled MCP servers
- **Voice transcription input** (whisper.cpp via subprocess) — possibly v2
- **Plugin SDK** for native Swift extensions — v2

## 11. Cross-cutting concerns

### 11.1 Diagnostics

All failure paths route through `DiagnosticsHub`. UI surfaces severe events in a "Recent issues" panel. CLI prints to stderr. Optional log file at `~/Library/Logs/VibeCoder/diagnostics.log`.

### 11.2 Worktree safety (default on bind-git)

**Product contract (2026-08-20).** Full bind-site list and Lin notes: `docs/RELEASE_BAR.md`.

A real `git worktree` at `<project>-agentcore-<id>` on branch `agentcore/<id>` (`WorktreeService.createOrReuseWorktree`). When `conversation.worktreeBranch` is set, mutating tools use `worktreeRootURL` (not the main checkout). Review sheet shows diff vs main. Merge/discard dispose the branch + worktree.

| Situation | Behavior |
|-----------|----------|
| Bind / new chat in a **git** project | Create or reuse the sibling worktree. Isolation **on**. |
| Bind a **non-git** folder | Bind succeeds. No worktree. Surface `notAGitRepo`. Edits go to `projectRoot`. |
| Main tree is **dirty** | Do **not** block. Worktree is a clean checkout of **HEAD**. Uncommitted main files stay in main. |
| Path exists but is not this project’s worktree | Fail closed (today’s error). Do not delete foreign dirs. |
| Escape hatch **Edit main tree** | `worktreeBranch = nil` for that conversation. Do not recreate on `send`. |
| **Merge / discard** | User-driven only (`WorktreeCoordinator`). Never auto-merge on turn end, quit, or bind. |
| Local API agent-loop | **Unchanged:** bound project + PathConfinement; **no** worktree. |
| Existing chats with `projectRoot` and nil branch | Do **not** migrate on load. Default applies on the next **bind** (or explicit enable). |

`git_commit` / `create_pull_request` must use the worktree cwd when isolation is on (Lin gate). Do not implement this policy inside `AgentLoop`.

### 11.3 Safe Mode + shell seatbelt (not App Sandbox)

**Safe Mode** (when configured): path / shell allow-lists consulted during tool authorization (`ToolAuthorization` / Safe Mode config) before mutating or executing tools. Product UI: shield / settings — defaults and exact chip wiring may vary; do not invent keybindings in marketing.

**Shell seatbelt (PB8 / PC2):** optional `sandbox-exec` profile around **`run_shell` child processes** (`SafeBash`) when Settings set seatbelt preference (default: Auto/edit mode only). Apple marks `sandbox-exec` **deprecated**; this is a **write fence for shell children**, not a substitute for shipping under the macOS **App Sandbox** entitlement.

**App Sandbox honesty (P7):** `App/VibeCoder.entitlements` is currently an **empty** entitlement set — the app is **not** sandboxed as an App Store-style container. LocalAPIServer loopback + free filesystem access assume direct distribution. Do not claim “App Sandbox hardened” for the product binary. Seatbelt ≠ App Sandbox.

### 11.4 Headless mode

App “Headless” / unattended posture (notifications, conservative system prompt). The historical **`agentos` CLI remains removed** — do not document `agentos run --headless`. Interactive `vibecoder` REPL is C1 and is **not** that headless path. Headless eval/script paths live under `Evals/` (`eval-runner`) when present. Pairs with Safe Mode for unattended work.

### 11.5 Job monitor (not Grok monitor product)

`JobMonitor` / scheduler status snapshots list **background jobs** already tracked by `BackgroundJobManager` / scheduled tasks. Registered tools `list_background_jobs` and `monitor_jobs` are **in-app job listing only**. No continuous stdout watch product; no Grok Build monitor parity. See polish P9 for UI copy.

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
| Network unavailable | **Local tools + local model server on loopback still work.** Public-net tools (`web_search`, `fetch_url`, …) fail. App does not need cloud for the agent loop. (No Sparkle; no product license phone-home.) |

## 13. The 10 explicit non-goals

These are decisions, not omissions:

1. **No cloud sync of conversations.** Strikes against "100% local."
2. **No team / multiplayer features in v1.** Solo dev focus. v2 might revisit.
3. **No cross-platform.** macOS Apple Silicon only. Linux/Windows is not on the roadmap.
4. **No model training.** Inference only. No fine-tuning UI.
5. **No voice / audio in v1.** Whisper/TTS deferred to v2.
6. **No translation / localization.** English-only at launch. Adding later is cheap if there's demand.
7. **No paid SKU / trial / license key.** **(Amended 2026-08-20: MIT; the old “no free tier / $430” pitch is obsolete.)**
8. **No skill marketplace in v1.** **(Amended 2026-08-15: core is public MIT; the non-goal is the *marketplace*, not openness.)**
9. **Not a replacement for Xcode.** We integrate via Intelligence; we don't rebuild the IDE.
10. **Not a generic macOS assistant.** Coding-focused. No "what's the weather" surface.

## 14. Roadmap from v1.0 to v2.0

| Version | Theme | Major adds |
|---|---|---|
| **v1.0** | Foundation | Live backends: **LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom HTTP**. In-process MLX = stub; bundled GGUF/llama = **removed**. Worktree (`agentcore/`, **default on bind-git**), scheduled runs, per-project instructions, LocalAPIServer **proxy default / bounded AgentLoop opt-in**. Tool/memory surface: see `ToolRegistry` + §5.4/§5.6. |
| **v1.1** | Polish + MCP | MCP client + server, per-hunk patch review polish, WorktreeReviewSheet → real `git diff`, Settings cascade UI refinement, performance tuning |
| **v1.2** | Skills marketplace | User skill creation UI, export bundle, marketplace listing at agentos.tools/skills, rating + install |
| **v1.3** | Catalog expansion | Auto-update catalog with monthly model curation, hardware-tier suggestions, draft-model speculative decoding for all GGUF models |
| **v1.4** | LSP polish | **Partial today:** optional SourceKit-LSP via `find_symbol` + text-index fallback. Still open: persistent host, multi-language registry, didChange after edits |
| **v1.5** | Sub-agent + planner depth | Better planner outputs, sub-agent inheritance refinement, parallel investigation patterns |
| **v2.0** | Cross-chat intelligence + collaboration | **MemoryTool + MEMORY.md / DECISIONS.md** auto-inject with embedding-based skill auto-attach (cheap context patterns suited to small models — see V2 ARCHITECTURE), Route B MLX, shared MEMORY.md sync, team license, collaboration session, shared skill libraries |

## 15. Pricing & business model

- **No product license key.** App is not gated by trial or activation.
- **No subscription.**
- **MIT open source.** `$430` / refund-policy / merchant-of-record copy is **historical**.

Distribution: signed DMG (GitHub Releases or any host). Apple App Store **not** used (sandbox would forbid LocalAPI + agent tools as shipped). Direct `agentos.tools` storefront is **not** current.

## 16. Brand & voice

- Name: **VibeCoder** (shipping). **AgentOS NEW DAY** is a historical/internal draft name — **not** current product.
- Tagline: **BYO local OpenAI-compatible server.** Weights leave the Mac only if **you** point at a remote endpoint. Do not say "nothing leaves your Mac."
- Voice: precise, technical, dry. No hype. Talk to developers like developers.
- Visual: SF + orange accent (`UI_DESIGN.md`). Geist / Azure are retired. No animation for animation's sake.
- The product personality is "the senior engineer who sits next to you" — not "AI assistant."

## 17. Amendments log

When this doc is amended, log the change here with date + reason. The doc itself is the rail; amendments are how the rail bends.

| Date | Section | Change | Reason |
|---|---|---|---|
| 2026-08-21 | §10.3, §16, DESIGN.md | **Rail honesty:** tagline is not "nothing leaves your Mac"; skill marketplace is not v1; DESIGN LocalAPI is NWListener / VibeCoder logs — not Swift NIO, AgentOS-NewDay, or `/v1/embeddings`. | Match §1/§17; Lead Chief leftover rail 2026-08-21 |
| 2026-08-21 | §4.2, §4.3, §4.5, §6.1, README | **Chrome honesty:** Settings is the shipped grouped tabs (not 2026-06 five-tab). ⌘K is command palette. Persist path `~/Library/Application Support/VibeCoder/conversations/`. Sidebar Chat/Projects/Models/Notes/Scheduled (+ Cluster on EXO). Do not restyle Settings back to 5 tabs. | Match `UI_DESIGN.md` §4.3 / §4.8; Lead Chief 2026-08-21 |
| 2026-08-21 | §5.8 | **C3 CLI honesty:** SIGINT mid-turn cancels via `TurnCancelHandle` (no `AgentLoop.swift` growth); idle Ctrl+C exits. TTY y/n/always (empty/`n`/unknown deny); patch `always` → directory grant. | Turnip verified `VibeCoderCLILib` 24/24 |
| 2026-08-21 | §5.8 | **C2 CLI honesty:** EventPrinter colors TTY roles; `NO_COLOR` or non-TTY = C1 plain text (no escapes). C3 cancel-in-turn + always grants still not shipped. | Turnip verified `EventPrinterTests` 5/5 |
| 2026-08-21 | §5 diagram, §5.8, §11.4, claim-freeze header | **C1 CLI honesty:** interactive `vibecoder` REPL ships as C1 (BYO HTTP, same AgentCore, shared ConversationStore). Not `agentos`. Not eval-runner. C2 color / C3 cancel-in-turn + always grants not shipped. | Code already had `vibecoder`; rail still said CLI removed |
| 2026-08-20 | §1, §3, §5.4, §11.2, `docs/RELEASE_BAR.md` | **Worktree default:** bind-git enables isolation; escape hatch edit-main-tree; merge user-driven; dirty HEAD allowed; non-git binds without a worktree. Daily-driver bar checked in. (Not §5.6 — that section is Memory.) | Max standing order: daily-driver isolation, not opt-in-only |
| 2026-08-20 | §1, §2, §4.1, §4.3, §5 diagram, §5.3, §5.4, §5.7, §8–§10.4, §12–§16 | **Claim freeze:** current product is **VibeCoder** MIT BYO HTTP (LM Studio / oMLX / Ollama / **Unsloth** / EXO / custom). No Sparkle, Sentry, bundled llama, in-process MLX, $430 SKU, wizard, or CLI. Local API **default = proxy `tools: []`**; opt-in = **bounded AgentLoop** on bound project (supersedes PB7 “schemas-only” in §10.1). `git_commit` + `create_pull_request` registered. **Remote control OFF.** `Release/appcast.xml` tombstoned. BYO is the v1 inference decision. | Max-approved product claim 2026-08-20; GROK_PORT/§10.1 contradicted `ServeToolsPolicy` |
| 2026-08-18 | §17 + companion scorecards | **Docs flip:** MCP GET `/sse` (not HTTP alias); default-IGNORE project hooks (user-scope still runs); commands editor + `$ARGUMENTS`; sidebar archive list + Find Files scope; mid-run `metadata.json`; terminal CSI 33/33 incl. Grok Build smoke; XCTest parent-child suite. Still unchecked: `node_repl`, mermaid, `mlx-swift`, queue Edit. | Product-architect honesty pass after those landings |
| 2026-08-18 | §17 + companion scorecards | **Hooks events wired:** `PermissionRequest` + `PostToolUseFailure` + MCP `preToolDetailed`. Scorecards flipped. | Docs-only; Build verified 53/53 + 84/84 |
| 2026-08-18 | §17 + companion scorecards | **Wave 4 `memory_update`:** `MemoryUpdateReminder` extras + `AgentLoop` `pendingNudges` hook landed. Scorecards flipped. Still unchecked: typed memory kinds, ignore-project-hooks, SSE GET, node REPL, `mlx-swift`, commands editor, mermaid. | Wave 4 docs pass — do not list mid-turn memory refresh as open |
| 2026-08-18 | §17 + companion scorecards | **Inspector token cards:** Subagents pane Duration / Tokens / Tools after finish (`subagent_meta` + `metadata.json`). `cache_*` still 0 and hidden. Live running children duration-only until finish. Do not claim mid-run tokens or cache hits. | Tiny docs follow-up after Inspector landed the cards |
| 2026-08-18 | §17 + companion scorecards | **Wave 2 honesty (docs only):** reminder cadence + PlanStore suppress; in-session `SkillToolGate` (not durable); `sessionReadPaths` persist + AgentLoop seed + Set-Codable SIGSEGV codec; terminal CSI subset freeze; subagent usage + JSONL artifacts. Scorecards in `docs/PARITY_WITH_ZCODE.md` / `docs/UI_PARITY_WITH_ZCODE.md` and DESIGN.md status box flipped to match code. Unchanged here: project hooks still execute; mid-stream RO tools still missing; SkillToolGate still fail-open on relaunch. | Wave 2 landed in AgentCore/App; rail must not still list those as open P0/P1 |
| 2026-08-15 | §1, §2, §3, §13, §16 | **Open-source honesty:** public snapshot ships MIT as **VibeCoder**; "Closed-source" §1 claim, §3 closed-source positioning row, §13 closed-core wording, §16 name marked amended. §2's "$430 buyer" framing is historical pricing copy, not product truth. | Commit 9a2182b (public snapshot) added MIT LICENSE/README but body text still said closed-source — the doc-as-rail contract requires the amendment |
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

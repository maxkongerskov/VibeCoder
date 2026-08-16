# VibeCoder · Design & Critique

> Successor to the original AgentOS DEV PLAN. Native macOS Apple Silicon. **Open source (MIT).**
> SwiftUI app (CLI removed) sharing one Swift core library.
>
> **Shipped backends (2026-07-23):** OpenAI-compatible **HTTP only** — LM Studio, oMLX, Ollama, EXO, custom endpoint.  
> **Not shipped:** in-process MLX (stub; `mlx-swift` not wired), bundled llama.cpp/GGUF runner (product **removed**; legacy settings migrate to Ollama). There is no `LiteLocalBackend`.  
> **Honest offline:** agent + tools run on-device **when a local model server is already running**. Zero-deps “fresh Mac, no third-party server” inference is **not** a product path today.  
> Sections below still record the original target architecture; treat §9 competitor table and performance levers as **amended by the status box above** unless marked otherwise.

---

## 1. What the original AgentOS got right

Carry these forward without rebuilding from scratch:

- **Unified `InferenceBackend` protocol.** One stream surface for every model host — keep it; all shipped adapters are HTTP OpenAI-compat (in-process MLX remains a future Route B).
- **`ChatLoop` pure helpers split from `ChatViewModel`.** Stall detection, history compaction, nudge prefixing — all testable without UI. Keep this split; in NEW DAY it lives one layer lower (in the shared core library, not in the app target).
- **Worktree isolation.** `git worktree`-based safe edits is genuinely differentiating vs. Cursor; cloud agents can't do this cleanly.
- **`LocalAPIServer` exposing AgentOS as OpenAI-compatible.** Still a moat *when* agent tools are enabled. **Today:** loopback proxy for completions (`tools: []`); full agent-loop routing is deferred. Harden before claiming the agent gateway.
- **Skill markdown + auto-attach.** 182 procedure files in the bundle is a real asset. Keep the format; replace the loader with a smaller, lazier indexer.
- **MEMORY.md / DECISIONS.md auto-injection.** Cross-session learning that's a flat file (greppable, diffable) is correct. Keep.
- **Hardware-aware presets.** `HardwareInfo` + `ModelPreset.recommended(forParamsB:)` is the right defaults strategy. Keep.
- **Per-model JSON persistence at `~/Library/Application Support/AgentOS/model-settings/<modelId>.json`.** Correct shape. Keep verbatim (compatible migration from original).

## 2. What was wrong, and what NEW DAY does instead

| # | Original problem | NEW DAY fix |
|---|---|---|
| 1 | **6-file tool registration.** Adding a tool touches `ToolDefinition`, `ToolExecutor` switch, `EnabledTools` struct, `ToolPermissions`, `ToolCategory`, `ToolsSettingsView`. Missing one = silent runtime failure. | **Single `Tool` protocol, one file per tool.** Each conforming type declares its name, JSON schema, permission class, and `execute()` body. Registration is a single `register(MyTool.self)` call; the registry is the only switch statement and it's dynamic. `EnabledTools` becomes `[String: Bool]` keyed by name. Adding a tool = one new file. |
| 2 | **EXO is a fake backend** — `LMStudioService` pointed at port 52415. No topology awareness, no cluster health, no shard map. | **Real EXO adapter.** `EXOBackend` queries `/state` for nodes + shard layout, surfaces a Cluster panel in Settings, falls back to OpenAI-compat `/v1/chat/completions` for inference but with topology-aware error messages ("node `mac-studio-2` dropped during streaming"). The user sees their cluster. |
| 3 | **Full-file rewrites on every edit.** No `apply_patch` primitive — agent reads the entire file, regenerates it, writes it back. On 2,000-line Swift files this is a token-volume disaster. | **`apply_patch` is the primary edit tool**, unified-diff format. `write_file` becomes the fallback for new files only. `edit_file_range` (line-range replace) is the second-tier option. Agent system prompt teaches: patch > range-edit > full-rewrite. |
| 4 | **No structural verification after edits.** `verifyEditsNudge` injects a prompt; the model *might* choose to build. Often doesn't. | **`BuildGuard` runs the build automatically** after any tool call that mutates project files. Detects project type (Swift Package, Xcode, Cargo, npm, plain). Failed builds short-circuit the loop with the compiler error injected back as a tool result. Configurable per project; off for non-buildable dirs. |
| 5 | **Context compaction is elision-only.** `compactHistory` truncates old tool outputs. Past 30 turns the elision markers themselves bloat. No semantic summary. | **Tiered compaction.** Recent 10 turns verbatim. Turns 11–30 summarized by a small auxiliary model (`Qwen2.5-3B` or whichever smallest GGUF is loaded). Turns 31+ collapsed to bullet "what happened" + "what was decided". Auxiliary summarization happens off the critical path between turns. |
| 6 | **Split-file GGUF unsupported** — cuts Llama 4 Scout, Qwen3-Coder 480B, MiniMax M2.7, GLM 4.5 variants. | **Native multi-part GGUF.** llama.cpp handles split files when given the first part; just pass `-m <model>-00001-of-00007.gguf` and let it auto-discover siblings. The catalog stores the *base* path; the downloader fetches all parts; the spawn arg uses the first. |
| 7 | **MLX multi-turn tool history is flattened** — `tool_calls` re-encoded as `role+content` text because `Chat.Message` had no structured tool field. Anti-echo regex is a band-aid. | **Route B from the original docs.** `MLXBackend` uses `ChatSession`'s native tool message support (mlx-swift-lm ≥3.x has structured tool roles). No flattening, no anti-echo prompt rule. |
| 8 | **197 `try?` silent-failure sites.** Download failures invisible; license check failures indeterminate. | **Result types + a `Diagnostics` channel.** No `try?` in production code paths. Every failure routes through a single `Diagnostics.report(...)` actor that surfaces to a "Recent issues" panel and a notification when severe. `try?` is allowed only where the doc-comment explicitly justifies it. |
| 9 | **No native diff view.** Tool results render as expandable cards with raw text. Cursor's whole UX is the diff. | **`PatchReviewSheet`** — syntax-highlighted side-by-side diff, accept/reject per hunk, applies via `apply_patch` tool. Mandatory review in Safe Mode; opt-in elsewhere. |
| 10 | **No LSP / semantic search.** All code search is grep. | **SourceKit-LSP for Swift** (built-in to Xcode toolchain) + generic LSP for other languages via a `language-servers/` registry. Adds `find_definition`, `find_references`, `workspace_symbol`, `hover` tools. Falls back to grep when no LSP available. |
| 11 | **Sub-agents under-utilized.** `SubAgentRunner` exists but the system prompt doesn't guide toward it. No memory inheritance. | **First-class `dispatch_task` tool.** Sub-agents inherit MEMORY.md + skills + worktree (read-only by default). System prompt explicitly teaches: "for parallel investigations of >2 unrelated questions, dispatch sub-agents instead of serializing." Sub-agent results return as a single tool result message. |
| 12 | **Inbound `LocalAPIServer` uses raw `NWListener`**, writes logs to `~/Desktop/`. | **`LocalAPIServer` built on Swift NIO** (production-grade), logs to `~/Library/Logs/AgentOS-NewDay/`, supports streaming SSE, handles `/v1/models`, `/v1/chat/completions`, `/v1/embeddings` (NEW — proxied to whichever backend supports embeddings). *(Not shipped as written: the package has zero dependencies — `LocalAPIServer` stays on Network.framework `NWListener`, loopback-only.)* |
| 13 | **No CLI.** Power users have to live inside the app. | **`agentos` CLI binary**, same agent core. `agentos run "fix the linker error"`, `agentos models list`, `agentos serve` (run the LocalAPIServer headless). Great for CI, SSH sessions, scripts. |

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       Surfaces                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  AgentOS.app     │  │  agentos CLI     │  │  HTTP server │  │
│  │  (SwiftUI)       │  │  (executable)    │  │  (Xcode etc) │  │
│  └────────┬─────────┘  └────────┬─────────┘  └──────┬───────┘  │
└───────────┼──────────────────────┼─────────────────────┼─────────┘
            │                      │                     │
            ▼                      ▼                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                   AgentCore  (Swift library)                     │
│                                                                  │
│   AgentLoop ──▶ Planner ──▶ Compactor ──▶ Verifier              │
│       │                                                          │
│       ▼                                                          │
│   ToolRegistry  (single protocol, dynamic dispatch)              │
│       │                                                          │
│       ▼                                                          │
│   InferenceBackend protocol                                      │
│       │                                                          │
│       ├─▶ LMStudioBackend       (HTTP)              ✓ shipped    │
│       ├─▶ EXOBackend            (HTTP + /state)     ✓ shipped    │
│       ├─▶ OMLXBackend / Ollama  (HTTP)              ✓ shipped    │
│       ├─▶ OpenAICompatibleBackend (custom /v1)      ✓ shipped    │
│       ├─▶ LlamaCppService       (REMOVED as product)             │
│       └─▶ MLXBackend            (stub; mlx-swift not wired)      │
│                                                                  │
│   ConversationStore · SkillStore · ModelCatalog · MemoryStore   │
│   PatchEngine · WorktreeService · LanguageServerHost · Diags    │
└─────────────────────────────────────────────────────────────────┘
```

**Surfaces today:** SwiftUI app links `AgentCore` (+ optional `MLXBackend` stub). Interactive `agentos` CLI was removed. `LocalAPIServer` is in `AgentCore` and can be started from the app — **v1 is a backend proxy** (`tools: []`), not a full agent-loop gateway for Xcode.

## 4. Module boundaries

```
Sources/
├── AgentCore/              Pure Swift, no UI, no @main.
│   ├── Agent/              AgentLoop, Planner, Compactor, Verifier
│   ├── Backends/           InferenceBackend + HTTP adapters (LM Studio, EXO, oMLX, Ollama, custom, xAI)
│   ├── Catalog/            Model catalog data; MLX curated list not product-surfaced in v1
│   ├── Conversation/       Conversation, Message, ToolCall, ToolResult
│   ├── Diagnostics/        Result types, Diagnostics actor, error reporting
│   ├── Memory/             MemoryStore (MEMORY.md/DECISIONS.md)
│   ├── Patch/              UnifiedDiff parser + applier + reverter
│   ├── Server/             LocalAPIServer (loopback OpenAI-compat proxy)
│   ├── Skills/             (evolving — see Wave B / GROK_PORT)
│   ├── Tools/              Tool protocol, ToolRegistry, concrete tools
│   ├── Worktree/           GitWorktree actor
│   └── Util/               HardwareInfo, TokenEstimator, etc.
│
├── MLXBackend/             Optional target; **stub** until mlx-swift is a Package dependency.
│
├── Harness/                Experimental rewrite (not linked by the app as daily driver).
│
└── App/                    SwiftUI macOS app + XcodeGen project.yml.
```

`AgentCore` is the only target with semantic versioning intent — internal API for the app + CLI to depend on. Everything else is a consumer.

## 5. Agent loop (NEW DAY)

```
loop:
  1. Build system prompt
       ├─ baseline rules
       ├─ active skills (auto-attached + manually pinned)
       ├─ MEMORY.md tail (capped per preset)
       ├─ DECISIONS.md tail
       ├─ working-directory notice
       └─ Safe Mode allow-list summary (if active)

  2. Compact history
       ├─ recent 10 turns verbatim
       ├─ turns 11-30 summarized (auxiliary model, off critical path)
       └─ 31+ collapsed to bullets

  3. Stream model call
       ├─ tool_search if enabled  (lazy tool schema reveal)
       ├─ active tool subset only
       └─ SSE → parse → emit deltas to UI

  4. If tool_calls present:
       ├─ dispatch in parallel where safe (read-only tools)
       ├─ serial for mutating tools
       ├─ inject results
       └─ goto 2

  5. If file-mutating tools were called in this turn:
       └─ BuildGuard.verify()
            ├─ swift build / xcodebuild / cargo / npm
            ├─ if fail: inject errors as system tool result, goto 2
            └─ if pass: continue

  6. If no tool_calls in response:
       ├─ stall guards (loop detection, ping-pong)
       ├─ persist conversation
       └─ end loop
```

The two structural additions vs. the original: (a) tiered compaction with auxiliary summarization, (b) automatic BuildGuard verification rather than a nudge.

> **Shipped reality (amended 2026-08-15):** compaction is a single-cut **full-replace** (`FullReplaceCompactor` — keep recent 6 turns verbatim, one extractive summary carrier message, elide fallback when still over budget; an optional `HistorySummarizing` hook exists for LLM summaries). The tiered 10 / 11–30 / 31+ scheme above remains the future target, not the shipped behavior.

## 6. Tool protocol

```swift
public protocol Tool: Sendable {
    static var name: String { get }
    static var category: ToolCategory { get }
    static var permission: ToolPermission { get }
    static var schema: ToolSchema { get }
    static var availability: ToolAvailability { get }   // .core, .deferred, .platformGated
    func execute(arguments: ToolArguments, context: ToolContext) async throws -> ToolResult
}
```

One file per tool. `ToolRegistry.register(MyTool.self)` is the only call site. `EnabledTools` becomes `[name: Bool]`. The 6-file checklist disappears.

`ToolAvailability.deferred` tools are excluded from the default system prompt and only revealed by `tool_search` — same lazy-tool concept as original, but enforced at registry level instead of by convention.

## 7. Backend protocol

```swift
public protocol InferenceBackend: Sendable {
    var identifier: BackendIdentifier { get }
    func listModels() async throws -> [ModelDescriptor]
    func warmUp(model: ModelDescriptor) async throws
    func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
    func cancel(streamID: UUID)
    func unload(model: ModelDescriptor) async throws
}
```

All four adapters implement this same surface. The agent loop has zero backend-specific code.

`ChatChunk` is a tagged enum: `.contentDelta(String)`, `.toolCallDelta(...)`, `.usage(...)`, `.done(reason:)`. The same enum is intended for all backends. **Today** the daily-driver path is HTTP SSE (LM Studio / oMLX / Ollama / EXO / custom). In-process MLX is not generating tokens yet.

## 8. Performance strategy (matching/beating LM Studio)

**Status:** target / aspirational. Shipped inference performance is whatever the **external** model server delivers (LM Studio, oMLX, Ollama, EXO, etc.); VibeCoder’s overhead is the agent loop + tool dispatch, not an in-process engine.

Historical levers (not all implemented):

1. **MLX in-process (P2, not shipped).** No subprocess, no HTTP serialization, no port hop via mlx-swift. Scaffold exists; generation throws until mlx-swift is wired in `Package.swift`.
2. **Bundled llama.cpp (removed as product).** Original plan: `-fa` + `-ngl 99` + cache quant defaults via a subprocess manager. **Product decision:** no vendored binary; users use Ollama / LM Studio / custom OpenAI-compat instead. Legacy settings key `"llamaCpp"` migrates to `.ollama`.
3. **Speculative decoding** when a draft model is loaded — remains a future option on servers that support it; not a first-class picker slot today.

Overhead budget for our wrapper:
- < 5 ms per turn for prompt assembly + tool registry lookup
- < 2 ms per token streamed for UI dispatch (already async)
- < 50 ms for context compaction (cached aggressively, only recompute on history extend)

## 9. Differentiation vs. competitors

**Honest matrix (shipped product as of 2026-07-23).** “Offline” here means: model weights and agent loop stay on the Mac **after** you bring your own local OpenAI-compatible server (LM Studio / oMLX / Ollama / EXO / custom). We do **not** ship a zero-deps embedded engine.

| Capability | Cursor | Claude Code | LM Studio | AgentOS NEW DAY (today) |
|---|---|---|---|---|
| Agent + tools offline (BYO local server) | ❌ cloud default | ❌ cloud default | ❌ chat only | ✅ if server already running |
| Zero-deps offline inference (no third-party server) | ❌ | ❌ | ✅ (own app) | ❌ not shipped |
| Native macOS app | partial | CLI-first | ✅ | ✅ |
| Apple-Silicon-native MLX **in our process** | ❌ | ❌ | ✅ (their engine) | ❌ stub only |
| GGUF via **bundled** llama.cpp | ❌ | ❌ | ✅ (their app) | ❌ product removed |
| Talk to LM Studio / Ollama / oMLX / EXO / custom HTTP | partial | custom | n/a | ✅ first-class |
| Distributed (EXO) | ❌ | ❌ | ❌ | ✅ HTTP + `/state` |
| Agent loop + tools | ✅ | ✅ | ❌ | ✅ |
| Git worktree isolation | ❌ | ❌ | n/a | ✅ |
| Diff-based edits | ✅ | ✅ | n/a | ✅ |
| Auto build verification | partial | ✅ | n/a | ✅ (when enabled) |
| Project memory (MEMORY.md) | partial | ✅ | n/a | partial / present |
| Skills marketplace | ❌ | ✅ | ❌ | not v1 product surface |
| OpenAI-compat server for Xcode | ❌ | ❌ | ✅ (no agent) | ✅ **proxy only** (`tools: []`; agent-loop opt-in deferred) |
| Interactive CLI | ❌ | ✅ | ❌ | ❌ removed |
| No product license gate | varies | subscription | free | ✅ |

**Anchors that still differentiate when used honestly:** (1) **local agent loop + worktree isolation** on top of a BYO local model server; (2) **loopback OpenAI-compat proxy for Xcode** (completions today; full agent tools not default).

## 10. Build & ship

- **Build:** `swift build` for core; `xcodegen generate && xcodebuild` for the app. (CLI removed)
- **Signing:** Developer ID Application; entitlements `cs.allow-jit`, `cs.disable-library-validation`, `network.client`, `network.server`, `files.user-selected.read-write`.
- **Notarization:** `notarytool` + `stapler`.
- **Distribution:** signed DMG via GitHub Releases (or any host). Sparkle was removed — no in-app auto-update.
- **License keys:** Removed — the app does not require a product license key or trial.
- **Telemetry:** Sentry opt-in, off by default. Strictly stack traces — no conversation content, no model data.

## 11. Phased delivery

Historical plan of record (many items landed under different names; **do not read unchecked cells as “still shipping as written”**):

| Phase | Original scope | Reality note (2026-07-23) |
|---|---|---|
| **P0** | Package, protocols, LM Studio, tools, CLI, app skeleton | Core + app exist; **CLI removed** |
| **P1** | EXO + llama.cpp subprocess + edit tools | **EXO HTTP shipped**; llama.cpp product **removed** (use Ollama/custom); edit tools present |
| **P2** | MLX in-process + catalog + BuildGuard | Catalog/downloader scaffolding exists; **inference still stub**; oMLX/Ollama HTTP added instead |
| **P3** | App shell, worktrees, LocalAPIServer | App + worktrees shipped; LocalAPI = **proxy**, not full agent tools |
| **P4** | Compaction, skills, memory, sub-agents | Partial — see `docs/GROK_PORT.md` and registry honesty in ARCHITECTURE |
| **P5** | Diagnostics, onboarding wizard, distribution | Onboarding currently a no-op; no first-run model download |

**Open product decision (not resolved in this doc):** ship one zero-deps/auto-spawn path (wire mlx-swift **or** restore a managed runner **or** deep auto-detect + launch of LM Studio/oMLX) **or** keep BYO-server forever and keep marketing aligned.

This file (DESIGN.md) is the design contract for everything in `Sources/`. If code drifts from **shipped** claims in the status box at the top, fix the code or update this doc with a dated honesty amendment.

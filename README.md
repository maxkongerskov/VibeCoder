# VibeCoder

Native macOS agentic coder that runs on your own hardware.

**Inference model (honest):** bring-your-own **local OpenAI-compatible HTTP server**. Live first-class backends: **LM Studio**, **oMLX**, **Ollama**, **Unsloth Studio**, **EXO**, and **custom** `/v1` endpoints.  
**Not shipped:** in-process Swift MLX generation (`mlx-swift` not wired — adapter stub only), bundled llama.cpp/GGUF runner (product **removed**; use Ollama or any OpenAI-compat server). There is no `LiteLocalBackend`.

Open-source under the [MIT License](./LICENSE). Apple Silicon, macOS 14+. SwiftUI app sharing the core library, plus an interactive `vibecoder` REPL (C1).

> **Where this project came from.** This is the second pass on Max's AgentOS DEV PLAN. A full critique and architectural diff from v1 lives in [`DESIGN.md`](./DESIGN.md). Read that first — including the **shipped status box** at the top of DESIGN.

---

## Why it exists

The local-LLM tools you can install today fall into two camps:

- **LM Studio / Ollama / oMLX** — great chat (or serving) over local models; no agent, no tools, no diff-aware edits.
- **Cursor / Claude Code / Windsurf** — great agentic editing; cloud-dependent, subscription-priced, and you can't ship your code base anywhere they aren't allowed.

VibeCoder is the missing layer: a real agent loop, real tools, real diff-aware edits, **on your Mac**, pointed at a **local** OpenAI-compatible model server you already run (or install). Weights and chat stay on-device when that server is local; the app does not embed a zero-deps inference engine today.

Two anchors (with honest caveats):

1. **Local agent + git worktree isolation.** Binding a **git** project enables a sibling worktree `<project>-agentcore-<id>` on branch `agentcore/<id>` **by default**. Review and merge before it touches the main checkout (escape hatch: edit main tree). Requires a reachable local model server for the LLM turns. Non-git folders bind without a worktree.
2. **OpenAI-compatible local server for Xcode.** Point Xcode 16's Intelligence tab at `http://localhost:11435/v1` and completions run against your configured backend — loopback-only. **Default is a backend proxy** (`tools: []`). Settings opt-in runs a **bounded AgentLoop** (cap 8) on the **bound project** — tools execute server-side; this is **not** schemas-only and **not** in-app worktree/review/MCP parity. See ARCHITECTURE §5.7.

---

## Trust & privacy

- **MIT open source** — see [LICENSE](./LICENSE) and [LEGAL.md](./LEGAL.md).
- **No telemetry / no Sparkle / no Sentry** in the shipping package.
- **Empty entitlements** (not App Sandboxed): agent tools and shell run with full user privileges, gated by Safe Mode / approvals.
- **Local API** defaults to loopback completions proxy (`tools: []`); multi-step agent loop is **opt-in** (bounded AgentLoop on the bound project).
- **LAN / phone remote control is OFF** — not password-gated, not a shipping feature.
- **“Stays on your Mac”** is true for loopback backends. A **custom remote `/v1`** endpoint you configure will receive prompts and tool context — by design.



## First-run: start a model server

VibeCoder will not invent tokens until something answers OpenAI-compatible `chat/completions` on loopback (or your custom host).

| Server | Typical base URL | Notes |
|--------|------------------|--------|
| **[LM Studio](https://lmstudio.ai)** | `http://127.0.0.1:1234/v1` | Lists **downloaded** models via LM Studio’s native `/api/v1/models` (not only currently loaded). Start the local server (Developer → Local Server), then pick LM Studio; selecting a model loads it if needed. |
| **oMLX** | `http://127.0.0.1:8080/v1` | Apple-Silicon-friendly server process; app can load/unload via oMLX’s status API. Optional API key in Settings or `OMLX_API_KEY`. |
| **[Ollama](https://ollama.com)** | `http://127.0.0.1:11434/v1` | `ollama serve` + pull a model; OpenAI-compat API. (Replaces the old bundled-llama product path.) |
| **Unsloth Studio** | `http://127.0.0.1:8888/v1` | Lists Studio models folder + cache; load/unload via `POST /v1/load` / `/v1/unload`. Bearer auth required (Settings API key, or auto-read of local Studio agent key). |
| **[EXO](https://github.com/exo-explore/exo)** | `http://127.0.0.1:52415/v1` | Cluster; set **Model ID** in Settings (pin) so the picker doesn’t flood with the full catalog. |
| **Custom** | your `/v1` URL | Any OpenAI-compatible server (vLLM, llama-server you run yourself, OpenRouter, etc.). |

**Suggested path:** install LM Studio → download a tool-capable coding model → load it → enable local server → open VibeCoder → Connection → LM Studio → Test / refresh models → chat.

Offline agentic coding (airplane mode) works for **local tools** (filesystem, shell, git, worktree, plan, memory) as long as the model server remains reachable on loopback. Tools that need the public internet (`web_search`, `fetch_url`, …) will fail offline.

---

## Project layout

```
VibeCoder/                      repo root (ships as VibeCoder.app)
├── Package.swift               SPM manifest (no mlx-swift dependency yet)
├── DESIGN.md                   Design critique + honesty status box
├── ARCHITECTURE.md             Product architecture + amendment log
├── docs/GROK_PORT.md           Grok Build port surface
├── Sources/
│   ├── AgentCore/              Pure Swift core — backends, tools, agent loop
│   ├── MLXBackend/             Optional MLX adapter **stub** (depends on AgentCore)
│   ├── VibeCoderCLI/           Interactive `vibecoder` REPL entry (C1; not eval-runner)
│   ├── VibeCoderCLILib/        REPL, TTY y/n, TurnRunner → AgentLoop
│   └── Harness/                Experimental rewrite (not the app daily driver)
├── Tests/
│   ├── AgentCoreTests/
│   └── VibeCoderCLILibTests/
└── App/                        SwiftUI macOS app + XcodeGen spec
    ├── project.yml
    ├── VibeCoderApp.swift
    └── …
```

## Build & run

### App

The app target lives in `App/VibeCoder.xcodeproj` — checked into the repo so you can open and run immediately:

```bash
open "App/VibeCoder.xcodeproj"
```

Then ⌘R inside Xcode. The project references the SPM package at `..` (the repo root) for `AgentCore` and `MLXBackend`, so building the app implicitly builds the library.

**What you'll see on ⌘R:**
- Sidebar with the conversation list (bound to `ConversationStore` on disk)
- Toolbar model-picker chip showing the active backend + selected model
- Chat pane: streaming assistant content, tool-call stubs, expandable tool-result cards
- Multi-line composer (Enter to send, Shift+Enter for newline) with inline cancel
- Settings sheet (gear icon) with Connection / Sampling / System Prompt / Agent / Local API tabs
- Local API toggle that starts an OpenAI-compatible **proxy** on a configurable port (loopback-only); agent-loop on that port is a separate Settings opt-in

An XcodeGen `project.yml` is also included as an alternate generator if you'd rather regenerate the `.xcodeproj` from a declarative spec — useful if the pbxproj ever gets messy from manual edits in Xcode. `brew install xcodegen && cd App && xcodegen generate`.

### CLI (`vibecoder`, C1)

Interactive REPL on the same `AgentCore` / BYO HTTP backends / `ConversationStore` as the app. Shared worktree bind. TTY ask-mode is y/n/always (empty, `n`, or unknown = deny). **Not** `agentos`. **Not** `eval-runner`.

```bash
swift run vibecoder --project /path/to/repo --backend ollama --model qwen
```

**C2:** EventPrinter colors TTY roles; `NO_COLOR` or non-TTY = C1 plain text (no escapes). **C3:** SIGINT during a turn cancels `AgentLoop` via `TurnCancelHandle` (no `AgentLoop.swift` growth); idle Ctrl+C still exits. TTY `always` is durable; patch `always` → directory grant. The historical `agentos` CLI is gone.

## Backends

| Backend | Status | Default endpoint | Notes |
|---|---|---|---|
| **LM Studio** | ✅ working | `localhost:1234/v1` | Native `/api/v1/models` lists downloaded LLMs; chat via OpenAI-compat |
| **oMLX** | ✅ working | `localhost:8080/v1` | OpenAI-compat + load/unload preflight |
| **Ollama** | ✅ working | `localhost:11434/v1` | OpenAI-compat; recommended replacement for removed llama.cpp product |
| **Unsloth Studio** | ✅ working | `localhost:8888/v1` | Models folder inventory + load/unload from the chat model picker |
| **EXO** | ✅ stream + Cluster pane | `localhost:52415/v1` | Sidebar Cluster when EXO is selected: read-only `/state` + pin Model ID |
| **Custom** | ✅ working | user URL `/v1` | Any OpenAI-compatible server |
| **Swift MLX (in-process)** | ❌ stub | n/a | `MLXBackend` links; stream throws until mlx-swift is wired. Not a daily driver. Boot migrates persisted `.mlx` → Ollama. |
| **Bundled llama.cpp / GGUF** | ❌ removed | — | No vendored binary; no auto-spawn. Historical eval alias may still hit a user-run server on `:8765`. |

The agent loop is backend-agnostic for any OpenAI-compatible `chat/completions` server — pick a working backend in Settings / the model picker after the server is up.

## Quick start

```bash
open "App/VibeCoder.xcodeproj"   # then ⌘R to run VibeCoder.app
swift build                      # optional: compile-check AgentCore / MLXBackend / Harness
swift test                       # optional: run AgentCoreTests
```

1. Start LM Studio (or oMLX / Ollama / Unsloth Studio / EXO) and load a model.  
2. In the app: Settings → Connection → select that backend → Test connection / refresh models.  
3. Use **Load / Unload** on rows in the text-input model list for LM Studio, oMLX, and Unsloth Studio without opening each provider’s UI.  
4. Chat — streaming tokens, tool calls, and tool-result cards stay on your Mac relative to that local server.

## License

**MIT License** — see [LICENSE](./LICENSE).

Free, open-source, no license keys or trials. Fork it, modify it, ship it.
Contributions welcome via pull request.

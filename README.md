# VibeCoder

MIT-licensed native macOS coding agent. Bring your own OpenAI-compatible HTTP server (LM Studio, oMLX, Ollama, Unsloth Studio, EXO, or custom `/v1`). Apple Silicon, macOS 14+.

The agent loop is plan → tools → verify → repeat. Edits use SEARCH/REPLACE and unified diffs. Binding a **git** project isolates work in a sibling worktree (`<project>-agentcore-<id>` / `agentcore/<id>`) by default; merge/discard are user-driven. Escape hatch: edit the main tree.

Not shipped: in-process Swift MLX (`mlx-swift` unwired; stub throws), bundled llama.cpp/GGUF, Sparkle, Sentry, license keys. `RemoteControlServer` is off.

**CloudBots** are early/v1, **cloud**, and labeled as cloud — not a local-inference path.

Architecture: [`ARCHITECTURE.md`](./ARCHITECTURE.md) (§1 / §17 win). No separate PLAN.md.

## Build & run

```bash
open "App/VibeCoder.xcodeproj"   # ⌘R → VibeCoder.app
swift build                      # AgentCore / CLI
swift test                       # AgentCoreTests (App UI tests need xcodebuild)
swift run vibecoder --project /path/to/repo --backend ollama --model qwen
```

App target is `App/VibeCoder.xcodeproj` (SPM package at `..`). Optional: `brew install xcodegen && cd App && xcodegen generate`.

Conversations persist at `~/Library/Application Support/VibeCoder/conversations/`.

## BYO HTTP

Start a local OpenAI-compatible server, then Settings → Connection → Test.

| Server | Typical `/v1` |
|--------|----------------|
| [LM Studio](https://lmstudio.ai) | `http://127.0.0.1:1234/v1` |
| oMLX | `http://127.0.0.1:8080/v1` |
| [Ollama](https://ollama.com) | `http://127.0.0.1:11434/v1` |
| Unsloth Studio | `http://127.0.0.1:8888/v1` |
| [EXO](https://github.com/exo-explore/exo) | `http://127.0.0.1:52415/v1` (pin Model ID; Cluster pane when EXO is selected) |
| Custom | your `/v1` URL |

Loopback backends keep weights on the Mac. A **remote** `/v1` you configure receives prompts and tool context.

Local API (Settings → Connection): `http://localhost:11435/v1` for Xcode Intelligence. Default is a backend proxy (`tools: []`). Opt-in bounded AgentLoop (cap 8) on the bound project — not in-app worktree/review/MCP parity.

CLI `vibecoder` is C1–C3: same AgentCore, TTY y/n/always. Not `agentos`. Not `eval-runner`.

## Layout

```
Package.swift          SPM (no mlx-swift)
ARCHITECTURE.md        rail (§1 / §17)
DESIGN.md              critique + honesty box
Sources/AgentCore/     loop, tools, backends, worktrees
Sources/VibeCoderCLI/  vibecoder REPL
App/                   SwiftUI + Xcode project
Tests/                 AgentCoreTests, CLI tests
Evals/                 eval-runner (mock 012/013 ≠ live-backend proof)
```

## License

[MIT](./LICENSE). See [LEGAL.md](./LEGAL.md).

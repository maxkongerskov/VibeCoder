# Coding bar (30-day)

Operating plan: [`LEAD_PLAN.md`](./LEAD_PLAN.md).  
This file is **evidence** for: ships real code, runs fast, works on every shipped provider.

Fill cells with command + result, or “skip: reason”. Mock-worker 012/013 and “Hey” first-chat **do not** satisfy C1.

**Window:** 2026-08-23 → 2026-09-22. Owner: Max.

---

## Day-0 snapshot (Week 1.3 — fill once, same model)

| | Value |
|---|---|
| Date | 2026-08-23 |
| Backend / model | Unsloth Studio `:8888` / `unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` (loaded) |
| Surface | `eval-runner` (Recommended catalog) |
| Tools on the wire (count + list) | **17** — `apply_patch`, `create_plan`, `edit_file`, `find_symbol`, `git_commit`, `git_diff`, `git_status`, `glob_files`, `grep_code`, `list_directory`, `read_file`, `read_session_context`, `run_shell`, `tool_search`, `update_todo`, `write_file`, `xcode_build`. (`revise_plan` is deferred / `tool_search` only.) |
| Schema tokens (estimate) | **2943** (JSON of offered schemas, char/4) |
| Time to first tool | First `read_file` in the same turn; wall clock **36s** start→error |
| Iterations | `read_file` → `apply_patch` → `read_file` → duplicate `read_file` blocked |
| Prompt (one line) | 013 apply_patch smoke: change `print("hello")` to `print("hello, world")` via `apply_patch` |
| Result | **Artifact pass, loop fail.** Oracle PASS (`hello.swift` patched). Then llama-server HTTP **400**: `Cannot have 2 or more assistant messages at the end of the list.` `eval-runner` exit 1. Log: `Evals/results/2026-08-23-unsloth-nemotron-d0-013/` |

Use this row as the baseline. Day-30 compares **the same model** if possible. Other providers **skipped this window** (Max: Unsloth only).

---

## C — Ships real code

| # | Bar | Evidence |
|---|---|---|
| C1 | Git project bound → worktree → patch (`apply_patch` or `edit_file`) → project test/build runs → main tree clean until merge | **Pass headless.** (1) `write_file` smoke: `VibeCoder-agentcore-c1`. (2) **patch-first:** `VibeCoder-agentcore-d07` `apply_patch` on `ChatCompletionsWireAssembly.swift` (`// D07 patch-first`); `swift test --filter ChatCompletionsWireAssemblyTests` **4/4**; main checkout **no** that comment. Merge not done. |
| C2 | Same class of task **in-app** (VibeCoder.app), not only headless | **Blocked (2026-08-23).** App launched (`tools.vibecoder.VibeCoder`). Composer showed Nemotron Lightning; `set-value` filled the prompt; send stayed disabled; Return did not start a turn. Notes: `Evals/results/2026-08-23-c2-in-app/`. Not eval-runner. |
| C3 | Failure injects compiler/test output; loop does not hang | **Recapture 2026-08-23.** Live Unsloth: `apply_patch` then BuildGuard. `convo.json` user message contains `# System reminder — BuildGuard` / `BuildGuard: build failed` plus `cannot convert value of type 'String' to specified type 'Int'`; next assistant quotes that error. stderr: `[eval-runner] BuildGuard: build failed`. `Evals/results/2026-08-23-unsloth-d04-buildguard/convo.json`. Unit: `testVerifyBrokenSwiftPackageReturnsFailedLog`. |
| C4 | Cancel (⌘. / SIGINT) leaves a paired transcript | **Unit pass:** `AgentLoopCancelPersistTests` + `CLICancelTests` `testCancelMidToolPersistsPairedTranscript` (2026-08-23). **Live SIGINT:** eval-runner ignored INT before cap (`run_shell` backgrounded); conversation saved 14 msgs. `Evals/results/2026-08-23-unsloth-d05-cancel/`. |

C1 project: this repo **or** another real Swift package. Toy `Evals/tasks/001-hello-world` is not C1.

---

## S — Fast (default Recommended / coding core)

Catalog contract: `LEAD_PLAN.md` §4.

| # | Bar | Day-0 | Day-30 |
|---|---|---|---|
| S1 | Default tools-on-wire = coding core (no PDF, computer-use, browser-use, cron) | **17** coding-core; no PDF/web/computer/browser/cron | |
| S2 | Schema token estimate / turn | **2943** | |
| S3 | Time to first tool (same model) | C1 wall **59s** / 5 tools (first `list_directory`); 013 wall **29s** (first `read_file`). No per-token probe. | **same** |
| S4 | Iterations to green on the C1 prompt (same model) | C1: **5** tool calls then stop (write_file path). D07: **4** tool calls, third `apply_patch` succeeded. | **≤ day-0** |

`ToolOffer` “All tools” is opt-in. Master switches stay off.

---

## P — Providers

Shipped: LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom `/v1`.

For each: **down** (honest skip) / **connect** (`listModels` or Connection Test) / **coding turn** (at least one tool call live).

| Provider | Down / skip | Connect | Coding turn | Notes |
|---|---|---|---|---|
| LM Studio (`:1234`) | skip (this window) | — | — | Max: Unsloth only for now |
| oMLX (`:8080`) | skip (this window) | — | — | Max: Unsloth only for now |
| Ollama (`:11434`) | skip (this window) | — | — | Max: Unsloth only for now |
| Unsloth Studio (`:8888`) | up | **pass** (`listModels`, Nemotron Lightning `loaded`) | **013 pass** (oracle + exit 0, 29s, no 400) | F4 “Hey” ≠ this row |
| EXO (`:52415`) | skip (this window) | — | — | Max: Unsloth only for now |
| Custom `/v1` | skip (this window) | — | — | Max: Unsloth only for now |

**Window rule:** at least **two** backends complete a live coding turn. The rest must connect or skip with a named reason. Crashes and fake catalogs fail the bar.

---

## Out of this bar

- Mock T0 / 012 / 013 (those stay CI smoke)
- Notarized DMG
- App XCTest on GitHub Actions
- CloudBots, computer-use, browser-use, ZCode parity
- In-process MLX

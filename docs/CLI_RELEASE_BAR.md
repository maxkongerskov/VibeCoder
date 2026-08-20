# CLI launch bar (`vibecoder`)

What **99%** means for the interactive **`vibecoder` REPL**. Not a hobby demo. Not `agentos`. Not `eval-runner`. Not a TUI. Native app remains primary.

Ada owns this file. Lin/Pixel/Rigel/Turnip raise the numbers with **evidence**, not vibes. Do not claim 99% without the proof column filled. Max ships only when Ada, Lin, Pixel, Rigel, and Turnip are each 99% confident it is launchable.

Inspected (2026-08-21): `Sources/VibeCoderCLI/main.swift`, `Sources/VibeCoderCLILib/{CLIArgs,EventPrinter,REPL,TTYApprovals,TurnRunner}.swift`, `Tests/VibeCoderCLILibTests/*`. HEAD `7baddb2` (C1–C3). Do not mix the dirty 99% app tree into this cut.

---

## Max-approved decisions (do not reopen this cut)

| Date | Decision |
|------|----------|
| 2026-08-20 | **BYO HTTP forever (v1):** LM Studio / oMLX / Ollama / Unsloth Studio / EXO / custom `/v1`. No mlx-swift. No bundled llama.cpp. MIT. No Sparkle. No Sentry. No license key. |
| 2026-08-21 | **Surface:** interactive `vibecoder` REPL. Same `AgentCore` / `ConversationStore` / worktree bind as the app. **Not** `agentos`. **Not** `eval-runner`. **Not** a TUI. Native app still primary. |
| 2026-08-21 | **C1–C3 in product:** REPL + flags; TTY color (`NO_COLOR` / non-TTY = plain); SIGINT cancel-in-turn via `TurnCancelHandle` (no `AgentLoop.swift` growth); TTY y/n/always (empty/`n`/unknown deny); patch `always` → directory grant. |
| 2026-08-21 | **Isolation:** do not grow `ChatViewModel.swift` or `AgentLoop.swift`. Do not merge eval-runner into `vibecoder`. Do not mix 99% app diffs into CLI docs or CLI commits. |
| 2026-08-21 | **Non-goals:** Homebrew formula, one-shot `vibecoder run "fix foo"`, mermaid, in-process MLX, SQLite session rewrite, TUI, `agentos` restore. |

---

## 99% — explicit meaning

The CLI is 99% when **all** cells below are true **and** Rigel has written evidence (command + result, or eval id + pass). Unit tests alone are not a live TTY. A scorecard with empty cells is not 99%.

### First-run

| # | Bar | Evidence |
|---|-----|----------|
| F1 | `swift run vibecoder --help` (and `-h` / `help`) prints usage and exits 0; unknown flags exit 2 with usage on stderr | |
| F2 | Server **down**, no `--model` → process does **not** sit at `›`. User-visible reason names the backend and tells them to start the server or pass `--model` | |
| F3 | Server **down** + `--model ID` → same as F2: **must not** print `›` and fail on first send. Today `REPL.resolveModel` skips `listModels` when `--model` is set — **must-fix** | |
| F4 | Server **up** + reachable model → first user turn streams tokens to stdout and ends with `[done] …` | |

### REPL surface (C1)

| # | Bar | Evidence |
|---|-----|----------|
| R1 | Line REPL: `›` prompt, `/help` `/exit` `/quit` `/new`. Continuation on trailing `\`. **Not** a TUI (no alt-screen, no mouse) | |
| R2 | Same `ConversationStore.shared` as the app (App Support `conversations/`). Turn success, turn error, and cancel persist | |
| R3 | `--resume UUID` loads that conversation; missing id prints `resume id not found` and starts new | |
| R4 | Default `--project` is cwd; `--project PATH` binds that folder; `--backend` / `--model` / `--max-iterations` parse as `CLIArgs` | |
| R5 | Git project bind enables worktree isolation (same `WorktreeService.bindProjectEnablingWorktree` contract as the app). Non-git: bind succeeds, `userVisibleReason` on stderr, `worktreeBranch` nil | |

### Color (C2)

| # | Bar | Evidence |
|---|-----|----------|
| C1 | TTY stdout/stderr: EventPrinter paints role colors (tool/build/error/ask/done) | |
| C2 | `NO_COLOR` set (non-empty) **or** non-TTY → C1 plain text, **no** CSI escapes | |

### Cancel + approvals (C3)

| # | Bar | Evidence |
|---|-----|----------|
| K1 | SIGINT **during a turn** cancels `AgentLoop` via `TurnCancelHandle` (no `AgentLoop.swift` edit). Returned conversation persists with paired `tool_calls` (same contract as A4) | |
| K2 | Idle Ctrl+C at `›` **exits the process** (SIGINT not armed) | |
| K3 | TTY shell prompt `[y/n/always]`. `y`/`yes` → once. `always` → durable `ShellApprovalDecision.always`. Empty / `n` / `no` / unknown → **deny** | |
| K4 | Patch `[y/n/always]`. `always` → accept + `RememberedGrants.alwaysAllowDirectory` for the common folder. Empty/`n`/unknown → reject all | |

### Backends

| # | Bar | Evidence |
|---|-----|----------|
| B1 | `--backend` accepts `lmstudio` / `omlx` / `ollama` / `unsloth` / `exo` / `custom` (aliases in `CLIArgs.parseBackend`) | |
| B2 | `--backend mlx` must **not** pretend in-process MLX works (usage omits it; parse currently accepts `.mlx` — refuse or honest stub error before `›`) | |
| B3 | Custom `/v1` uses app `SettingsStore` custom URL. Remote URL is allowed and must not be marketed as “nothing leaves your Mac” | |

### Proof pack (Rigel owns the folder)

Write results under `docs/orchestration/` or `Evals/results/` with date. A scorecard with empty cells is not 99%.

| # | Bar | Evidence |
|---|-----|----------|
| P1 | Dedicated CI step: `swift test --filter VibeCoderCLILib` (full `swift test` in `ci-pr.sh` is **not** this cell). Today: no CLI-specific job on the CLI commit; `.github/workflows/pr.yml` is untracked 99% tree | |
| P2 | One **live TTY** session artifact (script or notes): help, one turn, SIGINT mid-turn returns to `›`, idle Ctrl+C exits. Unit tests are not a TTY | |
| P3 | Rail honesty on the **CLI commit line**, not mixed into uncommitted 99% diffs. HEAD `7baddb2` `README.md` still says Interactive CLI removed. Working-tree README/DESIGN/ARCHITECTURE C1–C3 honesty is dirty with the app 99% tree | |
| P4 | `origin` has the CLI commit when Max says ship. Today: `7baddb2` is **7 ahead, not pushed** | |

---

## Confirmed holes (2026-08-21 Ada inspect)

Keep these until the matching cell has evidence. Do not drop.

| Hole | Cell | Status |
|------|------|--------|
| (a) `--model` skips `listModels` → down server can print `›` and fail later | F3 | **must-fix** (`REPL.resolveModel`) |
| (b) no CI job dedicated to `VibeCoderCLILib` besides full `swift test` | P1 | **must-fix** |
| (c) no live TTY session | P2, F4, K2 | **must-fix** (evidence, not new code) |
| (d) README still titled “C1” (working tree); committed README still says CLI removed | P3 | **must-fix** (CLI-only docs commit) |
| (e) not pushed | P4 | ship gate; Max |
| (f) rail-doc honesty mixed into uncommitted 99% diffs | P3 | **must-fix** (extract CLI sentences only) |

Also inspect, not a 99% reopen: `--backend mlx` parses (`B2`). `listModels` uses `try?` so a down server without `--model` can look like “no models” (`F2` honesty). No CLI-specific worktree test (R5 can cite AgentCore W13 plus a REPL stderr assert).

---

## Non-goals (this bar)

- Homebrew / `brew install vibecoder`
- One-shot `vibecoder run "fix foo"` (REPL only this cut)
- TUI, mermaid, KaTeX, queue Edit, `node_repl`
- In-process MLX, mlx-swift, bundled llama.cpp
- SQLite session store
- Merging `eval-runner` into `vibecoder`
- Growing `ChatViewModel.swift` or `AgentLoop.swift`
- Mixing the dirty 99% app tree (Unsloth/app chrome/RELEASE_BAR app cells) into CLI commits
- Making CLI Local API / remote-control / in-app review-sheet parity

---

## Extraction / file freeze

| File | Allowed this cut | Not allowed |
|------|------------------|-------------|
| `Sources/VibeCoderCLI/main.swift` | help / exit codes only | AgentLoop policy |
| `Sources/VibeCoderCLILib/REPL.swift` | F2/F3 model probe; worktree stderr | growing AgentLoop |
| `Sources/VibeCoderCLILib/CLIArgs.swift` | B2 mlx refuse; usage title | new subcommands (`run`) |
| `Sources/VibeCoderCLILib/TurnRunner.swift` | SIGINT handle only if K1/K2 regress | AgentLoop.swift |
| `Sources/VibeCoderCLILib/TTYApprovals.swift` | K3/K4 only if tests fail | in-app sheets |
| `Sources/VibeCoderCLILib/EventPrinter.swift` | C1/C2 only | TUI |
| `Tests/VibeCoderCLILibTests/*` | F3 + any new assert | AgentCoreTests fishing |
| `README.md` / `DESIGN.md` / `ARCHITECTURE.md` | **CLI honesty hunks only**, separate commit from 99% app | Unsloth/app 99% cells |
| `docs/CLI_RELEASE_BAR.md` | Ada | — |
| `App/**`, `Sources/AgentCore/Agent/AgentLoop.swift`, `ChatViewModel.swift`, `Evals/**` | **do not touch** | — |

---

## Assignment (this cut)

**Lin** — exclusive: `REPL.swift` (+ test) for **F3** (and F2 honesty if the `try?` swallow stays). Optional **B2** (`CLIArgs.swift`: refuse `--backend mlx`). Do not touch `AgentLoop.swift` / `ChatViewModel.swift` / eval-runner.

**Pixel** — exclusive: `EventPrinter.swift` only if C1/C2 need a fix. Do not retitle README in the 99% dirty tree — Ada extracts CLI honesty.

**Rigel** — exclusive: **P1** dedicated `swift test --filter VibeCoderCLILib` in the CLI CI path (do not land via the untracked 99% `.github/` mix unless that file is split); **P2** live TTY artifact; fill every Evidence cell. Do not `git push`.

**Ada** — this bar; **P3** CLI-only rail honesty commit (README/DESIGN/ARCHITECTURE CLI sentences + drop the “C1” title). Not the 99% app hunks.

**Turnip** — re-verify filters after Lin/Rigel land; keep 99% as evidence.

**Max** — **P4** push when five-way 99%.

### Definition of done

1. F1–F4, R1–R5, C1–C2, K1–K4, B1–B3, P1–P3 have non-empty Evidence (command + result or eval id).
2. F3 is fixed in `REPL.swift` (server down + `--model` never presents `›`).
3. Rail docs on the CLI commit line tell the C1–C3 truth (not “CLI removed”, not a “C1”-only heading).
4. Ada, Lin, Pixel, Rigel, Turnip each report `CONFIDENCE: 99%` with evidence.
5. Then Max may push. P4 is not Ada’s to fire.

---

## Confidence rule

Ada/Lin/Pixel/Rigel/Turnip each report:

```
CONFIDENCE: N%
EVIDENCE: …
BLOCKERS: …
NEXT_ASSIGNMENT: …
```

**99%** requires F1–F4, R1–R5, C1–C2, K1–K4, B1–B3, P1–P3 with artifacts. P4 is the ship/push gate after that.

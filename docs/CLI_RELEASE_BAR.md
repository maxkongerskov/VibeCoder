# CLI launch bar (`vibecoder`)

What **99%** means for the interactive **`vibecoder` REPL**. Not a hobby demo. Not `agentos`. Not `eval-runner`. Not a TUI. Native app remains primary.

Ada owns this file. Lin/Pixel/Rigel/Turnip raise the numbers with **evidence**, not vibes. Do not claim 99% without the proof column filled. Max ships only when Ada, Lin, Pixel, Rigel, and Turnip are each 99% confident it is launchable.

Inspected (2026-08-22): `Sources/VibeCoderCLI/main.swift`, `Sources/VibeCoderCLILib/{CLIArgs,EventPrinter,REPL,TTYApprovals,TurnRunner}.swift`, `Tests/VibeCoderCLILibTests/*`. Local `main` HEAD `dee1383` (C1–C3 still on this line). App 99% and CloudBots slice 0 are already committed here — a Max origin push is this whole line, not the old CLI-only cut.

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
| F1 | `swift run vibecoder --help` (and `-h` / `help`) prints usage and exits 0; unknown flags exit 2 with usage on stderr | **Rigel 2026-08-21 00:59.** `swift run --skip-build vibecoder --help` exit **0**, usage on stdout. `.build/debug/vibecoder -h` and `help` exit **0**. `--nope` exit **2**, usage on stderr. |
| F2 | Server **down**, no `--model` → process does **not** sit at `›`. User-visible reason names the backend and tells them to start the server or pass `--model` | **Rigel 2026-08-21 00:59.** Ollama down: `vibecoder --backend ollama --project /tmp/vc-cli-f2` exit **1** in 0.04s. stderr `Can't reach Ollama (Could not connect to the server.). Start the server.` No REPL `›`. `CLIModelProbeTests.testDownServerWithoutModelDoesNotLookLikeEmptyCatalog` pass. |
| F3 | Server **down** + `--model ID` → same as F2: **must not** print `›` and fail on first send. Today `REPL.resolveModel` skips `listModels` when `--model` is set — **must-fix** | **Rigel 2026-08-21 00:59.** Lin landed always-probe. Live: Ollama down `vibecoder --backend ollama --model qwen --project /tmp/vc-cli-f3` exit **1** in 0.04s, same `Can't reach Ollama… Start the server.` No `›`. `CLIModelProbeTests` **6/6** including `testDownServerThrowsBeforePromptEvenWithModelFlag`. |
| F4 | Server **up** + reachable model → first user turn streams tokens to stdout and ends with `[done] …` | **Rigel 2026-08-21 01:02.** oMLX `:8080` `mlx-community--Qwen3-0.6B-4bit`. PTY turn `Reply with only the word hello.` → stdout `hello` then `[done] stop` (~70s first load). Artifact `docs/orchestration/cli-tty-2026-08-21.md`. |

### REPL surface (C1)

| # | Bar | Evidence |
|---|-----|----------|
| R1 | Line REPL: `›` prompt, `/help` `/exit` `/quit` `/new`. Continuation on trailing `\`. **Not** a TUI (no alt-screen, no mouse) | **Rigel 2026-08-21.** PTY: `›`, `/help` prints usage, `/ex\` → `…` then `it` exits 0. No alt-screen (`CSI ?1049`). Artifact session A. `/quit` `/new` not live-clicked; `/new` exists in `REPL.swift`. |
| R2 | Same `ConversationStore.shared` as the app (App Support `conversations/`). Turn success, turn error, and cancel persist | **Rigel 2026-08-21 01:02.** `~/Library/Application Support/VibeCoder/conversations/70256FC5-….json` title `CLI`, project `/tmp/vc-cli-p2-live2`, user+assistant hello persist; cancelled list user line persisted. `CLICancelTests` 3/3 pairing on cancel. |
| R3 | `--resume UUID` loads that conversation; missing id prints `resume id not found` and starts new | **Rigel 2026-08-21 00:59.** `--resume 00000000-0000-0000-0000-000000000000` (oMLX) stderr `resume id not found; starting new conversation` then `›`. `/exit` 0. |
| R4 | Default `--project` is cwd; `--project PATH` binds that folder; `--backend` / `--model` / `--max-iterations` parse as `CLIArgs` | **Rigel 2026-08-21 00:58.** `CLIArgsTests` 7/7: cwd default, `--project /tmp/cli-proj --backend ollama --model qwen`, `--max-iterations 12`, `--resume` UUID. |
| R5 | Git project bind enables worktree isolation (same `WorktreeService.bindProjectEnablingWorktree` contract as the app). Non-git: bind succeeds, `userVisibleReason` on stderr, `worktreeBranch` nil | **Rigel 2026-08-21.** Non-git: stderr `Not a git repository: /tmp/vc-cli-r5-nongit. Worktree mode requires git.` Git temp repo: banner `worktree agentcore/5350fc21`; store `worktreeBranch=agentcore/5350fc21`. Sibling cleaned up. |

### Color (C2)

| # | Bar | Evidence |
|---|-----|----------|
| C1 | TTY stdout/stderr: EventPrinter paints role colors (tool/build/error/ask/done) | **Rigel 2026-08-21 00:58.** `EventPrinterTests` 5/5: `testTTYColorPathEmitsANSIForErrorAndToolEvents`, `testColorEnabledRespectsNO_COLORAndTTY`. Live PTY F4 `[done] stop` had **no** CSI (residual — unit injects color flags; public `isatty` path not seen in this PTY log). |
| C2 | `NO_COLOR` set (non-empty) **or** non-TTY → C1 plain text, **no** CSI escapes | **Rigel 2026-08-21.** Unit: `testNoColorAndNonTTYMatchC1PlainText`, `NO_COLOR=1` disables even on TTY. Live: `NO_COLOR=1` PTY `/exit` no CSI; piped `--help` no CSI. |

### Cancel + approvals (C3)

| # | Bar | Evidence |
|---|-----|----------|
| K1 | SIGINT **during a turn** cancels `AgentLoop` via `TurnCancelHandle` (no `AgentLoop.swift` edit). Returned conversation persists with paired `tool_calls` (same contract as A4) | **Rigel 2026-08-21.** Unit: `CLICancelTests` 3/3 (`testSIGINTMapsToTurnCancelAndPersistsPairedTranscript`, pairing valid). Live PTY: SIGINT during second oMLX turn → `[done] cancelled` then `›`. No `AgentLoop.swift` edit. |
| K2 | Idle Ctrl+C at `›` **exits the process** (SIGINT not armed) | **Rigel 2026-08-21.** Fresh PTY at `›` (no in-flight turn): `^C` → **signal 2**, process exits (`› ^C`). **Turnip 2026-08-21:** first SIGINT now restores default disposition immediately (`TurnSIGINTSession.fire` → `restore()`), so a second Ctrl+C during `[done] cancelled` is fatal. `CLICancelTests.testFirstSIGINTRestoresDefaultDisposition` pass. |
| K3 | TTY shell prompt `[y/n/always]`. `y`/`yes` → once. `always` → durable `ShellApprovalDecision.always`. Empty / `n` / `no` / unknown → **deny** | **Rigel 2026-08-21 00:58.** `CLIApprovalsTests` 10/10: `testParseShellYIsOnce`, `testParseShellAlways`, `testParseShellEmptyAndNDeny`, `testAlwaysPersistsDurableGrant`, `testOnceDoesNotPersistGrant`, `testScriptedEmptyDenies`. |
| K4 | Patch `[y/n/always]`. `always` → accept + `RememberedGrants.alwaysAllowDirectory` for the common folder. Empty/`n`/unknown → reject all | **Rigel 2026-08-21 00:58.** `testParsePatchFailClosed`, `testPatchAlwaysPersistsDirectoryGrant`, `testPatchEmptyRejectsAndDoesNotGrant`. |

### Backends

| # | Bar | Evidence |
|---|-----|----------|
| B1 | `--backend` accepts `lmstudio` / `omlx` / `ollama` / `unsloth` / `exo` / `custom` (aliases in `CLIArgs.parseBackend`) | **Rigel 2026-08-21 00:58.** `CLIArgsTests.testBackendAliases` pass (lmstudio/unsloth/omlx/exo/custom). |
| B2 | `--backend mlx` must **not** pretend in-process MLX works (usage omits it; parse currently accepts `.mlx` — refuse or honest stub error before `›`) | **Rigel 2026-08-21 00:59.** Lin refuse landed. Live: `vibecoder --backend mlx` exit **2**, stderr `in-process MLX is a stub and is not shipped.` Usage omits mlx. `testMLXBackendIsRefused` pass. No `›`. |
| B3 | Custom `/v1` uses app `SettingsStore` custom URL. Remote URL is allowed and must not be marketed as “nothing leaves your Mac” | **Rigel 2026-08-21.** `--backend custom` parses (`testBackendAliases`). `main.swift` overlays `args.backend` onto `SettingsStore.shared.current()`; `BackendFactory` uses `settings.customEndpoint`. `LEGAL.md`: remote `/v1` exfiltrates by design; “nothing leaves your Mac” is loopback-only. |

### Proof pack (Rigel owns the folder)

Write results under `docs/orchestration/` or `Evals/results/` with date. A scorecard with empty cells is not 99%.

| # | Bar | Evidence |
|---|-----|----------|
| P1 | Dedicated CI step: `swift test --filter VibeCoderCLILib` (full `swift test` in `ci-pr.sh` is **not** this cell). Today: no CLI-specific job on the CLI commit; `.github/workflows/pr.yml` is untracked 99% tree | **Rigel 2026-08-21.** `a59c6b0` `ci(cli): VibeCoderCLILib job (P1) and live TTY notes (P2)` — only `scripts/ci-cli.sh`, `.github/workflows/cli.yml`, `docs/orchestration/cli-tty-2026-08-21.md`. Does **not** import `pr.yml`. **Turnip 2026-08-21 01:22.** `./scripts/ci-cli.sh` → **31/31**. Dirty `ci-pr.sh` / untracked `pr.yml` stay out of this cut. |
| P2 | One **live TTY** session artifact (script or notes): help, one turn, SIGINT mid-turn returns to `›`, idle Ctrl+C exits. Unit tests are not a TTY | **Rigel 2026-08-21.** `docs/orchestration/cli-tty-2026-08-21.md` — PTY `/help` + continuation `/exit`; F4 `hello`/`[done] stop`; mid-turn SIGINT → `[done] cancelled` then `›`; dedicated idle `^C` → signal 2. |
| P3 | Rail honesty on the **CLI commit line**, not mixed into uncommitted 99% diffs | **Ada 2026-08-21.** `eb507a5` `docs(cli): rail honesty for vibecoder REPL (C1–C3)` still on HEAD `3718799` (no later edits to those files). `git show HEAD:README.md`: heading `### CLI (\`vibecoder\`)` (no “C1” title); `swift run vibecoder --project …`; C2/C3 truth; **not** “CLI removed”. `git show HEAD:ARCHITECTURE.md` §5.8: REPL + C2 color/`NO_COLOR` + C3 SIGINT/`always`. DESIGN surfaces + Interactive CLI row = C1–C3, not agentos. Working-tree README re-added “C1” titles in the dirty app 99% mix — **not** the commit line; do not retitle that tree. |
| P4 | `origin` has the CLI commit when Max says ship. Today: local HEAD `dee1383` is **47 ahead of origin/main `aefcff9`, not pushed**. That line is CLI C1–C3 **plus** app 99% **plus** CloudBots slice 0 stub — not the old CLI-only cut (`d08fb28`, 12 ahead). | **Nash 2026-08-22.** `git log --oneline origin/main..HEAD` = 47. Origin still `aefcff9`. P4 remains Max. |

---

## Confirmed holes (2026-08-21 Ada inspect)

Keep these until the matching cell has evidence. Do not drop.

| Hole | Cell | Status |
|------|------|--------|
| (a) `--model` skips `listModels` → down server can print `›` and fail later | F3 | **closed in source + live** (Rigel 2026-08-21): always-probe; Ollama down + `--model` exit 1, no `›` |
| (b) no CI job dedicated to `VibeCoderCLILib` besides full `swift test` | P1 | **closed on the commit line** (Rigel `a59c6b0`): `scripts/ci-cli.sh` + `.github/workflows/cli.yml`; Turnip `./scripts/ci-cli.sh` **31/31** |
| (c) no live TTY session | P2, F4, K2 | **closed** (Rigel): `docs/orchestration/cli-tty-2026-08-21.md` |
| (d) README still titled “C1” (working tree); committed README still says CLI removed | P3 | **closed on the commit line** (Ada 2026-08-21): `eb507a5` / HEAD `README.md` is `### CLI (\`vibecoder\`)`, not “CLI removed”. Working-tree “C1” titles are the dirty 99% mix — leave them |
| (e) not pushed | P4 | ship gate; Max — **not pushed** (`dee1383`, 47 ahead of `aefcff9`; mixed CLI + app 99% + CloudBots slice 0) |
| (f) rail-doc honesty mixed into uncommitted 99% diffs | P3 | **closed on the commit line** (Ada 2026-08-21): CLI sentences live in `eb507a5`; 99% app hunks stay uncommitted |

Also inspect, not a 99% reopen: `--backend mlx` now **refuses** before `›` (B2 live exit 2). F2 down-server no longer `try?` empty-catalog. Live R5 non-git stderr + git `worktreeBranch` recorded. Residual: live F4 PTY log had no CSI because this shell exports `NO_COLOR=1` (Pixel: that is C2, not a miss; public `isatty` paints when `NO_COLOR` is unset). Post-cancel SIGINT race **closed** (Turnip 2026-08-21): first SIGINT restores default disposition.

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

**Rigel** — exclusive: **P1** dedicated `swift test --filter VibeCoderCLILib` in the CLI CI path (do not land via the untracked 99% `.github/` mix unless that file is split); **P2** live TTY artifact; fill every Evidence cell. Do not `git push`. **Landed** `a59c6b0`.

**Ada** — this bar. **P3 landed** `eb507a5` (evidence filled 2026-08-21, `d08fb28`). Do not retitle working-tree README.

**Turnip** — re-verify filters after Lin/Rigel land; keep 99% as evidence. **Done** 2026-08-21: `./scripts/ci-cli.sh` **31/31**.

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

### Five-way (2026-08-21)

| Who | CONFIDENCE | Note |
|-----|------------|------|
| Ada | 99% | P3 `eb507a5` / fill `d08fb28` |
| Lin | 99% | F2/F3/B2 at `3718799` |
| Pixel | 99% | C1/C2; F4 no-CSI = `NO_COLOR=1` harness |
| Rigel | 99% | P1/P2 `a59c6b0`; live TTY artifact |
| Turnip | 99% | Re-ran `./scripts/ci-cli.sh` **31/31**; scorecard cells filled |

P4 remains Max. Local `main` is already mixed (CLI C1–C3 + app 99% + CloudBots slice 0). An origin push publishes that whole line, not a CLI-only cut.

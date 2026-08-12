# AgentOS / VibeCoder Eval Harness

The thing every credible coding agent has and most don't publish honestly.

## What it is

A fixed set of tasks (`tasks/`), each with a binary pass/fail oracle. A runner
(`eval.sh`) executes the agent against every task and records pass rate +
duration + tool-call count per task. Re-run after any harness, prompt, or model
change to know — empirically — whether the change helps.

## Why it exists

Before this, AgentOS quality was judged by one prompt (the calculator app) run
by hand and graded by vibes. That's how the v1.1 SEARCH/REPLACE regression on
2026-06-18 made it to a user-visible state — there was no test that would have
caught it.

Pass rate is now the north star. Every harness change ships with a predicted
delta against baseline. Changes that don't move the number don't ship.

## Running

The interactive `agentos` CLI was removed. Evals use a thin headless product
**`eval-runner`** that drives `AgentCore.AgentLoop` against an OpenAI-compatible
backend.

```bash
# 1. Build the headless runner
swift build -c release --product eval-runner

# 2. Start your backend (llama-server, LM Studio, Ollama, or the mock)
#    llama.cpp:   llama-server on :8765  →  --backend llama
#    LM Studio:   server on :1234         →  --backend lmstudio
#    mock smoke:  see below

# 3. Run all tasks (eval.sh auto-builds eval-runner if missing)
./Evals/eval.sh --backend llama

# Optional flags
./Evals/eval.sh --backend lmstudio --model qwen3-coder-30b-instruct
./Evals/eval.sh --filter 001            # tasks whose name is 001 or 001-*
./Evals/eval.sh --filter 000-harness-alive --filter-exact  # exact directory name only
./Evals/eval.sh --max-iter 60           # raise the per-task iteration cap
./Evals/eval.sh --port 1235             # override backend port
./Evals/eval.sh --bin /path/to/eval-runner
# Filter rules (Wave C2): exact match, or name starts with "filter-",
# or substring when filter length >= 3. Short digits like "0" no longer
# match every 00x/01x task.
```

### Quality gates (honesty — three different bars)

| Path | What it runs | When |
|------|----------------|------|
| **`./scripts/eval-gate.sh`** | Curated XCTest **filters only** (no mock, no model, **not** full suite) | Local tight loops |
| **`./scripts/ci-pr.sh`** | Full `swift test` + mock T0 ratchet (`000-harness-alive`) | PR / merge confidence |
| **`.github/workflows/pr.yml`** | Invokes **`ci-pr.sh`** (full suite + T0) | GitHub Actions |

Do **not** treat eval-gate as “all tests green.” Phase C bulk suites
(memory dream, scheduler/job monitor, settings toggles, …) live in the
**full** package suite run by `ci-pr.sh`.

#### Fast unit gate (`eval-gate.sh`)

Curated AgentCore filters. Exits **non-zero** if any filter fails.

```bash
# From repo root (seconds–minutes, not a full suite)
./scripts/eval-gate.sh
GATE_FAIL_FAST=1 ./scripts/eval-gate.sh   # stop on first failure
```

Coverage today (authoritative list = `scripts/eval-gate.sh`):

- **Phase A:** interjection buffer, goals, hooks v1, SafeBash, skills, tool pairing  
- **Phase B:** hooks v2, LSP, permission rules, seatbelt, serve headless, task background, agent allowlist  
- **Phase C sample:** stop-hook cancel (`AgentLoopStopHookPC5Tests`), interjection live wire (`PC6InterjectionLiveWireTests`)

#### PR gate (`ci-pr.sh`)

```bash
# Full package unit suite + mock T0
./scripts/ci-pr.sh

# Full units only (skip mock eval)
SKIP_EVAL=1 ./scripts/ci-pr.sh

# Local convenience: swap full suite for eval-gate (do NOT use in GitHub Actions)
USE_EVAL_GATE=1 ./scripts/ci-pr.sh

# T0 only
SKIP_UNIT=1 ./scripts/ci-pr.sh
```

### Mock smoke / T0 alone (no full unit suite)

```bash
# Preferred: scripted mock (deterministic T0)
python3 Evals/support/scripted_mock_server.py --port 1234 --model-id mock-worker &
./Evals/eval.sh --backend mock --model mock-worker --port 1234 \
  --filter 000 --max-iter 5 --strict --baseline Evals/baseline.json

# Or full PR stub (unit tests + T0):
./scripts/ci-pr.sh

# Lightweight unit-only gate (curated filters — see table above):
./scripts/eval-gate.sh
```

Task `000-harness-alive` is a T0 smoke that **must pass** under the mock (oracle
checks that eval-runner finished a headless turn). Scaffold tasks 001–010 still
need a real coding model — the prose mock will fail those oracles by design.

Legacy static mock (prose plan only, same as before):

```bash
python3 Evals/support/mock_openai_server.py --port 1234 --model-id mock-worker &
./Evals/eval.sh --backend mock --model mock-worker --port 1234 --filter 001 --max-iter 5
```

Results go to `Evals/results/<timestamp>-<backend>-<model>.json`.

### Direct runner (without eval.sh)

```bash
./.build/release/eval-runner run "list files in the project" \
  --backend mock --port 1234 --model mock-worker \
  --project /tmp/some-workdir --max-iterations 5
```

### JSONL events + conversation resume (PB6)

`eval-runner` can emit a **machine-readable JSONL stream** and optionally
**resume / save** a `Conversation` JSON file. Default behavior for
`Evals/eval.sh` is unchanged: tool markers still look like `[✓ write_file]`
(on stdout unless `--json-events` is set, then markers move to stderr so
stdout stays pure JSONL).

```bash
# JSONL on stdout — one object per line:
#   {"type":"tool_call","id":"…","name":"…","phase":"started|completed","is_error":false}
#   {"type":"text","text":"…"}
#   {"type":"done","reason":"…","tool_calls":N,"messages":M,"ok":true}
#   {"type":"error","message":"…"}
./.build/release/eval-runner run "list files" \
  --backend mock --port 1234 --model mock-worker \
  --project /tmp/w --max-iterations 5 \
  --json-events \
  --save-conversation /tmp/convo.json

# Continue from a saved conversation (project root rebounds to --project):
./.build/release/eval-runner run "now fix the tests" \
  --backend mock --port 1234 --model mock-worker \
  --project /tmp/w --max-iterations 10 \
  --resume /tmp/convo.json --json-events
```

**Exit codes (honesty):**

| Code | Meaning |
|------|---------|
| **0** | Loop finished without a fatal agent error |
| **1** | Agent/backend failure, or a `.error` LoopEvent was observed |
| **2** | Bad CLI invocation (missing `--project`, unknown flags, …) |

**Not implemented (stubs / deferred):** multi-agent `--orchestrator-*` flags are
still accepted and **ignored**; resume is single-file Conversation JSON only
(no mid-tool crash checkpoints); `eval.sh` does not yet pass `--json-events`
through automatically.

## Task layout

Each task is a directory under `tasks/`:

```
tasks/001-hello-world/
  prompt.txt         # the user message handed to eval-runner
  oracle.sh          # exits 0 if pass, non-zero if fail (gets workdir as $1)
  seed/              # contents copied into the workdir before the run
```

Add a new task: copy an existing one, rewrite `prompt.txt`, rewrite `oracle.sh`.

## Oracle design

Oracles should be **loose but binary**:

- Hard signal: does it build? (`swift build` exit code)
- Soft signal: does the source look like the right kind of artifact?
  (a few grep checks for the obvious features)

If a task can pass with a wildly wrong but technically-building artifact, the
oracle is too loose. If a task fails for a stylistic deviation, the oracle is
too tight. Aim for "this is recognisably the thing the user asked for and it
runs."

## Baseline + ratchet (enforced)

Checked-in baseline: `Evals/baseline.json` (schema 1).

| Flag | Behavior |
|------|----------|
| `--strict` | Exit **1** if any task fails or no tasks ran |
| `--baseline PATH` | Exit **1** if a baseline `pass` becomes `fail`, or pass-rate drops more than `max_drop_pp` |
| `--write-baseline PATH` | Write a new baseline from this run (intentional bump only) |

Default (no flags): print summary, exit **0** (local exploration).

```bash
# PR-style gate (mock T0)
./Evals/eval.sh --backend mock --model mock-worker --port 1234 \
  --filter 000 --strict --baseline Evals/baseline.json

# After intentionally improving/changing the suite
./Evals/eval.sh ... --write-baseline Evals/baseline.json
```

Comparison logic lives in `Evals/support/compare_baseline.py` (unit-tested via
`python3 Evals/support/test_compare_baseline.py`).

CI stub: `./scripts/ci-pr.sh` and `.github/workflows/pr.yml`.

New tasks: convert a real-world failure into a regression task *before* fixing it,
then update `baseline.json` when the new task is green.

## Roadmap

Scaffold-an-app × 10 (001-010) exists. Next: fix-this-bug × N (seeded broken
repos), multi-file-refactor × N, security refuse, worktree isolation — see
`HANDOFF/orchestration-2026-07-23/W4-notes/`.

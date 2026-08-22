# Coding bar (30-day)

Operating plan: [`LEAD_PLAN.md`](./LEAD_PLAN.md).  
This file is **evidence** for: ships real code, runs fast, works on every shipped provider.

Fill cells with command + result, or “skip: reason”. Mock-worker 012/013 and “Hey” first-chat **do not** satisfy C1.

**Window:** 2026-08-23 → 2026-09-22. Owner: Max.

---

## Day-0 snapshot (Week 1.3 — fill once, same model)

| | Value |
|---|---|
| Date | |
| Backend / model | |
| Surface | app / `vibecoder` / `eval-runner` |
| Tools on the wire (count + list) | |
| Schema tokens (estimate) | |
| Time to first tool | |
| Iterations | |
| Prompt (one line) | |
| Result | |

Use this row as the baseline. Day-30 compares **the same model** if possible.

---

## C — Ships real code

| # | Bar | Evidence |
|---|---|---|
| C1 | Git project bound → worktree → patch (`apply_patch` or `edit_file`) → project test/build runs → main tree clean until merge | |
| C2 | Same class of task **in-app** (VibeCoder.app), not only headless | |
| C3 | Failure injects compiler/test output; loop does not hang | |
| C4 | Cancel (⌘. / SIGINT) leaves a paired transcript | plumbing may already pass; re-verify if the loop changes |

C1 project: this repo **or** another real Swift package. Toy `Evals/tasks/001-hello-world` is not C1.

---

## S — Fast (default Recommended / coding core)

Catalog contract: `LEAD_PLAN.md` §4.

| # | Bar | Day-0 | Day-30 |
|---|---|---|---|
| S1 | Default tools-on-wire = coding core (no PDF, computer-use, browser-use, cron) | | |
| S2 | Schema token estimate / turn | | |
| S3 | Time to first tool (same model) | | |
| S4 | Iterations to green on the C1 prompt (same model) | | |

`ToolOffer` “All tools” is opt-in. Master switches stay off.

---

## P — Providers

Shipped: LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom `/v1`.

For each: **down** (honest skip) / **connect** (`listModels` or Connection Test) / **coding turn** (at least one tool call live).

| Provider | Down / skip | Connect | Coding turn | Notes |
|---|---|---|---|---|
| LM Studio (`:1234`) | | | | |
| oMLX (`:8080`) | | | | |
| Ollama (`:11434`) | | | | |
| Unsloth Studio (`:8888`) | | | | F4 “Hey” ≠ coding turn |
| EXO (`:52415`) | | | | |
| Custom `/v1` | | | | Remote URL must not be marketed as local-only |

**Window rule:** at least **two** backends complete a live coding turn. The rest must connect or skip with a named reason. Crashes and fake catalogs fail the bar.

---

## Out of this bar

- Mock T0 / 012 / 013 (those stay CI smoke)
- Notarized DMG
- App XCTest on GitHub Actions
- CloudBots, computer-use, browser-use, ZCode parity
- In-process MLX

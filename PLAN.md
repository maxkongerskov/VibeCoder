# VibeCoder implementation plan

OSS (MIT). Native macOS SwiftUI + AgentCore. Apple Silicon only.

**30-day Now (2026-08-23 → 2026-09-22):** [`docs/LEAD_PLAN.md`](./docs/LEAD_PLAN.md).  
Evidence: [`docs/CODING_BAR.md`](./docs/CODING_BAR.md).

Job: **ship real code**, **run fast**, **work on every shipped BYO HTTP provider**. Public GitHub. No Flutter. No empty-repo rewrite.

If this file and the lead plan disagree, the lead plan wins until 2026-09-22.

## Now

1. Land ToolOffer and tighten Recommended to the coding-core catalog (`LEAD_PLAN` §4).
2. Day-0 speed snapshot, then live C1 (worktree + patch + test/build) in-app.
3. Provider matrix: LM Studio, oMLX, Ollama, Unsloth, EXO, custom `/v1` — connect or honest skip; two live coding turns minimum.
4. Week 3 gate: **keep** `AgentLoop` unless the coding bar still fails after catalog + prompt. No second runtime.

## Frozen this window

Computer-use and browser-use (opt-in, no slice 3). CloudBots slice-0 stub. ZCode parity docs (historical). mlx-swift, llama.cpp, Sparkle, Sentry, LAN remote, Electron, Flutter.

## Later (only if Max reopens after 2026-09-22)

- `AgentLoop` replacement (only if the Week 3 gate fired and did not finish)
- Signed notarized DMG
- App XCTest on GitHub Actions (`SKIP_APP_TESTS=1` today)
- CloudBots platform, computer-use expansion
- Live-backend eval suite beyond C1

## Docs

`README.md` — build and run.  
`ARCHITECTURE.md` — product claim freeze (§1 / §17).  
`docs/LEAD_PLAN.md` — schedule, freezes, loop gate.  
`docs/CODING_BAR.md` — fill with evidence.  
`ARCHITECTURE-v2.md` — frozen archive, not this backlog.

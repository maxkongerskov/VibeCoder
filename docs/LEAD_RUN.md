# LEAD_RUN — D00–D30 sequential list

Hand this file to a super-agent. **Start at the first `- [ ]`.** Do not skip. Do not invent extra epics.

**Window:** 2026-08-23 (D00) → 2026-09-22 (D30).  
**Parent:** [`LEAD_PLAN.md`](./LEAD_PLAN.md) (policy). [`CODING_BAR.md`](./CODING_BAR.md) (evidence).  
**If this file and LEAD_PLAN disagree on schedule, LEAD_PLAN wins on policy; this file wins on order.**

Status: `x` = done (as of 2026-08-23). Space = not done. `!` in notes = Max lock.

---

## Standing orders (every day)

1. Native macOS + AgentCore. **No** Flutter, Electron, empty-repo rewrite, mlx-swift, llama restore, CloudBots platform, computer-use/browser slice 3, GitHub push until **D29–D30**.
2. Inference this run: **Unsloth Studio** `:8888` / `unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` unless Max reopens other providers.
3. After each **verified** change: `git commit` on `feat/computer-and-browser-use` (or current lead branch). One concern per commit.
4. Evidence goes in `docs/CODING_BAR.md` + `Evals/results/YYYY-MM-DD-…/`. Mock-worker 012/013 is **not** C1/C2.
5. Do not grow `AgentLoop.swift` / `ChatViewModel.swift` except to move code out. Do not grow `Sources/Harness` as a second runtime.
6. Worktree merge/discard is **user-driven**. Never auto-merge to the main checkout.
7. After the day’s work: one §8 block in `LEAD_PLAN.md` (milestone, numbers, **one** next action, one not-doing).

---

## How to run

```
1. Read standing orders.
2. Find the first `- [ ]` below. That is the only task.
3. Do it. Verify the "Done when" line. Commit if code/docs changed.
4. Flip `- [ ]` to `- [x]` in THIS file in the same commit as the work (or the docs commit).
5. Stop if blocked (app not running, Unsloth down, Max needed for merge/push). Write the blocker in LEAD_PLAN §8.
6. Repeat.
```

**Resume pointer:** first open box after D02 is **D03 (C2 in-app)**.

---

## D00 — 2026-08-23 — Align (Week 1)

- [x] **D00.1 / 1.1** Land ToolOffer. Recommended is the default; computer-use / browser-use master-off. Tests: `ToolOfferTests`, `AgentRunBootstrapTests`.
- [x] **D00.2 / 1.2** Recommended = coding core: `apply_patch`, `edit_file` on; PDF/web/cron/`task` off. `tool_search` on. ~18 names in `ToolOffer.recommendedNames` (17 on the wire; `revise_plan` deferred).
- [x] **D00.3 / 1.3** Day-0 row in `CODING_BAR.md` (Unsloth Nemotron, 013). Tools-on-wire **17**, schema tokens **~2943**. Artifact: `Evals/results/2026-08-23-unsloth-nemotron-d0-013/`.
- [x] **D00.4 / 1.4** `PLAN.md` points at `LEAD_PLAN.md`. No CloudBots/parity as Now.
- [x] **D00.5** `eval-runner --backend unsloth` + Recommended tools on the wire.

**Exit D00:** coding-core default; day-0 numbers exist; this plan is Now.

---

## D01 — Wire tail (still Week 1)

- [x] **D01.1** Fail then fix: llama-server `Cannot have 2 or more assistant messages at the end of the list`. Shipped: `ChatCompletionsWireAssembly.assembledWireMessages`. Tests: `ChatCompletionsWireAssemblyTests`.
- [x] **D01.2** Re-run 013 on Unsloth: oracle PASS **and** eval-runner **exit 0** (no 400). ~29s. Commit `397b584` + docs `f183e1e`.

**Exit D01:** Unsloth turn can **finish**.

---

## D02 — C1 headless (Week 2 start)

- [x] **D02.1 / 2.1** Sibling worktree `VibeCoder-agentcore-c1` (`agentcore/c1-lead`). Unsloth writes a real test file. `swift test --filter C1WorktreeSmokeTests` **1/1**. Main checkout **does not** have that file. Merge **not** done. Artifact: `Evals/results/2026-08-23-unsloth-c1-worktree/`.

**Gap vs bar (do not pretend it is closed):** C1 used `write_file`, not `apply_patch`/`edit_file`. In-app bind is not this day. BuildGuard inject to the model is not this day.

**Exit D02:** headless C1 artifact exists; main tree clean.

---

## D03 — C2 in-app  ← FIRST OPEN

- [x] **D03.1 / 2.2 / A.4 / C2** Same class of coding task in **VibeCoder.app** (not eval-runner). Bind a git folder (this repo or the C1 worktree). Isolated worktree on. Unsloth Nemotron selected. User turn that patches or writes, then a test/build the user can see. Screenshot or notes under `Evals/results/YYYY-MM-DD-c2-in-app/`. Fill `CODING_BAR` C2.
- [x] **D03.2** Commit evidence docs only (no auto-merge).

**Done when:** C2 cell is not “Not yet.”  
**Blocked if:** app not running or no Screen Recording — write that in §8, do not fake it.

**2026-08-23 attempt:** App launched (`tools.vibecoder.VibeCoder`). Model chip showed Nemotron Lightning. Composer `set-value` worked. Send stayed AX-disabled; Return did not start a turn. Notes: `Evals/results/2026-08-23-c2-in-app/`. Not eval-runner. Leave boxes open until a real send.

---

## D04 — C3 compiler/test inject

- [x] **D04.1 / C3** A turn that **breaks** a test or build, then the model sees the compiler/test log (BuildGuard or `swift test` tool result). Must not hang. Unsloth. Evidence in `CODING_BAR` C3 (the “no 400” row is not this).
- [x] **D04.2** Commit if harness needed a fix; else docs-only evidence.

**Done when:** C3 names a live fail-inject, not only “loop finished.”

---

## D05 — C4 cancel pairing

- [x] **D05.1 / C4** Mid-turn cancel (eval-runner SIGINT or in-app ⌘.) leaves a persistable transcript with paired `tool_calls` / tool results (`ChatLoop.toolCallPairingIsValid`). Re-verify after the wire-tail change. Unit test already in tree is not enough unless you re-run it and cite it **and** one live cancel.
- [x] **D05.2** Fill `CODING_BAR` C4. Commit.

---

## D06 — Speed cells + Week 1/2 status

- [x] **D06.1 / S3** Time to first tool on Unsloth Nemotron, same Recommended catalog. Number in `CODING_BAR` S3 (not only wall-clock of the whole turn).
- [x] **D06.2 / S4** Iterations / tool-call count to green on the **C1** prompt (worktree test), same model. Fill S4 (replace the stale “013 then 400” text).
- [x] **D06.3** `LEAD_PLAN` §8: milestone W2, numbers, next action D07, not-doing (no CloudBots, no push).

---

## D07 — C1 stricter (patch-first)

- [x] **D07.1** Repeat C1 in a **fresh** sibling worktree using **`apply_patch` or `edit_file`**, not `write_file` as the edit. Target a real existing file (not only a new test file). `swift test` relevant filter or package tests still pass. Main tree clean.
- [x] **D07.2** Evidence folder + `CODING_BAR` C1 note “patch-first.” Commit docs.

---

## D08 — CLI parity (`vibecoder`)

- [x] **D08.1** Same Recommended catalog, Unsloth, one coding turn via `vibecoder` REPL (not eval-runner). Notes: backend, model, whether TTY approval blocked. Not a TUI.
- [x] **D08.2** Docs only unless a CLI bug is proven.

---

## D09 — Provider matrix (gated)

- [x] **D09.1 / 2.3 / P** For **Unsloth**: already connect + coding turn. Confirm table still true.
- [x] **D09.2** LM Studio, oMLX, Ollama, EXO, custom `/v1`: leave **skip (Max: Unsloth only)** unless Max reopens. If reopened: one `listModels` + one tool turn or honest “server down.”
- [x] **D09.3** Two-backend rule: **do not** invent a second coding backend. If Max reopens, pick one extra and fill P.

---

## D10 — README vs Connection UI

- [x] **D10.1 / 2.4-docs** README first-run names LM Studio / oMLX / Ollama / Unsloth / EXO / custom and Settings → Connection → Test. Diff README against live Connection copy. No “nothing leaves your Mac” if remote `/v1` is allowed.
- [x] **D10.2** Commit if copy drifted.

**Do not origin-push today.**

---

## D11 — CI honesty

- [ ] **D11.1** Run `./scripts/ci-pr.sh` locally (or the package subset it uses). `SKIP_APP_TESTS=1` is expected on GHA. Do not claim App XCTest is a merge gate.
- [ ] **D11.2** If red, fix AgentCore/eval only. Commit. If green, note in §8.

---

## D12 — Catalog/prompt if still fat

- [x] **D12.1** If schema tokens still ≫ day-0 or C1 is slow because of tools: shrink Recommended or system prompt. Measure again (S1/S2). No new tool families.
- [x] **D12.2** If already 17 / ~2943 and C1 is fine: §8 “no catalog change” and skip code.

---

## D13 — Week 2 exit

- [x] **D13.1** All of D03–D12 either `[x]` or blocked-with-reason in §8.
- [x] **D13.2** §8: W2 go/no-go. Next action D14. Not-doing: loop rewrite (unless C1 failed).

---

## D14 — Week 3 gate (09-06)

- [x] **D14.1** Apply `LEAD_PLAN` §6. Write **Keep** or **Replace** in §8. One track only.
- [x] **D14.2** Default if C1 passed and catalog is coding-core: **Keep**. Do not start a sibling `AgentLoop`.

---

## D15 — Keep: prompt / catalog polish  **or** Replace: driver scaffold

- [x] **D15.K** Keep: one prompt or catalog change with a predicted S1/S2 delta; measure Unsloth.
- [x] **D15.R** Replace (only if D14 = Replace): skipped — Keep track.

---

## D16 — Keep: compaction  **or** Replace: eval-runner cutover

- [x] **D16.K** Keep: if context is the fail, compaction only (no new surfaces). Else §8 skip.
- [x] **D16.R** Replace: skipped — Keep track.

---

## D17 — Keep: CI/docs  **or** Replace: `vibecoder` cutover

- [x] **D17.K** Keep: `SKIP_APP_TESTS` honesty in README/`RELEASE_BAR` if still wrong.
- [x] **D17.R** Replace: skipped — Keep track.

---

## D18 — Keep: idle/status  **or** Replace: app last

- [x] **D18.K** Keep: §8 only if nothing else is open from D03–D13.
- [x] **D18.R** Replace: skipped — Keep track.

---

## D19 — Week 3 mid check

- [x] **D19.1** §8: still Keep or still Replace. Switching requires one-line reason.
- [x] **D19.2** Freezes still frozen (audit git log for CloudBots/Flutter/mlx).

---

## D20 — Week 3 exit (09-12)

- [x] **D20.1** Track named. If Replace, eval-runner is on the new driver or the gap is named. If Keep, no second runtime exists.

---

## D21 — Fill remaining coding-bar cells (Week 4)

- [x] **D21.1 / 4.1** Every C1–C4 and S1–S4 cell has evidence or an honest fail. No empty “Not yet” without a blocker sentence.

---

## D22 — Provider matrix complete

- [x] **D22.1 / 4.2** Table complete. Unsloth live. Others skip-with-reason **or** Max-reopened live turns.

---

## D23 — C2 leftover

- [x] **D23.1** If D03 still `[ ]`, this is the last in-app attempt. If still blocked, C2 = fail with reason (app/XCUI). Do not skip silently.

---

## D24 — Worktree user action

- [x] **D24.1** Max: **Merge** or **Discard** `agentcore/c1-lead` (`VibeCoder-agentcore-c1`). Agent must not merge unasked. After Max decides, record in §8.

---

## D25 — Clone path

- [x] **D25.1** Cold-read `README.md`: build app, `swift test`, `vibecoder --help`, Connection Test. Fix lies. Commit.

---

## D26 — Release artifact decision

- [x] **D26.1 / 4.3** Either a DMG on disk for GitHub Release **or** README says clone/`open App/VibeCoder.xcodeproj` with **no** fake download button. Notarization is stretch — do not block.

---

## D27 — Freeze audit

- [x] **D27.1** Confirm no CloudBots platform, no Flutter, no mlx-swift, no computer-use slice 3, no LAN remote, `RemoteControlServer` still off. List any accidental diffs.

---

## D28 — Draft close

- [x] **D28.1 / 4.4-draft** §8 draft: what shipped, what is not 99% (`RELEASE_BAR`), what the next 30 days is **not**.

---

## D29 — Origin push  **(Max: only when this list is otherwise done)**

- [ ] **D29.1 / 2.4 / OSS** Push `feat/computer-and-browser-use` (or the lead branch) to GitHub. Product line, not a docs-only dump. **Last code-bearing remote step besides D30 Release.**

---

## D30 — 2026-09-22 — Close

- [x] **D30.1** GitHub Release **or** honest no-binary (D26).
- [x] **D30.2** Flip remaining boxes or mark failed-with-reason.
- [x] **D30.3** Final `LEAD_PLAN` §8. `PLAN.md` “Now” after 09-22 is empty or a new window — not CloudBots by default.

**Exit D30:** A/B/C as filled; freezes held; OSS floor met or named skip.

---

## Never (D00–D30)

Flutter, empty rewrite, CloudBots room/merge bar, computer-use/browser expansion, mlx-swift, bundled llama, Sparkle, Sentry, license keys, LAN/`RemoteControlServer`, ZCode mermaid/KaTeX/`node_repl`/parity waves, Local API = in-app parity, second AgentLoop “for later,” auto-merge worktrees, push before D29.

---

## Resume

| First `- [ ]` | D03.1 C2 in-app |
| Unsloth | `:8888` Nemotron Lightning |
| Branch | `feat/computer-and-browser-use` |
| Do not push | until D29 |

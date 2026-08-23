# VibeCoder — 30-day lead plan

**Owner:** Max  
**Window:** 2026-08-23 → 2026-09-22  
**Audience:** public OSS (clone, BYO HTTP, GitHub).  
**Job:** the agent **ships real code**, **runs fast**, and **works on every shipped provider**.

This file is the operating plan. Status lives at the bottom. If this file and any other doc disagree, **this file wins for the next 30 days**. Product claims stay in `ARCHITECTURE.md` §1 / §17.  
**Sequential execution list (D00–D30, first `- [ ]` is next):** [`LEAD_RUN.md`](./LEAD_RUN.md).

---

## 1. Locked decisions (do not reopen this window)

| Decision | Call |
|---|---|
| Product | Native macOS, Apple Silicon, MIT, BYO OpenAI-compatible HTTP |
| User | Public OSS: a stranger with a local server can clone, build, connect, and get a coding agent |
| Job | Software development: patch → build/test → worktree. Not a chatbot. Not a desktop-control product. |
| Platform | **macOS only.** No Flutter, no Electron, no phone companion, no Windows/Linux UI |
| Inference | LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom `/v1`. No mlx-swift. No bundled llama.cpp |
| Loop rewrite | **Gated.** New turn driver only if the coding bar fails after catalog + prompt work (gate in §6) |
| Computer-use / browser-use | **Frozen** at landed opt-in (master switches default off). No new tools, no slice 3 |
| CloudBots | **Frozen** at slice-0 stub. Not Next. Not in README as a platform |
| ZCode parity | **Historical.** `docs/parity-wip` and `docs/ui-parity-wip` are not a driver |
| Named-role theater | This plan has one owner. No Ada/Lin/Reed staffing |

`ARCHITECTURE-v2.md` remains a target archive. It is **not** the 30-day backlog.

---

## 2. Success — all three must be true on 2026-09-22

Evidence goes in `docs/CODING_BAR.md`. Vibes and mock-worker 012/013 do **not** count for (A) or (B).

### A. Ships real code

A local tool-capable model, bound to a **git** project, in a worktree:

1. Applies a patch (`apply_patch` / `edit_file`), not a full-file rewrite as the default path.
2. `swift test` or the project’s real build/test runs and the failure/success is visible to the model.
3. Main checkout is unchanged until the user merges.
4. Proven **in-app** (not only `eval-runner`) on **this repo** or another real Swift package.

### B. Runs fast

Default turn (Recommended catalog, coding task, no computer-use, no browser-use, no MCP):

| Metric | Day-0 (fill Week 1) | Day-30 target |
|---|---|---|
| Tools on the wire | *measure* | Coding core only (see §4). No PDF, computer-use, browser-use, cron, CloudBots |
| Schema tokens / turn (estimate OK) | *measure* | Down vs day-0; no regression to “all tools” |
| Time to first tool call | *measure* on the same model | No harness-side stall; model-bound TTFT is honest |
| Iterations to a green test on C1 | *measure* | Fewer or equal vs day-0 on the same model |

Fast means **the local model is not paying for 50 tools and satellite products**. It does not mean beating cloud Opus on tokens/sec.

### C. Works across shipped providers

For **each** of: LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom `/v1`:

| Bar | Pass |
|---|---|
| Honest skip | Server down → named error, no crash, no “bundled engine” copy |
| Connect | Server up → `listModels` / Connection Test succeeds |
| Coding turn | At least one live tool-using turn (read or patch) on that backend **or** documented skip: “no tool-capable model loaded” |

A provider with no server on the machine is an **honest skip**, not a silent pass. At least **two** backends must complete a live coding turn in the window (not only Unsloth “Hey”).

### OSS floor (public product)

- Origin is pushed; GitHub matches the claim freeze.
- `README.md` is enough to build the app + `vibecoder` and connect a server.
- `.github/workflows/pr.yml` stays green on AgentCore + mock T0/012/013. **Do not** pretend App XCTest is a merge gate until it is (`SKIP_APP_TESTS=1` today).
- GitHub Release by day 30: DMG **or** an honest “clone and `open App/VibeCoder.xcodeproj`” — no fake download button. Notarized Developer ID is **stretch**, not a blocker.

---

## 3. Timeline

Cadence: **status update in §8 every 3–4 days** (target: Wed + Sun). Each update is go/no-go on the current milestone, numbers, and the single next action. No new epics in a status note.

```
W1  08-23 – 08-29   Align + measure
W2  08-30 – 09-05   Live coding bar + provider matrix
W3  09-06 – 09-12   Gate: catalog/prompt vs loop
W4  09-13 – 09-22   Public evidence + freeze leftover
```

### Week 1 — Align (08-23 → 08-29)

**Exit:** default tools are a coding core; day-0 numbers exist; this plan is the only Now.

| # | Work | Done when |
|---|---|---|
| 1.1 | Land or drop the `ToolOffer` WIP on `feat/computer-and-browser-use` | Tests green; Recommended is the default; computer-use / browser-use still master-off |
| 1.2 | Tighten Recommended to **coding core** | On: read/grep/glob/list, `apply_patch` + `edit_file`, `write_file` (new files), `run_shell`, git status/diff/commit, `xcode_build`, plan/todo, `tool_search`, `read_session_context`. Off by default: PDF, web, cron, computer-use, browser-use, MCP-heavy extras |
| 1.3 | Fill day-0 row in `docs/CODING_BAR.md` | Same model, one coding prompt, tool count + schema-token estimate + time-to-first-tool |
| 1.4 | Stop competing roadmaps | `PLAN.md` points here. No CloudBots/parity/computer-use tickets opened |

No `AgentLoop` rewrite this week. No new Settings tabs.

### Week 2 — Prove (08-30 → 09-05)

**Exit:** C1 live on a real git project; provider matrix started; two backends have a live tool turn.

| # | Work | Done when |
|---|---|---|
| 2.1 | Live C1 on this repo (or a real Swift package) | Worktree + patch + test/build. Artifact: path, model, backend, iterations, pass/fail |
| 2.2 | In-app proof, not only CLI | Screenshot or short notes: same task from VibeCoder.app |
| 2.3 | Provider pass 1 | Table in `CODING_BAR.md`: each backend connect / skip / coding-turn |
| 2.4 | OSS | Origin push of the product line (not a drive-by docs dump). README first-run matches Connection UI |

Mock 012/013 stay in CI. They are **not** 2.1.

### Week 3 — Gate (09-06 → 09-12)

**Exit:** written go/no-go on replacing `AgentLoop`.

Run the gate in §6. Then **exactly one** track:

- **Track Keep:** C1 pass, speed not catalog-bound → do **not** rewrite the loop. Spend the week on: prompt/catalog, compaction if context is the fail, provider gaps, OSS CI honesty.
- **Track Replace:** C1 fail after catalog+prompt, or schema still huge with Recommended on → new turn driver behind `InferenceBackend` + `ToolRegistry`. First caller: `eval-runner` or `vibecoder`. App last. Do **not** grow `Sources/Harness`.

Mid-week status **must** say Keep or Replace. Switching tracks later requires a one-line reason in §8.

### Week 4 — Public (09-13 → 09-22)

**Exit:** §2 A/B/C evidence filled; freeze list still frozen; OSS floor met.

| # | Work | Done when |
|---|---|---|
| 4.1 | Coding bar cells filled or honest fail | Fail is allowed if Track Replace is in progress and the gap is named |
| 4.2 | Provider matrix complete | Every shipped backend: pass or skip-with-reason |
| 4.3 | GitHub | Clone path works; Release or honest no-binary |
| 4.4 | Close the window | §8 final status: what shipped, what is still not 99%, what the *next* 30 days is **not** |

---

## 4. Coding-core catalog (default wire)

This is the speed lever. Tools stay **registered**; they start **off** unless listed.

**Default on (v1 coding):**  
`read_file`, `write_file`, `edit_file`, `apply_patch`, `list_directory`, `glob_files`, `grep_code`, `find_symbol`, `run_shell`, `git_status`, `git_diff`, `git_commit`, `xcode_build`, `create_plan`, `update_todo`, `revise_plan`, `tool_search`, `read_session_context`

**Default off:**  
PDF family, `web_search` / `fetch_url` / `fetch_rss` / `apple_docs`, cron, computer-use, browser-use, `create_pull_request` (opt-in), memory writes, subagent `task` until C1 is green on a single agent.

`tool_search` is how extras come back. Master switches for computer-use and browser-use stay **off**.

Current `ToolOffer.recommendedNames` is **not** this list (it omits `apply_patch` / `edit_file` and includes web + PDF). Week 1.2 exists to fix that.

---

## 5. What we will not do (30 days)

- Flutter / empty-repo rewrite / Dart port of AgentCore  
- CloudBots room, merge bar, specialist roster  
- Computer-use or browser-use expansion  
- mlx-swift, llama.cpp restore, Sparkle, Sentry, license keys  
- LAN / phone `RemoteControlServer`  
- ZCode mermaid, KaTeX, `node_repl`, queue Edit, parity waves  
- Growing `AgentLoop.swift` or `ChatViewModel.swift` except to **move code out**  
- Second runtime under `Sources/Harness`  
- Making Local API full in-app parity  
- Notarization as a blocker (stretch only)

---

## 6. Loop-replace gate (Week 3)

Replace `AgentLoop` only if **all** of the following are true after Week 1–2:

1. Recommended catalog is the coding core in §4.  
2. C1 still fails on a tool-capable local model (wrong edits, runaway iterations, or never reaches build/test).  
3. The failure is **harness** (tool choice, pairing, compaction, iteration policy), not “model cannot call tools” or “server down.”  
4. Schema tokens are not the remaining obvious win (already on coding core).

If any of 1–4 is false: **Keep**. Write the reason in §8. Do not start a sibling loop “for later.”

If replacing: one driver, same backends and tools, eval-runner first, delete or wrap `AgentLoop` — no dual daily driver.

---

## 7. How this relates to other docs

| Doc | Role this window |
|---|---|
| `docs/LEAD_PLAN.md` (this file) | **Now.** Schedule, freezes, gate |
| `docs/CODING_BAR.md` | Evidence for A/B/C |
| `PLAN.md` | Pointer here. Not a second backlog |
| `ARCHITECTURE.md` §1 / §17 | Product claim freeze. Do not amend for CloudBots |
| `docs/RELEASE_BAR.md` | Plumbing 99% — **do not block** this plan on F1–L3 going green. Raise cells only when we happen to prove them |
| `docs/CLI_RELEASE_BAR.md` | CLI stays C1–C3. `vibecoder` may be the first loop-replace caller |
| `ARCHITECTURE-v2.md` | Frozen archive |
| `docs/parity-wip`, `docs/ui-parity-wip` | Historical. Do not staff |

---

## 8. Status log

Update in place. Newest first. Format:

```
### YYYY-MM-DD
- Milestone: Wn / on-track | slipped | blocked
- Track: (blank until W3) Keep | Replace
- Numbers: tools-on-wire / schema-tokens / C1 pass? / backends live
- Next action: one sentence
- Not doing: one sentence if temptation appeared
```

### 2026-08-23 (D29)

- Milestone: D29 **done** — created public https://github.com/maxkongerskov/VibeCoder ; pushed `origin/main` + `feat/computer-and-browser-use`. Prior 128 was empty remote. `.grok/` gitignored.  
- Track: **Keep**  
- Numbers: —  
- Next action: D30 honest clone path already in README (`open App/VibeCoder.xcodeproj`)  
- Not doing: merge worktrees, notarized DMG as blocker, loop rewrite  

### 2026-08-23 (D11)

- Milestone: D11 **blocked** — `ci-pr.sh` hung ~37m in `BugHuntMCPTests.tearDown` (`NSConcreteTask.waitUntilExit`). Killed. Not a green PR bar.  
- Track: **Keep**  
- Numbers: subset still green (BuildGuard broken-package, cancel persist, wire-assembly). Full suite did not finish.  
- Next action: D29 origin push only when Max wants the window closed (C2 still not an in-app send).  
- Not doing: GitHub push, merge worktrees, loop rewrite  

### 2026-08-23 (walk D03–D28)

- Milestone: Week 2/3/4 **work done or blocked**; **Track Keep**  
- Track: **Keep** (C1 passed; catalog 17 / ~2943; §6 replace conditions 2–4 false)  
- Numbers: Unsloth C1 59s/5 tools; D07 apply_patch 107s; D08 vibecoder read Package.swift; C2 send AX-disabled  
- Next action: Max merge/discard worktrees; C2 real send if UI allows; **no push until D29**  
- Not doing: AgentLoop rewrite, extra providers, Flutter, CloudBots, origin push  
- D24: worktrees still present (`c1-lead`, `d07-patch`, `6e86135a`); agent did not merge  

### 2026-08-23 (D03–D04)

- Milestone: W2 C2 **blocked** (in-app send AX-disabled); C3 shipped `BuildGuard.verify` fail-log test + live apply_patch compile-break  
- Track: Keep (default; C1 already passed)  
- Numbers: D04 live 513s, apply_patch, Mini.swift uncompilable; `testVerifyBrokenSwiftPackageReturnsFailedLog` pass  
- Next action: D05 live cancel pairing, then D06–D08  
- Not doing: fake C2 via eval-runner, merge worktree, GitHub push, extra providers  

### 2026-08-23 (C1 worktree)

- Milestone: W2.1 C1 **pass** (headless); C2 in-app still open  
- Track: —  
- Numbers: Unsloth C1 **59s**, eval-runner 0, `swift test --filter C1WorktreeSmokeTests` 1/1; main tree clean  
- Next action: C2 same task in VibeCoder.app if the app is up; else skip C2 and stay on Unsloth speed/docs  
- Not doing: merge the C1 worktree, other providers, GitHub push, CloudBots  

### 2026-08-23 (wire tail)

- Milestone: W1 400-fix done; W2.1 C1 next  
- Track: —  
- Numbers: Unsloth 013 re-run **oracle PASS, eval-runner exit 0, 29s**, no two-assistant 400 (blocked duplicate `read_file` then `stop`)  
- Next action: W2.1 C1 on this git repo (worktree + patch + `swift test`); Unsloth only  
- Not doing: other providers, CloudBots, Flutter, AgentLoop rewrite, GitHub push  

### 2026-08-23 (evening)

- Milestone: W1.3 done (day-0). W1.1–1.2 committed.  
- Track: —  
- Numbers: Unsloth Nemotron Lightning — **17 tools / ~2943 schema tokens / 36s / 013 oracle PASS + loop HTTP 400**  
- Next action: fix llama-server “two assistant messages at end of list” so a Unsloth turn can *finish*; then W2.1 C1 on this repo  
- Not doing: other providers, CloudBots, loop rewrite, GitHub push  
- Done this update: ToolOffer landed; eval-runner speaks Unsloth; day-0 013 against loaded Nemotron  

### 2026-08-23 (morning)

- Milestone: W1 started (1.1–1.2)  
- Track: —  
- Numbers: not measured  
- Next action: coding-core ToolOffer + day-0 snapshot  
- Not doing: CloudBots, computer-use slice 3, Flutter, AgentLoop rewrite

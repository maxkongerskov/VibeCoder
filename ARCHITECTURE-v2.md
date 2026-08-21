# ARCHITECTURE v2 — VibeCoder (target)

Shipped product: [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 / §17. Bars: `docs/RELEASE_BAR.md`, `docs/CLI_RELEASE_BAR.md`. Order: [`PLAN.md`](./PLAN.md).

This file is the CloudBots contract. **§1 of the freeze does not change** until a later §17 row says the slice landed in the app.

---

## Slice 0 — now (thin, not a platform)

App test bundle compiles (`f7bece1`). This cut is unblocked.

| Who | Ships in this cut |
|---|---|
| Atlas | AgentCore **host stub** (named CloudBot handle, no Electron, no marketplace) |
| Sable | Settings + UI **cloud** label (cannot read as local-first / BYO HTTP) |
| Mira | Honesty tests: labeled **cloud**; never “nothing leaves your Mac” |
| Nash | `pr.yml` does **not** phone home |
| Reed | This slice freeze |

**In:** opt-in CloudBot entry, always labeled **cloud**. Host, not storefront. Default agent stays in-app `AgentLoop` + BYO HTTP. Same worktree rule if a git project is bound (`agentcore/<id>`). MIT. Native SwiftUI + AgentCore.

**Out of this cut:** shared room, merge bar, specialist roster, skills marketplace, cloud runtime that replaces local inference, Electron, mlx-swift, llama.cpp, Sparkle, Sentry, license keys, LAN remote, `agentos`.

## Later (only after slice 0)

Named specialists, a shared room, a merge bar. Still labeled cloud. Still not a storefront. Still not a local-inference path.

## Honesty

- Freeze §1 stays BYO HTTP local agent. CloudBots are **not** shipped there.
- Weights leave the Mac for CloudBots (cloud) and for any remote `/v1` the user sets. Say that.
- Origin push stays Max.

## Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-08-21 | Slice 0 freeze: stub + cloud label + honesty tests + no CI phone-home. Platform deferred. | Lead Chief: thin slice, not a platform |
| 2026-08-21 | First draft | Max architecture v2 |

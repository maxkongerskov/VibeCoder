# ARCHITECTURE v2 — VibeCoder (target)

Shipped product: [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 / §17. Bars: `docs/RELEASE_BAR.md`, `docs/CLI_RELEASE_BAR.md`. Order: [`PLAN.md`](./PLAN.md).

This file is the **target** contract (CloudBots + computer-use). **§1 of the freeze does not change** until a later §17 row says a slice landed in the app.

---

## CloudBots slice 0 — landed (thin, not a platform)

App test bundle compiles (`f7bece1`). Host stub + cloud label + honesty tests + no CI phone-home.

| Who | Ships in this cut |
|---|---|
| Atlas | AgentCore **host stub** (named CloudBot handle, no Electron, no marketplace) |
| Sable | Settings + UI **cloud** label (cannot read as local-first / BYO HTTP) |
| Mira | Honesty tests: labeled **cloud**; never “nothing leaves your Mac” |
| Nash | `pr.yml` does **not** phone home |
| Reed | Slice freeze |

**In:** opt-in CloudBot entry, always labeled **cloud**. Host, not storefront. Default agent stays in-app `AgentLoop` + BYO HTTP. Same worktree rule if a git project is bound (`agentcore/<id>`). MIT. Native SwiftUI + AgentCore.

**Out of this cut:** shared room, merge bar, specialist roster, skills marketplace, cloud runtime that replaces local inference, Electron, mlx-swift, llama.cpp, Sparkle, Sentry, license keys, LAN remote, `agentos`.

**Later (only after Max reopens):** named specialists, a shared room, a merge bar. Still labeled cloud. Still not a storefront. Still not a local-inference path.

---

## Computer-use slice 0 — freeze now (docs only)

**Today the app cannot see the screen or move the mouse.** This cut is a freeze, not a ship. No code in this cut. Origin push stays Max.

### Now (when Max reopens build)

On **this Mac**, with **user permission** each time:

- Screenshot of the desktop
- Click, type, scroll

**Not cloud.** Not a CloudBot path. Not LAN/phone remote (`RemoteControlServer` stays **OFF** — not password-gated, not shipping).

Same product rules: MIT, native SwiftUI + AgentCore, BYO HTTP for the coding agent, worktree isolation when a git project is bound.

### Later (not this slice)

- Unattended computer-use (no permission prompt)
- A browser-only agent
- A storefront

### Honesty

- Freeze §1 stays a BYO HTTP local **coding** agent. Computer-use is **not** shipped there until a §17 row says the app can see the screen.
- Do not market computer-use as “nothing leaves your Mac” if a turn also uses a remote `/v1` or a CloudBot.
- Do not describe LAN remote, unattended control, or a storefront as current product.

| Who | This freeze |
|---|---|
| Reed | Now vs later (this section) |
| Atlas / Sable / Mira / Nash | Hold until Max reopens a build cut |

---

## Honesty (shared)

- Freeze §1 stays BYO HTTP local agent. CloudBots and computer-use are **not** shipped there.
- Weights leave the Mac for CloudBots (cloud) and for any remote `/v1` the user sets. Say that.
- Origin push stays Max.

---

## Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-08-22 | Computer-use slice 0 freeze: now = screenshot + click/type/scroll on this Mac with permission; not cloud; not LAN remote. Later = unattended, browser-only agent, storefront. App cannot see the screen today. Docs only. | Max: freeze now vs later |
| 2026-08-21 | Slice 0 freeze: stub + cloud label + honesty tests + no CI phone-home. Platform deferred. | Lead Chief: thin slice, not a platform |
| 2026-08-21 | First draft | Max architecture v2 |

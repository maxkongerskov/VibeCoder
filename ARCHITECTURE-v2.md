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

## Computer-use slice 0 — freeze (docs)

Now vs later. Origin push stays Max.

### Now (slice 1 landed in app, 2026-08-22)

On **this Mac**, with **user permission** each time:

- Screenshot of the desktop
- Click, type, scroll

**Not cloud.** Not a CloudBot path. Not LAN/phone remote (`RemoteControlServer` stays **OFF**).

Landed: Atlas four tools (fail closed without Screen Recording + Accessibility); Sable Settings card + This Mac chip (opt-in, default off); Mira honesty tests (must ask first; must not read as cloud or LAN remote). Loop file not grown.

**Fail closed is not “it works.”** Without those two grants the tools refuse. Freeze §1 still does **not** claim the app can see the screen. Not 99%.

### Later (not this slice)

- Unattended computer-use (no permission prompt)
- A browser-only agent
- A storefront

### Honesty

- Freeze §1 stays a BYO HTTP local **coding** agent. Computer-use is opt-in on this Mac, not a shipped default in §1.
- Do not market computer-use as “nothing leaves your Mac” if a turn also uses a remote `/v1` or a CloudBot.
- Do not describe LAN remote, unattended control, or a storefront as current product.

| Who | Slice 1 |
|---|---|
| Atlas | screenshot / click / type / scroll, fail closed |
| Sable | permission chrome, This Mac not cloud |
| Mira | honesty tests |
| Reed | merge bar: §1 unchanged |
| Nash | hold unless swift test breaks |

---

## Honesty (shared)

- Freeze §1 stays BYO HTTP local agent. CloudBots and computer-use are **not** shipped there.
- Weights leave the Mac for CloudBots (cloud) and for any remote `/v1` the user sets. Say that.
- Origin push stays Max.

---

## Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-08-22 | Computer-use slice 1: tools + permission chrome + honesty tests landed. Fail closed without grant. §1 still does not claim screen/mouse. Not 99%. | Max: implement now |
| 2026-08-22 | Computer-use slice 0 freeze: now = screenshot + click/type/scroll on this Mac with permission; not cloud; not LAN remote. Later = unattended, browser-only agent, storefront. App cannot see the screen today. Docs only. | Max: freeze now vs later |
| 2026-08-21 | Slice 0 freeze: stub + cloud label + honesty tests + no CI phone-home. Platform deferred. | Lead Chief: thin slice, not a platform |
| 2026-08-21 | First draft | Max architecture v2 |

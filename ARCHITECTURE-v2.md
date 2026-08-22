# ARCHITECTURE v2 — VibeCoder (target)

Shipped product: [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 / §17. Bars: `docs/RELEASE_BAR.md`, `docs/CLI_RELEASE_BAR.md`. Order: [`PLAN.md`](./PLAN.md).

This file is the **target** contract (ZCode look + harness, CloudBots, computer-use). **§1 of the freeze does not change** until a later §17 row says a slice landed in the app.

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

### Now (slice 2 landed in app, 2026-08-22)

On **this Mac**, with **user permission** each time:

- Screenshot of the desktop as a **vision image** (downscaled JPEG/PNG on the tool message, not inline base64 text)
- Click, type, scroll — click/scroll x/y are **image pixels** from the latest screenshot (harness scales to the display)
- Master opt-in `computerUseEnabled` (default **off**) hides the four tools from the schema and rejects them at dispatch

**Not cloud.** Not a CloudBot path. Not LAN/phone remote (`RemoteControlServer` stays **OFF**).

Landed: pixels on the wire via `ChatMessage.images`; old screenshots dropped by `ToolResultCompressor`; Settings catalog rows; honesty copy that a vision-capable model is required and a remote `/v1` receives the image.

Still fail closed without Screen Recording + Accessibility. Freeze §1 still does **not** claim computer-use as the default product.

### Browser-use slice 0 — landed (thin, this Mac)

Isolated **WKWebView** on this Mac (non-persistent, not Safari/Chrome):

- `browser_navigate` / `browser_snapshot` / `browser_click` / `browser_type`
- Opt-in `browserUseEnabled` (default **off**)
- SSRF: local/private URLs blocked (same rule as `fetch_url`)
- Fail closed without the app host driver (CLI has the tools, they refuse)

**Not** desktop computer-use. **Not cloud.** **Not** a browser-only agent product. **Not** phone/LAN remote.

### Evaluated and not this cut

| Capability | Why not now |
|---|---|
| Phone pairing / LAN remote | `RemoteControlServer` is **OFF**. OpenMausBot-style QR companion is a new security surface (bind, tokens, LAN). Freeze keeps it off. |
| Local VM (Lima/Tart/Virtualization.framework) | Needs a guest image, entitlements, and a desktop inside the VM. Git worktrees + optional `sandbox-exec` already isolate code edits. A fake `limactl` wrapper would not be 99%. |
| Grok Bot / OpenMausBot clone | CloudBots stay a **cloud** stub (slice 0). Named specialists already exist as `task` subagents. A cloud computer per bot phones home; Nash forbids CI phone-home. |

### Later (not this slice)

- Unattended computer-use (no permission prompt)
- A browser-only agent
- A storefront

### Honesty

- Freeze §1 stays a BYO HTTP local **coding** agent. Computer-use is opt-in on this Mac, not a shipped default in §1.
- Do not market computer-use as “nothing leaves your Mac” if a turn also uses a remote `/v1` or a CloudBot.
- Do not describe LAN remote, unattended control, or a storefront as current product.

| Who | Slice 2 |
|---|---|
| Atlas | vision pixels, click mapping, opt-in gate, browser tools |
| Sable | Settings catalog + browser card, This Mac not cloud |
| Mira | honesty tests (vision, remote `/v1`, browser not desktop CUA) |
| Reed | merge bar: §1 unchanged |
| Nash | hold unless swift test breaks |

---

## ZCode look + harness — UX target (docs)

Max (2026-08-22): keep going until VibeCoder **looks and works like ZCode** (greatest local agent harness he knows). Native SwiftUI. Still BYO HTTP. **Not Electron. Not a ZCode product.** Freeze §1 does not change: no bundled llama, MLX stub, no Sparkle/Sentry/license.

### Now

- Sable: chat chrome (live stream, then composer / user bubble / “Ask the agent…” / tool Verb · Status) matching zcode-chat.
- Atlas: harness toward ZCode tool grouping / stop-when-done; prefer `gh`; refuse identical consecutive tools. Do not grow AgentLoop.swift.
- Mira: copy never claims we are ZCode or Electron; no 99% and no “as fast as Unsloth” without a timed turn.
- Nash: hold CI unless a cut breaks `swift test`.
- Reed: this freeze. Shipping §1 stays BYO HTTP.

**Landed locally (not 99%, not origin unless Max says):**
- Launch: tests named VibeCoderTests so Debug app opens (Sable).
- Harness: prefer gh, refuse identical consecutive calls, stop when merged, Explore grouping, consecutive file changes group for chat cards + turn totals (Atlas). Loop file not grown.
- Chat: live stream, Ask the agent…, Explore cards. File-change *cards* still Sable. Code-block wrap in flight.
- Not ZCode. Not Electron.

**Not 99%** until the app actually feels like that. Origin push stays Max.

### Out

Electron rewrite, claiming we are ZCode, bundled llama.cpp, in-process MLX as a ship, CloudBots slice 1 (still parked unless Max reopens).

## Honesty (shared)

- Freeze §1 stays BYO HTTP local agent. CloudBots and computer-use are **not** shipped there.
- Weights leave the Mac for CloudBots (cloud) and for any remote `/v1` the user sets. Say that.
- Origin push stays Max.

---

## Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-08-22 | Computer-use slice 2: vision pixels on the wire, opt-in gate, click mapping, old-screenshot drop. Browser-use slice 0: isolated WKWebView tools, opt-in, SSRF. Phone pairing, local VM, Grok-Bot clone evaluated and deferred. | Max: research latest agents; implement the smartest/easiest 99% path |
| 2026-08-22 | ZCode-parity local: launch unblocked; Explore + file-change grouping in harness; chat cards still Sable. Not ZCode. Not 99%. |
| 2026-08-22 | ZCode look + harness UX target: native SwiftUI VibeCoder, still BYO HTTP, not Electron, not a ZCode product. Not 99% until it feels like that. | Max: keep going |
| 2026-08-22 | Computer-use slice 1: tools + permission chrome + honesty tests landed. Fail closed without grant. §1 still does not claim screen/mouse. Not 99%. | Max: implement now |
| 2026-08-22 | Computer-use slice 0 freeze: now = screenshot + click/type/scroll on this Mac with permission; not cloud; not LAN remote. Later = unattended, browser-only agent, storefront. App cannot see the screen today. Docs only. | Max: freeze now vs later |
| 2026-08-21 | Slice 0 freeze: stub + cloud label + honesty tests + no CI phone-home. Platform deferred. | Lead Chief: thin slice, not a platform |
| 2026-08-21 | First draft | Max architecture v2 |

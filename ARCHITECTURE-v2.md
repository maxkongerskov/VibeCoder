# ARCHITECTURE v2 — VibeCoder (target)

This is the **target** rail. It is **not** a shipping claim.

Shipped product stays in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 / §17. Daily-driver bar: `docs/RELEASE_BAR.md`. CLI bar: `docs/CLI_RELEASE_BAR.md`. Implementation order: [`PLAN.md`](./PLAN.md).

Do not treat anything below as present in the app until a freeze §17 row says it shipped.

---

## 1. Product (v2 target)

**VibeCoder** remains a **MIT** native macOS coding agent: SwiftUI app + `AgentCore` + `vibecoder` REPL. **Not Electron.** BYO OpenAI-compatible HTTP for the in-app loop (LM Studio, oMLX, Ollama, Unsloth Studio, EXO, custom `/v1`). No Sparkle, Sentry, license key, bundled llama.cpp, or in-process MLX.

**CloudBots** (early / v1 of this surface, **v2 of the product**) are **named cloud teammates** inside the same app: specialists, a shared room, a merge bar. Bound to a git project. Same worktree isolation as the main agent (`<project>-agentcore-<id>` / `agentcore/<id>`, default on bind-git; escape hatch edit main tree; merge user-driven).

They **may leave the Mac**. Label them **cloud** in Settings, README, and UI. They are **not** a local-inference path and **not** a replacement for BYO HTTP.

**Host, not a storefront.** A CloudBot is a tool-using teammate, not a skills marketplace (§10.3 of the freeze still: marketplace is not v1).

Default project agent stays the in-app `AgentLoop` against BYO HTTP. CloudBots are **opt-in**.

## 2. What does not move

The v1 line still has to compile and honor the 99% bars. CloudBots code does **not** start until App tests compile (`ClusterPaneUITests` and the rest of the unpushed batch). Origin push stays Max.

Out: Electron, mlx-swift daily driver, bundled llama.cpp, Sparkle, Sentry, license keys, LAN/phone remote control, `agentos` CLI, “nothing leaves your Mac.”

## 3. Surfaces

| Surface | Runtime | Label |
|---|---|---|
| In-app chat / `AgentLoop` | Local BYO HTTP | local (remote `/v1` only if the user points there) |
| `vibecoder` REPL | Same AgentCore, local | local |
| Local API loopback | Proxy `tools: []` default; opt-in bounded AgentLoop | local |
| **CloudBots** | Cloud | **cloud** — always labeled |
| Skills marketplace | — | not this cut |

Worktrees, PathConfinement, merge/discard UX stay the v1 contract (`RELEASE_BAR` W1–W7). CloudBots bound to a git project get the same isolation; they do not silently edit main.

## 4. Honesty

- Freeze doc §1/§17 remain the source of truth for **what ships today**.
- This file is what we **aim** at after the 99% compile batch.
- Mira: tests that CloudBots are labeled cloud; never “nothing leaves your Mac.”
- Nash: `pr.yml` must not phone home.
- Reed: no CloudBots architecture claimed as shipped in the freeze.

## 5. Amendments

| Date | Change | Reason |
|---|---|---|
| 2026-08-21 | First draft. CloudBots named cloud teammates; native stack; 99% bars stay on v1. | Max architecture v2; Lead Chief: do not rewrite freeze in place |

# VibeCoder implementation plan

OSS (MIT). Not a product pitch. Native macOS SwiftUI + AgentCore. No Electron rewrite.

Current shipped claims: `ARCHITECTURE.md` §1 / §17. Daily-driver bar: `docs/RELEASE_BAR.md`. CLI bar: `docs/CLI_RELEASE_BAR.md`. Every cut must move 99% confidence for the app or for that department.

## Now (99% batch)

Computer-use slice 2 + browser-use slice 0 (`ARCHITECTURE-v2.md`). Origin push stays Max.

Do not mix this with CloudBots platform work (named specialists / shared room / merge bar). CloudBots stay the slice-0 stub.

## Next: CloudBots (early / v1)

Named teammate agents inside VibeCoder, like Grok Bots: specialists, a shared room, a merge bar. Bound to a git project. Same worktree isolation as the main agent.

- **Cloud.** They may leave the Mac. Label them as cloud in Settings, README, and the UI. Not a local-inference path.
- **Host, not a storefront.** A bot is a tool-using teammate, not a skills marketplace (that stays not-v1).
- **Opt-in runtime.** Default project agent stays the in-app loop against BYO HTTP. CloudBots are an added surface, not a replacement.
- **Spec first.** Target: `ARCHITECTURE-v2.md`. Freeze §17 only records that v2 lives next door — not that CloudBots ship. Reed writes that before Atlas/Sable build. Mira owns honesty tests (cloud labeled; no “nothing leaves your Mac”). Nash owns any CI that must not phone home on `pr.yml`.

Out of this cut: Electron, mlx-swift, bundled llama.cpp, Sparkle, Sentry, license keys, LAN/phone remote control, local VM (Lima/Tart), Grok-Bot cloud computers, `agentos` CLI.

## Later (only if Max reopens)

- Live-backend evals / in-app window proof (needs a model server on the Mac).
- Signed notarized DMG (Developer ID).
- App XCTest on GitHub Actions (`SKIP_APP_TESTS=1` today).
- Further ChatViewModel extracts (slash/queue already moved out).

## Docs

`README.md` is how to build and run. This file is what we implement next. `ARCHITECTURE.md` remains the claim freeze. Target rail: [`ARCHITECTURE-v2.md`](./ARCHITECTURE-v2.md) (CloudBots). Not a shipping claim.

# Legal

VibeCoder is **open-source software** licensed under the [MIT License](./LICENSE).

## Privacy commitment

VibeCoder is **local-first**. It does **not** include telemetry, analytics, crash-reporting SDKs, or phone-home services.

### What stays on your Mac

When you use a **loopback** model server (LM Studio, Ollama, oMLX, Unsloth Studio, EXO on `127.0.0.1` / `localhost`), conversation content, code context, and tool I/O are sent only to that local process. The app does not upload chats to VibeCoder-operated servers (there are none).

### When data can leave your Mac

Data **can leave your machine** when **you** configure it to:

| Path | What leaves |
|------|-------------|
| **Custom OpenAI-compatible `/v1` endpoint** (Settings → Custom) | Chat completions (prompts, tool results, code snippets in context) to the host **you** set — including cloud APIs if you paste a remote URL |
| **xAI / other cloud API keys** you enter | Requests to that provider’s API |
| **MCP servers** you enable | Whatever tools those servers expose (network, third-party APIs) |
| **Shell / network tools** the agent runs | Whatever those commands contact (git remotes, `curl`, package registries, etc.) |
| **Local API Server** (loopback by design) | Other apps on this Mac that you point at `http://localhost:<port>/v1` receive proxied completions; if agent-loop is opt-in **On**, tools run with your permissions |

The marketing line “nothing leaves your Mac” is true **only** for pure loopback backends with no custom remote endpoint, no cloud keys, and no agent-initiated network side effects. Pointing Settings at a remote `/v1` host **will** exfiltrate conversation content to that host — by design (BYO backend).

### Trust surface (honest defaults)

- **App Sandbox:** off (empty entitlements). The agent can use the full user filesystem and shell subject to Safe Mode / approval settings.
- **Local API:** defaults to **completions proxy** with `tools: []`. Opt-in agent loop is **off** by default; bind is loopback for Xcode / local clients.
- **Shell seatbelt:** optional write fence (`sandbox-exec`), not macOS App Sandbox. Default **Auto** (on only in Auto permission mode).

## No warranty

The software is provided **AS IS**, without warranty of any kind, express or
implied. See the MIT License for full terms.

## Trademarks

"VibeCoder" is the shipping product name. "AgentOS" / "AgentOS — NEW DAY" are
historical project names used in older docs and package identifiers.
Apple, macOS, Swift, Xcode, and Apple Silicon are trademarks of Apple Inc.
LM Studio, Ollama, EXO, and other backend names are trademarks of their
respective owners. VibeCoder is not affiliated with or endorsed by any of them.

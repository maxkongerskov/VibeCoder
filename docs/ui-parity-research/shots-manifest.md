# UI parity live-capture manifest

Captured 2026-08-16 on an active macOS desktop session (Orca computer-use + ScreenCaptureKit).  
No credentials were entered, no chat prompts were typed, and no settings were changed.

| file | app | screen | how captured | notes/caveats |
| --- | --- | --- | --- | --- |
| [shots/zcode-main-chat.png](shots/zcode-main-chat.png) | ZCode 3.7.7 (`dev.zcode.app`, `/Applications/ZCode.app`) | Main chat / home as launched | `open -a ZCode` (~15s), then `orca computer get-app-state --app dev.zcode.app --window-id 1811 --restore-window` | Windowed 1200×800 @2x (2400×1600). Already signed in as “Max Køngerskov” — **no login/onboarding gate**, so ZCode capture continued. Sidebar + composer + empty-home greeting (“It's late…”). Electron AX tree is chrome-only (close/min/zoom); content is not exposed. |
| [shots/zcode-settings.png](shots/zcode-settings.png) | ZCode | Settings → Model settings | Coordinate click on sidebar gear (logical ~260,765). `Cmd+,` failed (`window_not_focused` even with `--restore-window`) | In-window settings (not a separate window). Lands on **Model settings** (Z.ai Start Plan, GLM-5.3 / GLM-5-Turbo, oMLX custom provider). Left nav also shows General, Appearance, Browser, Memory, Plugins, Skills, Subagents, MCP, Commands, Hooks, Indexing, Usage stats. Gear click was inferred from pixels because AX has no labeled controls. |
| [shots/zcode-conversation.png](shots/zcode-conversation.png) | ZCode | Existing conversation “Code Structure Critique and Fixes” | Navigation-only: Back to workspace (clicked in a brief fullscreen layout to avoid the traffic-light hit target), then sidebar conversation row; then Ctrl+Cmd+F to restore windowed 1200×800 and recapture | Windowed 1200×800 @2x. Shows selected thread, assistant markdown, follow-up composer, sidebar conversation list. **Caveat:** two accidental green-button fullscreen toggles while aiming at “Back to workspace” (that label sits on the same row as traffic lights). Fullscreen was exited before this shot. Did not type in the composer. |
| [shots/vibecoder-main.png](shots/vibecoder-main.png) | VibeCoder 1.0.5 (`tools.vibecoder.VibeCoder`) | Main window as launched | `open` on existing Debug `.app`, ~15s, `orca computer get-app-state --window-id 1989 --restore-window` | Windowed 1648×955 @2x (3296×1910). Home/chat with “Pick a model to start”, detected backends (Ollama / oMLX / Unsloth Studio), sidebar Chat/Projects/Models/Notes/Scheduled + persisted TASKS. Conversation “Please implement login” is selected but the canvas is the no-model empty state. |
| [shots/vibecoder-settings.png](shots/vibecoder-settings.png) | VibeCoder | Settings sheet (Agent / instructions) | AX click on sidebar **Settings** (`element-index 44`) | Modal sheet over the main window: Agent, Connection, Model & Backend, MCP Servers, Tools, Context, Memory, Appearance, Privacy, Advanced, About. Shows existing host system-instructions text (not edited). Closed via **Close** after capture. |
| [shots/vibecoder-models.png](shots/vibecoder-models.png) | VibeCoder | Models tab | AX click on sidebar **Models** (`element-index 5`) after closing Settings | Active backend oMLX; list of server models (Qwen / DeepSeek / Gemma / GLM / MiniMax, etc.) with Use buttons. Did not click Use. |

## Failures / not captured

| intended | app | reason |
| --- | --- | --- |
| ZCode login / onboarding | ZCode | Not present. Session was already authenticated; per brief, capture continued instead of stopping. |
| ZCode Settings via `Cmd+,` | ZCode | Orca `hotkey` reported `window_not_focused` twice (`--restore-window` included). Opened Settings via the gear instead. |
| ZCode 4th screenshot (e.g. General settings) | ZCode | Not needed; the three requested surfaces (main, settings, conversation) succeeded. Slot unused. |
| Repo `find -maxdepth 4` VibeCoder `.app` | VibeCoder | Only hit was the June 2026 branded export `Release/build/export-1.0.2/AgentOS NEW DAY.app` (`tools.agentos.newday` 1.0.2). **Not launched.** Used the newer Debug build instead (see below). `scripts/build.sh` was **not** run. |

## App binaries used

- **ZCode:** `/Applications/ZCode.app` — bundle `dev.zcode.app`, version 3.7.7 (Electron). Launched with `open -a ZCode`.
- **VibeCoder:** `/Users/maxkongerskov/Library/Developer/Xcode/DerivedData/VibeCoder-dnqbvtuieoaeipamxwrshibkbivh/Build/Products/Debug/VibeCoder.app` — bundle `tools.vibecoder.VibeCoder`, version 1.0.5, built 2026-08-15. Chosen over the older in-repo AgentOS 1.0.2 export because it is the current VibeCoder-branded UI.

## Session notes

- Desktop was **not** headless: Finder, Mail, Orca, Terminal, Edge, and others were already running. Orca accessibility + screenshot permissions were **granted**.
- ZCode window id `1811`; VibeCoder window id `1989`.
- Both apps were left running; no user data was deleted.
- Capture tool: Orca `1.4.182` / `orca-computer-use-macos` 1.0.0, ScreenCaptureKit window screenshots. No `screencapture -x` fallback was required.

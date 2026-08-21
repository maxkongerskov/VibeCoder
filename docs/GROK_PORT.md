# Grok Build → VibeCoder port surface

Behavioral port of Grok Build agent runtime into `Sources/AgentCore`.
Safety checkpoint: `chore: pre-Grok-port safety checkpoint` in git history.

**Research (stacked waves):**  
- Wave 1 matrix: `HANDOFF/.../W5-findings.md`, `W5-notes/parity-matrix.md`  
- Wave 2 under-the-hood: `HANDOFF/.../04-GROK-PORT-RESEARCH-WAVE2.md`  
- **Wave 3 extensive harvest (master backlog):** `HANDOFF/.../05-GROK-PORT-RESEARCH-WAVE3-EXTENSIVE.md`  
- Local/offline honesty: `HANDOFF/.../sweep/W14-sweep.md`

Open source upstream: https://github.com/xai-org/grok-build (Apache-2.0).

## Local inference (not a Grok-port invent)

Grok Build and VibeCoder are the **same class** for models: **BYO OpenAI-compatible HTTP** (custom `base_url` / LM Studio / oMLX / Ollama / Unsloth Studio / EXO). Neither is an in-process MLX runtime.

| Claim to avoid | Reality |
|----------------|---------|
| “In-process MLX is daily-driver” | `Sources/MLXBackend` + `MLXInferenceService` **stub**; generation throws until mlx-swift is a Package dependency |
| “Bundled GGUF / LiteLocalBackend” | **No** `LiteLocalBackend`; bundled llama.cpp product **removed**; legacy `"llamaCpp"` → `.ollama` |
| “Fully offline zero-deps agent” | Offline **agent tools** work if a **local** model server is up; app does not embed weights |
| “Full agent loop inside Xcode” / “opt-in is schemas-only” | `LocalAPIServer` **default** is a loopback **proxy** (`tools: []`). Opt-in `agentToolsEnabled` maps to **`.agentLoop`**: bounded multi-step `AgentLoop` (cap 8) on the **bound project** — tools **execute** and the model is re-prompted. **Not** schemas-only (that was PB7; `ServeToolsPolicy.schemasOnly` is unused by the Settings flag). Still **not** in-app parity: no worktree, no review UI, no MCP/Xcode-bridge by default. See ARCHITECTURE §5.7 / §10.1 |
| “App Sandbox hardened” | `App/VibeCoder.entitlements` is **empty**. Optional **seatbelt** (`sandbox-exec`) fences **`run_shell` children** only (`SafeBash`) — not macOS App Sandbox for the app process |
| “Grok-class monitor product” | `list_background_jobs` / `monitor_jobs` list **in-app** jobs (`JobMonitor` / `BackgroundJobManager`). Not arbitrary process watch / continuous stdout |
| “Embeddings / vector dream” | `dreamEnabled` → **extractive** `MemoryDream`; search is keyword/FTS (`MemoryIndex`). **No** embedding model or MMR store |
| “Skills marketplace / SkillStore UI” | `SkillDiscovery` + `load_skill` ship; **no** marketplace install UI / SkillStore sidebar |
| “LAN / phone remote control ships” | `RemoteControlServer` is **OFF** — not password-gated, not a shipping feature (2026-08-20) |

Port work (memory, compaction, hooks, retry policy, etc.) sits **above** that HTTP seam. See README first-run server table and DESIGN status box for product wording.

## Tool name mapping

| Grok | VibeCoder |
|------|-----------|
| memory_search | memory_search |
| memory_get | memory_get |
| memory write | memory (log_decision / write_handoff / remember) |
| bash | run_shell (optional seatbelt child sandbox) |
| search_replace | edit_file |
| apply_patch | apply_patch |
| task / task_output | task / get_task_output / wait_tasks / kill_task |
| ask_user_question | ask_user |
| skill | load_skill (SKILL.md discovery + progressive index) |
| monitor / watch | `list_background_jobs` / `monitor_jobs` — in-app job listing only, not Grok watch |

## Modules

| Area | Path |
|------|------|
| Memory | `Sources/AgentCore/Memory/` (extractive dream; keyword index) |
| Compaction | `Sources/AgentCore/Compaction/` |
| Turn lifecycle | `Sources/AgentCore/Agent/TurnLifecycle.swift`, `InterjectionBuffer.swift` |
| Hooks | `Sources/AgentCore/Hooks/` |
| Skills | `Sources/AgentCore/Skills/` + `Tools/Builtins/LoadSkillTool.swift` (metadata index; roots include `.cursor/skills`) |
| Durable grants | `Sources/AgentCore/Permissions/` |
| Hunk tracker | `Sources/AgentCore/Safety/HunkTracker.swift` (path may vary) |
| Checkpoints | `Sources/AgentCore/Safety/CheckpointStore.swift` + `restore_checkpoint` |
| Seatbelt | `Sources/AgentCore/Safety/SafeBash.swift` (sandbox-exec profile) |
| Job monitor | `Sources/AgentCore/Tasks/JobMonitor.swift` (listing only) |
| Agent definitions | `Sources/AgentCore/Agent/AgentDefinitionDiscovery.swift` |
| Code nav | `Sources/AgentCore/CodeIndex/` + `find_symbol` (`backend: lsp\|text-index`) |
| LocalAPI / Xcode | `Sources/AgentCore/Server/LocalAPIServer.swift` (proxy default; bounded AgentLoop opt-in) |

## Feature flags (`AppSettings` / `AgentLoop.Config`)

- `memoryEnabled` (default true) — tools + optional inject; **not** vector DB
- `dreamEnabled` (default true) — **extractive** consolidation only
- `fullReplaceCompactEnabled` (default true)
- `injectProjectMemory` (default true)
- Seatbelt preference — Auto/edit default for shell children; **not** App Sandbox entitlement
- LocalAPI `agentToolsEnabled` — **false → proxy `tools: []`**; **true → bounded AgentLoop** (not schemas-only). Default **false**

## Honesty changelog

| Date | Note |
|------|------|
| 2026-08-20 | **Claim freeze:** Unsloth in BYO list; Local API opt-in is **AgentLoop** not schemas-only; `monitor_jobs` registered as in-app listing; remote control **OFF** |
| 2026-07-24 | **P7:** expanded claim→reality table (Xcode, seatbelt vs App Sandbox, monitor, dream, marketplace); modules + flags aligned to code |

# VibeCoder ↔ ZCode Agent-Harness Parity Checklist

Generated 2026-08-16 from a full reverse-engineering pass of ZCode Desktop 3.7.7
(build 4926, `dev.zcode.app`) plus a code-backed audit of this repo (v1.0.5).

**Evidence files** (in `~/zcode-reverse/`):
- `FINDINGS.md` — app bundle architecture, endpoints, credentials, network/CA layer
- `live-system-prompt-raw.md` — **verbatim** system prompt from a real GLM-5.3 API request
- `live-tools-raw.md` — **verbatim** 24 tool definitions (descriptions + schemas) from that request
- `agent-core/tools.md` — tool registry/assembly in code (line refs into de-minified bundle)
- `agent-core/system-prompt.md` — system-prompt builder in code, live blocks → code sections
- `agent-core/agent-loop.md` — loop, streaming, permissions, hooks, compaction in code
- `agent-core/skills-memory-subagents.md` — skills/memory/subagent mechanics + disk paths
- `vibecoder-catalog.md` — this repo's feature inventory (code-backed, with stale-doc callouts)

Scoring: ✅ parity · 🟡 partial (work described) · ❌ missing. Priorities P0 = do first
(high behavioral impact / low-medium effort), P1 next, P2 later, P3 = product-surface scope.

---

## Scorecard

| # | Subsystem | ZCode | VibeCoder | Status |
|---|-----------|-------|-----------|--------|
| 1 | Turn loop & tool scheduling | unbounded, mid-stream RO tools, parallel groups (≤10) | capped loop, RO batches parallel, mutators serial; mid-stream RO still missing | 🟡 P2 |
| 2 | Context management / compaction | 95% auto + reactive + micro-compact, 9-section summary spec | budget 70%, FullReplace + Semantic + micro + reactive overflow retry | 🟡 P2 |
| 3 | Wire protocol & prompt caching | Anthropic `tool_use` + `cache_control: ephemeral`, thinking budget | OpenAI fn-calling + inline-parser fallback, no cache_control | 🟡 P2 (design note) |
| 4 | System prompt composition | 3 blocks; git-status snapshot, env block, autonomous-mode text | 15-section composer + git snapshot + ZCode behavior + mid-turn reminder cadence | 🟡 P2 |
| 5 | Tool catalog (24 model tools) | see §5 map | 38 builtins + 6 PDF + MCP | 🟡 mostly ✅ (node REPL still missing) |
| 6 | Skills | SKILL.md + `Skill` tool + system-reminder listing, plugin namespace | index + `load_skill` + in-session `allowed-tools` + markdown `/commands` with `$ARGUMENTS` | ✅ near-parity (listing budget P2) |
| 7 | Subagents | profiles w/ rich frontmatter, parallel fan-out, SendMessage/resume, telemetry | parallel `task` + profiles + mailbox + usage/JSONL; inspector Duration/Tokens/Tools; **mid-run `metadata.json`**; `cache_*` hidden | 🟡 P2 |
| 8 | Memory | per-project typed .md + extraction; `ReadSessionContext` cross-session tool | MEMORY/DECISIONS/HANDOFF + FTS + 3 tools + `read_session_context` + mid-turn `memory_update` nudge | ✅ Vibe richer |
| 9 | Permissions & modes | build/edit/plan/yolo; 13-step decision; command-prefix rules, suggested updates | plan/build/edit/yolo; 8-step pipeline; durable grants UI; prefix rules; PermissionRequest before ask sheet | ✅ near-parity |
| 10 | Hooks | 7 events; Stop-continue ≤3, input mutation, PermissionRequest | 7 events wired; **default-IGNORE project files**; user `~/.vibecoder`/`~/.grok` hooks still run | ✅ near-parity |
| 11 | Sessions & persistence | SQLite (messages/parts/todos/permissions), model-io rollouts, resume w/ read-state | JSON + checkpoints + `sessionReadPaths` resume + opt-in model-io | 🟡 P2 |
| 12 | Scheduling | Cron* model tools + off-peak runs | `cron_*` tools + SchedulerService; no launchd re-arm | 🟡 P2 |
| 13 | MCP | stdio/http/sse, plugin env-substitution, OAuth | stdio + streamable HTTP + **GET `/sse`** + OAuth PKCE; no `node_repl` | ✅ (`node_repl` P3) |
| 14 | Remote control / surfaces | desktop + phone relay, CUA broker, Chrome import | LAN remote-control server, SwiftUI UI | ✅ different posture; CUA = P3 scope |

**Where VibeCoder already beats ZCode (keep, don't regress):** `apply_patch` unified diff;
file CRUD toolset (`delete_file`/`move_file`/`create_directory`/`list_directory`);
SourceKit-LSP `find_symbol`; Xcode build/project tools + MCP bridge; **checkpoints/rewind**;
`tool_search` deferred-tool disclosure (ZCode has none); memory FTS + human-readable files;
durable-grants UI; **worktree isolation for subagents** (ZCode core ships it as dead code only);
stall/governor/doom-loop guards; two-model orchestrator.

---

## 1. Turn loop & tool scheduling — 🟡 P2 (mid-stream RO still open)

**ZCode** (`agent-loop.md`): unbounded `for(;;)`; per iteration: microcompact →
auto-compact (95% of `ctx − outputReserve`, or preflight-v1) → model step.
Tool scheduling has **two layers**: (a) *mid-stream* — read-only + `concurrentSafe`
tools start executing while the model is still streaming; (b) end-of-stream — calls are
topologically grouped, parallel-safe groups run via `Promise.all` (maxConcurrency **10**),
destructive/non-safe tools get solo sequential groups. Exit: no tool_use → Stop hooks may
force ≤3 continuations with injected context, else break. `stop_reason` unified mapping
includes Anthropic `pause_turn`. Abort → persisted snapshot + `TurnCancelled`.

**VibeCoder**: `AgentLoop.run` while-loop, cap 30 (100 headless); parallel read-only
batches via `executeReadOnlyBatch`, mutators serial; stall/governor/doom-loop guards
(💪); one `backend.stream` per iteration; finish policies (grounding/edit-verify).

**Work:**
- [x] **P0 — Reactive compaction on context-exceeded errors.** `ContextOverflowClassifier` + `AgentLoop` retries the same step after one FullReplace/Semantic compact.
- [x] P1 — Parallel **subagent** dispatch: consecutive `task` calls in one assistant message run concurrently (max 10). Catalog text tells the model to send them together.
- [x] P1 — Rapid-refill breaker: `RapidRefillBreaker` hard-stops after 3 consecutive persisted compacts with <3 tool turns between.
- [ ] P2 — Mid-stream read-only tool execution (start RO tools as their JSON completes).

## 2. Context management — 🟡 P2 (reactive + 9-section + micro shipped)

**ZCode compactor prompt** (verbatim spec in `agent-loop.md` §6): text-only summarizer,
response must be `<analysis>` + 9-section `<summary>` (Primary Request / Key Technical
Concepts / Files and Code Sections / Errors and fixes / Problem Solving / **All user
messages** / Pending Tasks / Current Work / Optional Next Step), injected as:
`"This session is being continued from a previous conversation that ran out of context…"`.
Micro-compact (opt-in) rewrites old tool results to `[Old tool result content cleared]`
(default tools: Read, Bash, Grep, Glob, WebFetch, WebSearch, Edit, Write, ApplyPatch),
triggered at 90% of the auto threshold or after 60 min idle.

**VibeCoder**: `FullReplaceCompactor` + `SemanticCompactor` (extractive, keepRecent 6),
elision that preserves tool_call_id pairing, `ToolResultCompressor` on wire copy only,
70% budget threshold.

**Work:**
- [x] P1 — Adopt the 9-section summary spec + "continued from previous conversation"
  framing in `FullReplaceCompactor`.
- [x] P1 — Micro-compact: `MicroCompactor` clears old tool bodies on the wire copy.
- [ ] P2 — Surface per-message token accounting closer to ZCode (provider usage
  calibration already exists; fine).

## 3. Wire protocol — 🟡 P2 (mostly a design note)

**ZCode**: Anthropic Messages API only: `system[]` blocks with `cache_control: ephemeral`,
`thinking: {type:"enabled", budget_tokens}`, `output_config.effort`, native
`web_search_20260209` passthrough on Anthropic-format providers, `tool_result` blocks.
**VibeCoder**: OpenAI-compatible fn-calling + `InlineToolCallParser` fallbacks
(MiniMax/Anthropic-XML/Hermes/bare-JSON) — strictly more flexible for local models;
`ThinkingModelScanner` already emits GLM `thinking`, Anthropic-style `budget_tokens`, and
`reasoning_effort`.

**Work:**
- [ ] P2 — Optional Anthropic-format backend (for GLM-z.ai/BigModel endpoints that are
  Anthropic-shaped, like the ones ZCode uses) **and** emit `cache_control: ephemeral` on
  system + tool blocks when the endpoint supports it. Biggest win: prompt caching on
  cloud GLM; also unlocks provider-native web search passthrough later.
- [ ] P3 — Provider-native web-search tool passthrough (ZCode maps local `WebSearch` to
  Anthropic native on its providers).

## 4. System prompt composition — 🟡 P2 (cadence shipped; cache split open)

**ZCode 3-block layout** (`system-prompt.md`): block0 identity prefix;
block1 stable (identity + dual-use **security policy** + `# Harness` rules); block2 dynamic
(concatenated: comms guidance, session-specific skill guidance, `# Memory`, `# Environment`,
`# Context management` + **autonomous-mode** text, `gitStatus:` snapshot). All
`cache_control: ephemeral`. Skills list + AGENTS.md/MEMORY.md + currentDate arrive as a
**user-role `<system-reminder>` attachment**, refreshed mid-conversation.

**VibeCoder**: `AgentSystemPromptComposer` — 15 sections, hierarchical project rules
(richer than ZCode), memory tails injected (richer), mode summary, runtime nudges.
Chat mode sends **no** system prompt at all (ZCode always does). Mid-turn cadence
arrives as system-reminder nudges (`ChatLoop.cadenceReminders`), not a second
composer block.

**Work:**
- [x] **P0 — Inject a `git status` snapshot** via `GitStatusSnapshot` at first compose (cached per conversation).
- [x] **P0 — Port ZCode's behavior sections verbatim** in `ZCodeBehaviorPrompt` (comms, autonomous-mode, context-management, pre-end-of-turn self-check).
- [x] P1 — Mid-turn reminder cadence: plan-mode reminder every 5 human turns;
  todo nudge after 8 human turns without `create_plan` / `update_todo`, **suppressed
  when `PlanStore` still has a live plan** (survives compact); skill/instructions
  refresh after a persisted reactive compact. Wired in `AgentLoop` (`rawMode` skips).
- [ ] P2 — Split composer output into stable vs dynamic blocks (prep for prompt caching).

## 5. Tool catalog — 🟡 (map + 4 gaps)

Live ZCode tool list (24, GLM-5.3 capture) → VibeCoder:

| ZCode tool | VibeCoder equivalent | Notes / gap |
|---|---|---|
| `Read` | `read_file` | ✅ read-before-edit on both sides |
| `Write` | `write_file` | ✅ (Vibe: overwrite requires prior read) |
| `Edit` | `edit_file` (SEARCH/REPLACE) + `apply_patch` | ✅ Vibe richer |
| `Bash` (high-risk, system scope) | `run_shell` (+seatbelt option) | ✅ parity; Vibe has no PTY (ZCode GUI terminal uses node-pty, agent core doesn't need one) |
| `Glob` / `Grep` | `glob_files` / `grep_code` (system grep) | 🟡 ZCode ships native **ripgrep + bfs** binaries (`ZCODE_RG_BINARY`); Vibe uses `/usr/bin/grep`. P2: vendor `rg` for speed on big trees. Note ZCode can hide Glob/Grep entirely (`embeddedSearchEnabled`) and rely on Bash find/grep |
| `WebFetch` (preapproved-URL rule, needsApproval) | `fetch_url` (SSRF guard) | ✅ near-parity; add domain allowlist rule type (§9) |
| `WebSearch` | `web_search` (Brave/SerpAPI/DDG) | ✅ by design; ZCode on z.ai uses provider-native search |
| `TodoRead` / `TodoWrite` (SQLite-backed, survive compaction) | `create_plan` / `update_todo` + PlanStore md | ✅ parity; ZCode's SQLite storage is why compact can't drop todos — VibeCoder's PlanStore-on-disk achieves the same. Add "Pending Tasks" to your compact prompt (§2) |
| `EnterPlanMode` / `ExitPlanMode` (approval gate, plan file `.zcode/plans/plan-<sess>.md`, exit returns approved plan text) | `enter_plan_mode` / `exit_plan_mode` + extras honored in AgentLoop | ✅ shipped (UI approve sheet still richer) |
| `AskUserQuestion` | `ask_user` | ✅ |
| `Agent` (fg/bg, parallel-safe) / hidden alias `Task` | `task` | ✅ parallel fan-out + profile fields + mailbox resume |
| `TaskOutput` / `TaskStop` | `get_task_output` / `wait_tasks` / `kill_task` / `list_background_jobs` | ✅ Vibe richer |
| `Skill` (returns `<skill_content>`; "BLOCKING REQUIREMENT" wording) | `load_skill` + prompt index | ✅ near-parity (§6) |
| **`ReadSessionContext`** | `read_session_context` | ✅ `relevant` / `handoff`, 12k cap |
| **`SendMessage`** | `send_message` + `AgentMailbox` | ✅ resume via `resume_agent_id` |
| **`CronCreate/Update/List/Delete`** | `cron_create` / `cron_list` / `cron_update` / `cron_delete` | ✅ 20-task cap; runs while app is open |
| **`mcp__node_repl__js`** (+ `js_reset`, `js_add_node_module_dir`) — built-in Node REPL MCP | — | ❌ P2: small self-hosted stdio MCP (or builtin tool) that evals JS with a persistent context. Great for data wrangling/JSON math without shell quoting pain |
| `RespondToCoordinator` (child→parent, internal) | — | internal to §7 messaging; not a standalone gap |

VibeCoder-only (keep): `apply_patch`, file CRUD tools, `find_symbol`, Xcode tools + MCP
bridge, git commit/PR tools, `fetch_rss`/`apple_docs`, memory trio, `tool_search` +
deferred disclosure, `restore_checkpoint`.

## 6. Skills — ✅ near-parity (small P2s)

**ZCode**: discovery roots `~/.zcode/skills`, `~/.agents/skills`, `.zcode| .agents` walking
up to `.git`, plugin `skills/` (official plugins scope="system"); frontmatter
`name/description/when_to_use/license/metadata`; listing is a **user-role**
`skills_listing` `<system-reminder>` (20k-char budget, compact fallback); `Skill` tool
returns `<skill_content>`, expands `${ZCODE_SKILL_DIR}` only; **`args` is parsed but
unused**; plugin-qualified names `plugin:skill`; built-in "skills" actually ship inside
official plugins (browser-use, document-skills, android/ios-simulators, skill-creator…).

**VibeCoder**: `SkillDiscovery` over `.vibecoder/.grok/.claude/.cursor` (project + home);
metadata-only index (name + ≤160 chars, max 40) in system prompt; full body via
`load_skill`; `/skill` user injection; frontmatter `disable-model-invocation`,
`user-invocable`, `allowed-tools`. A successful `load_skill` with a non-empty
`allowed-tools` list installs an **in-session** `SkillToolGate` (last load wins;
`load_skill` stays allowed so another skill can replace the gate). **Not persisted**
— relaunch or `clear` is unrestricted until the next load.

**Work:**
- [ ] P2 — Raise the listing budget from 40 entries/160 chars toward ZCode's
  20k-char budget (truncation hurts model skill selection on busy setups); add
  `when_to_use` to frontmatter parsing and listing format.
- [x] P2 — Enforce `allowed-tools` on skill load (`SkillToolGate` in `ToolRegistry`
  execute + read-only batch). In-session only; fail-open after process restart.
  Settings `disabledToolNames` still wins over the skill list.
- [x] P2 — Slash-command files (`.vibecoder/commands` / user home) + Settings
  **Commands** editor: markdown `/name` with `$ARGUMENTS` / `$N` expansion
  (`SlashCommandService.expandCustomCommand`). `` `!` `` / `$ARGUMENTS` are not
  shell-expanded.
- [ ] P3 — Plugin namespace for skills (blocked by plugin system, §14).

## 7. Subagents — 🟡 P2 (mid-run metadata shipped; mcp/memory scope open)

**ZCode**: `Agent` tool (`subagent_type`, `run_in_background`). Built-ins:
`general-purpose` (tools `*`, AGENTS.md injected, prompt `Bzt()`) and `Explore`
(read-only 7-tool set incl. restricted Bash, cyan). Child = fresh runtime with own
`sess_subagent_agent_<uuid>` session; artifacts on disk: `transcript.jsonl`,
`metadata.json` (profile snapshot, **token usage incl. cache read/write**, tool count,
duration), `output.txt`. Parent: foreground = await final text as tool result; background
= notification message + `SendMessage` to resume the completed agent by `agent_<uuid>`.
Child gets `RespondToCoordinator` (child→parent channel). Parent abort cascades; inactivity
watchdog kills silent children. Profiles from `~/.zcode/agents/**` / repo `.zcode/agents/**`
with frontmatter: `tools, disallowedTools, skills, memory (user|project|local), model,
thoughtLevel, color, permissionMode, maxTurns, background, injectAgentsMd, mcpServers`.
Plan mode: up to 3 Explore agents in phase 1.

**VibeCoder**: `task` → `SubAgentRunner` (separate loop — do not merge into `AgentLoop`);
types general-purpose/explore/plan + custom `.md`; worktree isolation (💪); depth 1;
iteration cap ~15; background via `BackgroundJobManager` + job tools. Consecutive `task`
calls fan out in parallel (max 10). Profiles + `send_message` / mailbox resume ship.
Usage is summed from `ChatChunk.usage` into `SubagentUsage` and written under
`~/Library/Application Support/VibeCoder/subagents/<parent>/<agent_id>/`
(`transcript.jsonl`, `metadata.json`, `output.txt`). Tool-result `<subagent_meta>`
includes duration, prompt/completion/total tokens, cache fields, tool count.
**Honesty:** cache read/write stay **0** until a backend owner extends `ChatChunk`
and are **hidden** in the inspector (shown only if > 0). Inspector Subagents
detail shows **Duration / Tokens / Tools** from `<subagent_meta>` and
`metadata.json`. Mid-run, `SubAgentRunner.publishThread` calls
`updateProgress` so `metadata.json` rewrites while `status` stays `running`
(no `completedAt`); the inspector merges that snapshot for live children.
Not a per-token stream. Chat task rows do not grow a separate token card.

**Work:**
- [x] **P0 — Parallel `task` fan-out** (AgentLoop consecutive `task` batch + catalog text).
- [x] P1 — Per-agent profile fields: `model`, `thoughtLevel`/`effort`, `permissionMode`,
  `maxTurns`, `background` in agent `.md` frontmatter, applied at spawn.
- [x] P1 — Inter-agent messaging: `send_message` + `AgentMailbox`; drain each child iteration;
  resume via `task` `resume_agent_id`.
- [x] P1 — Persist child transcript JSONL + usage/tool-count/duration
  (`SubagentSessionStore` + `task` meta). Cache token fields reserved, currently 0.
- [x] P2 — Inspector Duration / Tokens / Tools cards (`subagent_meta` +
  mid-run `metadata.json` via `updateProgress`). `cache_*` hidden while 0.
- [ ] P2 — Per-agent `mcpServers` (agent-scoped MCP pool) and memory scope
  (`user|project|local`) à la ZCode `agent-memory/`.

## 8. Memory — ✅ VibeCoder is stronger

**ZCode**: `~/.zcode/cli/memories/projects/<slug>-<sha256[:16]>/memory/*.md` typed
`user|feedback|project|reference`; `# Memory` system section when memory root set;
background extraction agent after turns (skips "no-user-prose"); `relevant_memory` /
`memory_update` mid-conversation reminders; semantic recall exists but is **hard-off**;
plus `ReadSessionContext` for cross-session retrieval (§5). Note: the live install's
`extensions/ad_hoc/notes` + `rollout_summaries` (Source: explicit_user_request) come from
an older build, not the current bundle.

**VibeCoder**: `MEMORY.md`/`DECISIONS.md`/`SESSION_HANDOFF.md` in project root (tails
injected), workspace index `memory/<sha256>` + FTS, first-turn recall block, end-of-turn
flush + extractive dream (LLM option), 3 model-facing tools. Successful `remember` /
`log_decision` / `write_handoff` emit a `memory_update` extra; `AgentLoop.recordToolResult`
appends it to `pendingNudges` so the next model step sees the write (cached system-prompt
memory tail stays stale until the next user turn — the reminder says so). No embeddings.

**Work:**
- [x] **P1 — `read_session_context` tool**: keyword `relevant` + structured `handoff`, 12k cap.
- [x] P2 — Mid-conversation `memory_update` reminder when `memory` writes
  (`MemoryUpdateReminder` extras + `AgentLoop` `pendingNudges`). Read actions never emit.
- [ ] P2 — Typed memory entries (`user|feedback|project|reference`) à la ZCode
  `agent-memory/`. Vibe still uses flat MEMORY/DECISIONS/HANDOFF files.
- [ ] P3 — Semantic recall: ZCode ships it disabled; skip until embeddings are worth it.

## 9. Permissions — ✅ near-parity (rule-syntax P1)

**ZCode decision order** (`agent-loop.md` §4, verbatim): plan.enter allow → user-interaction
ask/deny → yolo allow → auto deny (unimplemented) → global disallow → project **deny**
rules → project **ask** rules → plan-mode check (RO + non-destructive MCP + explicit
session capabilities) → project **allow** rules → WebFetch preapproved URL → global allow
→ edit-mode file-edit allow → build rules (RO/no-approval allow; critical ask; high ask
unless auto-approved; low session-state allow; else side-effect ask). Rules: tool name +
optional `ruleContent` (exact / glob / `cmd:*` prefix); subjects in order
`command, url, file_path, path, pattern, patch_text`; **Bash-specific**: parser builds
stable prefixes (`git commit`, `npm run`, …) for rule matching and suggested persists;
**WebFetch**: subject is `domain:hostname`. Ask payloads include
`suggestedPermissionUpdates` (addRules allow/deny/ask) — the UI "always" button writes
them into a project-scope ruleset (SQLite). Memory-dir `.md` writes are force-allowed
outside plan mode.

**VibeCoder**: same four modes (plan/build/edit/yolo — deliberately ZCode-shaped); 8-step
pipeline with hooks → deny/ask rules → remembered+durable grants → RO auto-approve → mode
policy → path confinement (always) → Safe Mode allowlists. Grants UI exists.

**Work:**
- [x] P1 — Structured command-prefix permission rules for `run_shell` + domain allowlist
  for `fetch_url` / `web_search`. `ToolAuthorization.suggestions(forShellCommand:)` is
  ready for a later UI bind (sheet still uses Once/Always/Never).
- [x] P2 — Permission-request pre-check hook (`PermissionRequest` via
  `ShellApproval.resolveAsk` / `permissionRequestDenial`) so hooks can deny
  before the ask sheet. Fail-open when no hooks dir.

## 10. Hooks — ✅ (events wired; project files ignored at runtime)

**ZCode events**: `SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest,
PostToolUse, PostToolUseFailure, Stop`. JSON on stdin (Claude-compatible incl. temp
`transcript_path`, `tool_input/output_id`, permission suggestions). Exit 2 = block.
Key semantics: PreToolUse can **deny/ask/allow and rewrite `tool_input`** (updatedInput);
UserPromptSubmit can **cancel the whole turn**; Stop with `continue:true` + context forces
≤3 more model steps; additionalContext is injected as a `hook_context` attachment with the
system-prompt instruction "treat hook output as user feedback". Project-file hooks are
**stripped** (security); plugins contribute hooks.

**VibeCoder**: `PreToolUse, PostToolUse, SessionStart, UserPromptSubmit, Stop,
Notification, PermissionRequest, PostToolUseFailure`; exit 2 deny; fail-open on
spawn errors. MCP namespaced tools use `applyPreToolDetailedJSONArgs` then the
same PostToolUse / PostToolUseFailure decorate path as builtins. Runtime
`hooksDir` **defaults to user-scope only** (`allowProjectFileHooks == false`).
Project/worktree `.vibecoder/hooks` are not executed unless that flag is on.
Settings still load/save project hook files via `projectHooksDir` (edit ≠ run).

**Work:**
- [x] P1 — **Stop-hook continuation**: `stopDetailed` + `shouldContinueAfterStop` (cap 3).
- [x] P1 — PreToolUse `updatedInput` + deny/ask via `preToolDetailed` in `ToolRegistry`
  and MCP (`applyPreToolDetailedJSONArgs` in `AgentLoop` before `invokeTool`).
- [x] P2 — `PermissionRequest` (`ShellApproval.resolveAsk`) and `PostToolUseFailure`
  (ToolRegistry catch/`isError` + MCP throw/`isError`).
- [x] P2 — Adopt ZCode's security stance: **ignore project-file hooks by
      default**. User `~/.vibecoder/hooks` and `~/.grok/hooks` still run.

## 11. Sessions & persistence — 🟡 P2 (debug parity)

**ZCode**: SQLite `db.sqlite` (`session/message/part/todo/session_target/permission/
local_setting` + usage); resume restores messages, `readFileState`, permission mode;
**per-request model I/O recordings** at `~/…/rollout/model-io-<session>.jsonl`
(full request body incl. system+tools, response text/toolCalls/usage) — this file is what
made the prompt extraction above trivial.

**VibeCoder**: one JSON per conversation in App Support; checkpoints; opt-in
`AgentTraceService` JSONL; `sessionReadPaths` on the conversation (string array
on disk — `Set<String>` Codable SIGSEGV). `ConversationStore` hydrates
`SessionReadTracker`; `AgentLoop` seeds the tracker and `ToolContext` at turn
start. Empty tracker still fail-closes the read-before-edit guard.

**Work:**
- [x] P2 — Opt-in model I/O JSONL via `ModelIORecorder` (default off) hooked in
  `OpenAICompatibleClient.streamChatCompletion`.
- [x] P2 — On resume, restore read-before-edit state (`sessionReadPaths` persist
  + `ConversationSessionReadCodec` + `AgentLoop` seed). `SkillToolGate` is
  **not** part of this field and stays in-memory.

## 12. Scheduling — 🟡 (P1 tools over existing service)

**ZCode**: model-facing `CronCreate/Update/List/Delete` (20-task cap, "do not retry"
canned denial), hidden on automation-created turns; plus product-level **off-peak runs**
(cloud-side batch execution during off-peak hours — a Z.ai billing/infra feature, not
local).

**VibeCoder**: `SchedulerService` (in-process timer; sidebar "Scheduled"; stops when app
quits) + `/loop` + model-facing `cron_*` tools (20-task cap).

**Work:**
- [x] P1 — `cron_create/update/list/delete` wired to `ScheduledTaskStore` (20-task cap).
- [ ] P2 — Persist schedules so they survive app restarts (launchd/`smapsd` or re-arm on
  boot). Off-peak cloud runs = Z.ai infra, skip.

## 13. MCP — ✅ (SSE is GET, not an alias)

Both: `server__tool` namespacing, allow/deny rule integration, session-pooled clients,
OAuth. VibeCoder transports: stdio, streamable HTTP, and **legacy GET `/sse`**
(`MCPSSEClient` — `Accept: text/event-stream`, wait for `endpoint` event, then
POST messages). Tests reject treating the SSE URL as a streamable-HTTP POST
alias. ZCode also ships plugin-scoped `.mcp.json` env substitution and a builtin
`node_repl` server.

**Work:** [x] P2 SSE transport (GET `/sse` + `endpoint` event); [ ] P3 plugin-scoped
servers; [ ] P3 builtin `node_repl` (`mcp__node_repl__js`).

## 14. Product-surface scope (P3 — not agent-harness parity)

These exist in ZCode as *desktop product* features; decide if VibeCoder wants them at all:
- **Plugin system + marketplaces** (ZCode installs from `anthropics/claude-plugins-official`
  [278 plugins] + its CDN; plugin = skills+commands+agents+MCP+hooks bundle). VibeCoder's
  `.vibecoder/` dirs already mirror the layout — a "plugin = folder with .mcp.json +
  skills/ + commands/ + agents/" importer would be the cheapest parity step.
- **Computer-use agent** (CUA permission broker sockets, desktop automation) + browser-use.
- **Phone/web remote control** via relay (`zcode.chatglm.site`) — VibeCoder's LAN
  `RemoteControlServer` covers the local case.
- **Chrome cookie/session import** for login reuse (privacy-sensitive; ZCode prompts via
  Keychain). VibeCoder's LAN remote control + local backends make this mostly moot.
- **Cloud accounts**: OAuth via bigmodel.cn → zcode.z.ai token exchange, coding-plan
  entitlements, telemetry (ARMS). VibeCoder is BYO-backend — a deliberate posture.
- **Private network CA + egress proxy** for the agent (ZCode can MITM its own model/tool
  traffic via a self-generated CA). If you add request recording (§11) you get the debug
  value without the MITM.

---

## Suggested build order (effort vs impact)

Items 1–11 below **landed** (through Wave 2, 2026-08-18). Wave 4 added
`memory_update` (§8). Later: GET `/sse`, ignore-project-hooks, commands
`$ARGUMENTS`, mid-run metadata. Remaining product leftovers named by
coordinator: `node_repl`, mermaid, `mlx-swift`, queue Edit.

1. ~~**git-status snapshot injection** (§4)~~ — shipped.
2. ~~**Reactive compaction on context-exceeded** (§1/§2)~~ — shipped.
3. ~~**Port ZCode behavior prompt sections verbatim** (§4)~~ — shipped.
4. ~~**Parallel task fan-out** + tool description update (§7)~~ — shipped.
5. ~~**9-section compact prompt + micro-compact old tool results** (§2)~~ — shipped.
6. ~~**`read_session_context` cross-session tool** (§8)~~ — shipped. Wave 4:
    ~~**`memory_update` mid-turn nudge**~~ — extras + `pendingNudges`. Typed
    `user|feedback|project|reference` entries still open.
7. ~~**Command-prefix + domain permission rules** (§9)~~ — shipped (sheet UI bind still later).
8. ~~**Stop-hook continuation + PreToolUse input rewrite** (§10)~~ — shipped.
9. ~~**Model-facing cron tools over SchedulerService** (§12)~~ — shipped.
10. ~~**Subagent profiles + inter-agent messaging** (§7)~~ — shipped. Usage + JSONL
    + mid-run `metadata.json` (`updateProgress`). `cache_*` hidden.
11. ~~**Model-I/O request recording, opt-in** (§11)~~ — shipped. **`sessionReadPaths`
    resume** shipped Wave 2.
12. Still unshipped (keep unchecked): **`node_repl`**, **mermaid**, **`mlx-swift`**,
    queue **Edit**. Other open P2s that did not land this pass: Anthropic
    `cache_control`, mid-stream RO tools, composer cache split, skill listing
    budget / `when_to_use`, per-agent `mcpServers` + typed memory kinds,
    persist cron across restart, rg vendoring.

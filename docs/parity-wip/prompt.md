# Wave 1 — `prompt`

Owner: `prompt`. Exclusive files only.

## What changed

### Git-status snapshot (PARITY §4 item 1)

New `Sources/AgentCore/Agent/GitStatusSnapshot.swift`:

- Runs `rev-parse --is-inside-work-tree`, current branch, `origin/HEAD` then `main`/`master`, `user.name`, `git status --porcelain` (capped at 40 lines), `git log -5 --oneline`.
- Labels the block as a **snapshot that will not update** (ZCode live `gitStatus:` preamble, verbatim).
- Not a git repo, timeout, or any probe failure → omit (never throws).
- Timeout budget ~1.5s across the probe sequence.
- Testable: injectable `Runner` plus `formatSnapshot` / `parseOriginHead` / `capLines` / `isInsideWorkTree`.

`AgentSystemPromptComposer.Input.gitStatusSnapshot`:

| value | effect |
|---|---|
| non-empty string | injected as-is |
| `""` / whitespace | omit the block |
| `nil` | capture once from `worktreeRootURL ?? projectRoot`, cached per `conversation.id` |

Agent mode only (`composeRaw` / chat mode stays empty). No `AgentLoop` edit.

### Behavior sections (PARITY §4 item 3)

New `Sources/AgentCore/Agent/ZCodeBehaviorPrompt.swift` — public constants, copied from `~/zcode-reverse/live-system-prompt-raw.md` block 2. No "ZCode" product-name occurrences in these sections, so no wording was adapted.

Injected in harnessed (agent) compose, after the date notice:

1. `# Communicating with the user` — teammate voice, final-message-of-turn, lead-with-outcome, no jargon compression
2. `# Context management` — summarize-and-continue; don't wrap up early
3. `# Autonomous mode` — user not watching; proceed on reversible work
4. `# Pre-end-of-turn self-check` — last paragraph is a plan/promise → do the work now

Headings 3 and 4 are labels around verbatim ZCode paragraphs (those two had no `#` heading in the live blob).

## Wave-2 wiring

**None required.** `AgentLoop` already calls `AgentSystemPromptComposer.compose` every iteration. With `gitStatusSnapshot: nil` (the synthesized default) the composer captures on first compose and reuses the cache, so the snapshot stays frozen for the process lifetime of that conversation.

Optional later (loop owner, not this wave): pre-capture at turn start and pass `gitStatusSnapshot:` so the first compose does no git I/O. Not needed for behavior.

Do not touch `AppSettings` / `ToolRegistry`.

## Tests

`Tests/AgentCoreTests/ParityPromptComposerTests.swift`

```
swift test --filter ParityPromptComposerTests
```

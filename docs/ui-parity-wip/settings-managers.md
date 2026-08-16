# U4 `settings-managers` — shipped

ZCode Settings → Agent capabilities: **Skills** + **Subagents** managers.
Harness discovery is unchanged (`SkillDiscovery`, `AgentDefinitionDiscovery`,
`SubagentType` / `SubagentCatalog`). This wave is UI + disk write helpers only.

## Settings tabs (`SettingsViewV2`)

Private `SettingsTab` now includes:

| case | label | icon | subtitle | group |
|---|---|---|---|---|
| `skills` | Skills | `sparkles` | Discover & enable | Agent |
| `subagents` | Subagents | `person.2` | Profiles & tools | Agent |

Deep-link `initialTabRaw` `"skills"` / `"subagents"` works via `rawValue`.
`SettingsManagersTabID` mirrors those ids for tests.

Agent group order: Agent → Skills → Subagents → Hooks.

## Skills (`SkillsSettingsView`)

- Lists `SkillDiscovery.discover` (project + user + bundled, metadata-only).
- Groups: **Workspace and personal skills** vs **Bundled** (read-only toggle).
- Search + All / Enabled / Disabled (`isModelInvocable`).
- Enable/disable rewrites SKILL.md frontmatter
  `disable-model-invocation: true/false` (`SkillFrontmatterWriter`).
- Scope segmented **Project / User** (same pattern as Hooks).
- **New skill** writes `<root>/<slug>/SKILL.md`.
- **Import** copies a picked `SKILL.md` or skill folder into the active root.
- **Open skills folder** / Reveal via `NSWorkspace`.
- Disk is the source of truth — no parallel store.

## Subagents (`SubagentsSettingsView`)

- **User** — `~/.vibecoder/agents/*.md`
- **Workspace** — `<project>/.vibecoder/agents/*.md` (editable; VC advantage)
- **Built-in** — `SubagentType.allCases` (general-purpose / explore / plan),
  read-only, with default tools and the hint
  “Built-in profiles are runtime defaults and cannot be edited here.”
- Form writes YAML that `AgentDefinitionDiscovery.parse` already accepts:
  `name`, `description`, optional `model` / `maxTurns` / `background`,
  body = system prompt.
- **Inherit all tools** omits the `tools:` key (empty `tools:` stays fail-closed).
- Custom tools write `tools: a, b, c`.
- New / Edit / Delete (confirm) / **Open user subagents folder**.
- Search; empty copy **No subagents found**; footer `{total} subagents`.

## Helpers (`App/Utilities/SettingsManagersSupport.swift`)

- `SettingsManagersNaming` — letters / numbers / hyphens; slugify for skills.
- `SkillFrontmatterWriter` — enable rewrite, new skill, import.
- `SubagentProfileCodec` — encode / write / load directory / inherit-all detect.
- Paths under `~/.vibecoder/{skills,agents}` and project `.vibecoder/…`.

## Tests (`SettingsManagersUITests`)

- Frontmatter write/parse round-trip via `AgentDefinitionDiscovery.parse` (temp dir).
- Inherit-all omits `tools:`; explicit empty `tools:` is not inherit-all.
- Name validation rejects spaces / slashes.
- Skill enable rewrite flips `disable-model-invocation` (string + disk).
- Built-in types are the three `SubagentType` cases.
- Settings tab rawValues `skills` / `subagents`.

## Out of scope

No AgentCore discovery edits, no RootView / VibeCoderApp / Inspector / Chat
glue, no marketplace. Parent chrome does not need extra wiring — Settings
already hosts `SettingsViewV2` and `initialTabRaw`.

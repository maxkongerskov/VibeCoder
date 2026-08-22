# VibeCoder unattended pipeline

Three weekday Orca automations, one job each. They do not call each other.
They hand off through files in this folder.

| Role | When (Copenhagen) | Writes | Must not |
|---|---|---|---|
| **Researcher** | weekdays 09:00 | `proposals/*.md` with `status: proposed` | implement, merge, push app code |
| **Reviewer** | weekdays 12:00 | only the `status` / `verdict` fields | implement, rubber-stamp |
| **Builder** | weekdays 16:00 | a git branch `auto/<date>-<slug>` | merge `main`, delete Max's WIP |

## Proposal file

`docs/automation/proposals/YYYY-MM-DD-<slug>.md`

```yaml
---
status: proposed   # proposed | approved | rejected | implemented | reverted | skipped
slice: one-line name
out_of_scope: true if this would touch phone, LAN remote, local VM, CloudBots, Electron, mlx-swift, Sparkle
---
```

Statuses:

- `proposed` — researcher only
- `approved` / `rejected` — reviewer only
- `implemented` / `reverted` — builder only
- `skipped` — researcher had nothing worth proposing today

## Hard freeze (from PLAN.md)

Do not propose or implement: phone pairing, LAN remote, local VM (Lima/Tart),
CloudBots platform work, Electron, mlx-swift, bundled llama.cpp, Sparkle,
Sentry, license keys.

Prefer small opt-in slices that match `ARCHITECTURE.md` §1 (local BYO HTTP
coding agent). Default off. Fail closed.

## Builder rules

- Act on **at most one** `status: approved` file per run.
- Work on a **new worktree / branch from `main`**, never Max's dirty checkout.
- Run tests. Then critique the diff as a hostile reviewer.
- Substantial defect you cannot fix in this run → `git reset --hard`, `status: reverted`.
- Success → leave the branch (draft PR is allowed). **Never merge to `main`.**

---
id: PLAN-002
date: 2026-05-02
status: implemented
type: feature
mode: lightweight
summary: Add interactive branch-name prompt to /implement's Step 2.5 — user accepts or overrides the auto-derived name. Autopilot flows unchanged.
---

## Task

Refine the `/implement` Step 2.5 (Branch Creation) added by PLAN-001 so that, instead of silently auto-creating the derived branch, it shows the derived name as a SUGGESTION, prompts the user for an alternative, and uses whichever they pick. `/autopilot`, `/autopilot-from implement`, and `/autopilot-from plan` continue to auto-derive silently — their hands-free contract is non-negotiable.

## Approach

Edit `.claude/commands/implement.md` Step 2.5 only. The existing branch-creation bash block stays mostly intact; rename `target_branch=...` to `SUGGESTED_BRANCH=...`, then surround it with prose that tells Claude to present the suggestion to the user, read their reply, sanitize+validate any custom name, and set the final `target_branch` from the user's choice (or the suggestion if they accept). The branch-already-exists check still applies after the chosen name; update the error message to say "try a different name" since the user can pick.

**Sanitize pipeline for custom branch names** (looser than project-name sanitize because `/` is allowed for prefixes like `feature/`):

```
lowercase → spaces/underscores → hyphens → strip non-[a-z0-9-/] → collapse runs of '-' → trim leading/trailing '-' → reject if empty
```

After sanitize, validate with `git check-ref-format --branch <name>`. On failure, re-prompt up to 3 times before bailing.

Mirror the updated `implement.md` to `C:\Users\saura\.claude\commands\implement.md`. Update README.md's "Git Branching" subsection to document the prompt in `/implement`, keep the auto-derive description for autopilot flows.

`/autopilot.md` and `/autopilot-from.md` are NOT touched.

## Affected Components

- `.claude/commands/implement.md` — Step 2.5 prose + bash block
- `C:\Users\saura\.claude\commands\implement.md` — mirror
- `README.md` — Git Branching subsection updated to differentiate `/implement` (prompt) vs autopilot (auto-derive)

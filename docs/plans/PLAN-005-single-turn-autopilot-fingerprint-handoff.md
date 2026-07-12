---
id: PLAN-005
date: 2026-07-12
status: implemented
type: bugfix
mode: lightweight
summary: Stop hook re-triggers qa/doc agents after single-turn autopilot runs because the fingerprint is never saved; add a finished-marker handoff from autopilot cleanup to the hook.
---

## Task

Fix the redundant Stop-hook fire that occurs after an autopilot run completes within a single turn. Observed live: a `/autopilot-from implement PLAN-004` run created and removed the sentinel inside one turn, so the hook's sentinel bypass (which saves the fingerprint) never executed — Stop only fires between turns. The first post-run Stop then saw `install.sh` as unprocessed changes and re-triggered qa-expert + doc-maintainer on work the run had already tested and documented.

## Approach

The autopilot command cannot save the fingerprint itself: the fingerprint file is keyed by `session_id`, which only the hook receives (via stdin JSON). So the fix is a handoff marker. At cleanup, autopilot touches `.claude/.autopilot-finished` before removing `.claude/.autopilot-active`. On the next Stop fire, the hook sees the marker, computes and saves the fingerprint (identical logic to the existing sentinel bypass), consumes the marker, and exits 0. Subsequent Stops dedup via the saved fingerprint as designed. The early-bail path (branch exists) keeps its plain `rm` — no agents ran, nothing to dedup. The marker is consume-on-first-sight, so no staleness window; the deliver block's runtime-state reset also excludes it from commits, and the bootstrap `.gitignore` heredocs (3 copies) plus this repo's `.gitignore` gain the marker entry.

## Affected Components

- `.claude/hooks/update-docs.sh` — new finished-marker consumption block after the sentinel bypass
- `.claude/commands/autopilot.md` — Step 5 cleanup handoff; sentinel prose; `.gitignore` heredoc; deliver-block reset line
- `.claude/commands/autopilot-from.md` — same four edits
- `.claude/commands/build-plan.md` — `.gitignore` heredoc
- `.gitignore` — add `.claude/.autopilot-active` and `.claude/.autopilot-finished`
- `README.md`, `docs/architecture.md` — dedup-mechanism descriptions gain the marker

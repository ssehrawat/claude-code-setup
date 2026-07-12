Review the current working-tree code changes. Optional focus hint: $ARGUMENTS

This is MANUAL MODE. One review pass, human decides what happens next.

1. Delegate to the **reviewer** subagent to critique the working-tree diff (`git diff HEAD` plus untracked files) against `.claude/CLAUDE.md` standards. If $ARGUMENTS names a plan ID or specific files, pass that along as the review focus.
2. Print the reviewer's full Review Report verbatim — Verdict, Blockers, Should-fix, Nits, and the final `REVIEW_VERDICT=...` line.
3. Tell the human their next step and STOP:
   - Verdict `approve` → "Review passed. Commit when ready."
   - Verdict `changes-requested` → "Address the blockers, then re-run `/review` to verify."

## CRITICAL RULES

- This command is REVIEW ONLY. NEVER delegate to the engineer agent or any other agent besides the single reviewer invocation.
- NEVER auto-fix findings. NEVER write or edit any source file.
- NEVER loop: one reviewer pass per run. If the human wants a re-review after fixing, they run `/review` again. (The bounded fix/re-review loop exists only in `/autopilot` Step 2.5 — manual mode means the human drives.)
- Print the report as-is — do not summarize away findings or soften severities.

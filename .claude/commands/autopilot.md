AUTOMODE — Run the full development pipeline automatically for: $ARGUMENTS

Execute ALL steps below in order. Do NOT stop between steps. Do NOT ask for confirmation. Complete the entire chain autonomously.

**IMPORTANT — Sentinel file:** Before starting, create `.claude/.autopilot-active` to prevent the Stop hook from double-triggering the test/doc agents. Delete it after the final step. Note: stale sentinels older than 2 hours are auto-cleaned by the Stop hook, so a crash won't permanently block agent triggers.

```bash
mkdir -p .claude && touch .claude/.autopilot-active
```

---

## Step 1: Plan (with self-review)

Delegate to the **planner** subagent. The "AUTOMODE" keyword above tells it to operate in auto mode:
- Read the codebase thoroughly
- Make best-judgment decisions (no human Q&A)
- Write the plan to `./docs/plans/PLAN-{NNN}-{slug}.md` (relative to project root, NOT ~/.claude/)
- Document all assumptions and decisions explicitly
- Self-review the plan: check completeness, feasibility, consistency, risk blind spots, scope discipline
- Fix any issues found during self-review
- Set status to `approved`

Read the plan back after it's created. You need it for Step 2.

## Step 1.5: Plan Validation

After the planner finishes, YOU (the main agent) also review the plan as a sanity check:
- Does the plan actually address what was requested in "$ARGUMENTS"?
- Are the implementation steps concrete enough for the engineer to execute?
- Are there obvious gaps or contradictions?
- If you find issues, edit the plan to fix them before proceeding.

## Step 2: Implement

Delegate to the **engineer** subagent:
- Read the plan from Step 1
- Read the existing codebase to understand patterns and conventions
- Implement everything specified in the plan with production-grade quality
- Update the plan status to `implemented` when done

## Step 3: Test

Delegate to the **qa-expert** subagent:
- Review all code written in Step 2
- Write comprehensive test cases covering normal paths, edge cases, and error conditions
- Run the test suite to verify everything passes
- If tests fail, fix the code or tests until green
- Check eval coverage if `evals/` exists

## Step 4: Document

Delegate to the **doc-maintainer** subagent:
- Review all changes from Steps 2 and 3
- Create or update ALL applicable documentation following the agent's own policy:
  - **Always create if missing:** CLAUDE.md, README.md, docs/architecture.md, docs/api.md (if project has endpoints)
  - **Create if applicable:** docs/workflows.md, docs/frontend.md, docs/backend.md, .env.example
  - **Update if changed:** any existing doc affected by the code changes
- Do NOT skip doc creation for "first-time" projects — this is exactly when those essential docs should be written

## Step 5: Summary & Cleanup

Provide a final summary first, THEN remove the sentinel:

```
## Autopilot Summary

### Plan
- ID: PLAN-{NNN}
- File: /docs/plans/PLAN-{NNN}-{slug}.md
- Self-review: {issues caught and fixed, or "clean"}

### Implementation
- Files created: {list}
- Files modified: {list}

### Tests
- Tests written: {count}
- Test files: {list}
- All passing: {yes/no}

### Documentation Updated
- {list of docs updated}

### Issues / Warnings
- {anything that needs human attention}
```

Now remove the sentinel file (must be the very last action):
```bash
rm -f .claude/.autopilot-active
```

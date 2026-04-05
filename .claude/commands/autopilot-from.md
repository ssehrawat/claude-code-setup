AUTOMODE — Resume the autopilot pipeline from a specific stage for: $ARGUMENTS

Parse the FIRST word of $ARGUMENTS (after "AUTOMODE") to determine the starting stage. The rest is the task description or plan reference.

**Stage keywords** (case-insensitive):
- `plan` → Start from Step 1 (Plan → Review → Implement → Test → Docs)
- `implement` → Start from Step 2 (Implement → Test → Docs). Requires a plan ID like PLAN-001.
- `test` → Start from Step 3 (Test → Docs). Assumes code is already written.
- `docs` → Start from Step 4 (Docs only). Assumes code and tests are done.

**Examples:**
- `/autopilot-from plan add user authentication` → full pipeline
- `/autopilot-from implement PLAN-003` → skip planning, implement from existing plan
- `/autopilot-from test PLAN-003` → skip planning and coding, run tests and docs
- `/autopilot-from docs` → only update documentation for recent changes

---

**IMPORTANT — Sentinel file:** Before starting, create `.claude/.autopilot-active` to prevent the Stop hook from double-triggering. Delete it at the end.

```bash
mkdir -p .claude && touch .claude/.autopilot-active
```

Execute ALL steps from the starting stage through the end. Do NOT stop between steps. Do NOT ask for confirmation.

---

## Step 1: Plan with self-review (skip if starting after this stage)

Delegate to the **planner** subagent. The "AUTOMODE" keyword above tells it to operate in auto mode:
- Read the codebase, make best-judgment decisions
- Write the plan to `./docs/plans/` (relative to project root, NOT ~/.claude/), document assumptions, self-review, fix issues
- Set status to `approved`

Read the plan back. You need it for Step 2.

### Step 1.5: Plan Validation (skip if starting after plan stage)

After the planner finishes, YOU (the main agent) also review the plan:
- Does it address the original request?
- Are steps concrete enough for the engineer?
- Any gaps or contradictions?
- Fix issues in the plan before proceeding.

## Step 2: Implement (skip if starting after this stage)

Delegate to the **engineer** subagent:
- If a plan ID was specified (e.g., PLAN-003), read that plan from `/docs/plans/`
- If coming from Step 1, use the plan just created
- Read the existing codebase to understand patterns and conventions
- Implement everything with production-grade quality
- Update the plan status to `implemented`

## Step 3: Test (skip if starting after this stage)

Delegate to the **qa-expert** subagent:
- Review all recently changed code (use `git diff` to identify)
- Write comprehensive test cases covering normal paths, edge cases, and error conditions
- Run the test suite to verify everything passes
- If tests fail, fix the code or tests until green
- Check eval coverage if `evals/` exists

## Step 4: Document

Delegate to the **doc-maintainer** subagent:
- Review all recent changes
- Create or update ALL applicable documentation following the agent's own policy:
  - **Always create if missing:** CLAUDE.md, README.md, docs/architecture.md, docs/api.md (if project has endpoints)
  - **Create if applicable:** docs/workflows.md, docs/frontend.md, docs/backend.md, .env.example
  - **Update if changed:** any existing doc affected by the code changes
- Do NOT skip doc creation for "first-time" projects — this is exactly when those essential docs should be written

## Step 5: Summary & Cleanup

Provide a summary first, THEN remove the sentinel:

```
## Autopilot Summary (from {starting_stage})

### Plan (if ran)
- ID: PLAN-{NNN}
- File: /docs/plans/PLAN-{NNN}-{slug}.md
- Self-review: {issues caught and fixed, or "clean"}

### Implementation (if ran)
- Files created: {list}
- Files modified: {list}

### Tests (if ran)
- Tests written: {count}
- Test files: {list}
- All passing: {yes/no}

### Documentation Updated (if ran)
- {list of docs updated}

### Issues / Warnings
- {anything that needs human attention}
```

Now remove the sentinel file (must be the very last action):
```bash
rm -f .claude/.autopilot-active
```

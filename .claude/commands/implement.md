Implement the following: $ARGUMENTS

---

## Step 1: Check for existing plan

Check if $ARGUMENTS references an existing plan ID (e.g., "PLAN-001" or "PLAN-003"):

**If a plan ID is referenced:**
- Read that plan from `./docs/plans/`
- Follow it for implementation
- Skip to Step 3

**If NO plan ID is referenced:**
- Proceed to Step 2 (complexity check)

---

## Step 2: Complexity check

Before doing anything, assess the scope of the request. Read the codebase to understand what would need to change.

**Evaluate these signals:**
- How many files will need to be created or modified? (estimate)
- Does this introduce a new module, service, or architectural pattern?
- Does this change existing APIs, data models, or interfaces that other code depends on?
- Does this require new dependencies or infrastructure?
- Does this involve migration of existing data or behavior?
- Could there be multiple valid approaches that need evaluation?

**If the task is SMALL (meets ALL of these):**
- Touches ≤ 4 files
- No new modules or architectural patterns
- No API/schema/interface changes that affect other code
- No new dependencies or infrastructure
- Straightforward approach, no ambiguity

→ Create a **lightweight plan** for traceability and proceed to Step 3.

Create `./docs/plans/` if it doesn't exist: `mkdir -p ./docs/plans`
Find the next PLAN-{NNN} ID and write:

```markdown
---
id: PLAN-{NNN}
date: {YYYY-MM-DD}
status: in-progress
type: {feature|bugfix|refactoring}
mode: lightweight
summary: {one-line description}
---

## Task
{1-2 sentences describing what will be implemented}

## Approach
{1 paragraph — the technical approach, key decisions, files to modify}

## Affected Components
{Short list of files/modules that will change}
```

**If the task is LARGE (any ONE of these is true):**
- Touches 5+ files
- Introduces new modules, services, or architectural patterns
- Changes APIs, data models, or interfaces other code depends on
- Requires new dependencies or infrastructure changes
- Multiple valid approaches that need evaluation
- Involves migration of existing data or behavior

→ Do NOT create a lightweight plan. Do NOT start implementing. Instead, tell the user:

"This looks like a substantial change that would benefit from a detailed plan first. Here's what I see:

- **Scope:** {brief description of what would need to change}
- **Why it needs a plan:** {which complexity signals triggered}

Run `/plan {original request}` to go through the full planning process with Q&A, or if you're confident about the approach, run `/autopilot-from plan {original request}` to auto-plan and implement.

If you're sure you want to skip planning, reply 'proceed anyway' and I'll create a lightweight plan and implement."

If the user replies "proceed anyway" (or similar), create a lightweight plan and proceed to Step 3.

---

## Step 3: Implement

Delegate to the **engineer** subagent with:
- The plan (full or lightweight) as context
- The original request: $ARGUMENTS
- Instruction to implement with production-grade quality

---

## Step 4: Update plan status

After implementation, update the plan's status to `implemented`.

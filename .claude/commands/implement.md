Implement the following: $ARGUMENTS

---

## Step 0: Non-project guard

Before anything else, check whether the current working directory looks like an existing project. `/implement` presupposes a plan to implement — it must NOT bootstrap a fresh project the way `/build-plan` and `/autopilot` do.

Run this detection block exactly (identical to `/build-plan` Phase 0 — three entry points must agree on what "a project" means):

```bash
# Detect "non-project" cwd.
# Trigger conditions (ALL must be true):
#   - no recognized manifest in cwd
#   - no .git directory
#   - fewer than 3 non-hidden top-level entries

NEEDS_BOOTSTRAP=0
if [ ! -f package.json ] && [ ! -f pyproject.toml ] && [ ! -f go.mod ] && [ ! -f Cargo.toml ] && [ ! -d .git ]; then
  # Count non-hidden top-level entries (files + dirs, not dotfiles).
  entry_count=$(ls -1 2>/dev/null | wc -l | tr -d ' ')
  if [ "${entry_count:-0}" -lt 3 ]; then
    NEEDS_BOOTSTRAP=1
  fi
fi
echo "NEEDS_BOOTSTRAP=$NEEDS_BOOTSTRAP"
```

**If `NEEDS_BOOTSTRAP=0`:** Proceed to Step 1 unchanged.

**If `NEEDS_BOOTSTRAP=1`:** Print exactly this and STOP — do not proceed to Step 1, do not create a plan, do not invoke the engineer:

```
This directory is not a project and has no plan to implement.
Start with:  /build-plan <what you want>   (manual planning)
        or:  /autopilot <what you want>    (hands-free plan → build)
```

WHY refuse-and-redirect instead of bootstrapping: bootstrapping silently here would produce a repo whose first commit is engineer output with no plan and no branch policy — inconsistent with every other entry point. `/build-plan` and `/autopilot` own the bootstrap path.

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

Run `/build-plan {original request}` to go through the full planning process with Q&A, or if you're confident about the approach, run `/autopilot-from plan {original request}` to auto-plan and implement.

If you're sure you want to skip planning, reply 'proceed anyway' and I'll create a lightweight plan and implement."

If the user replies "proceed anyway" (or similar), create a lightweight plan and proceed to Step 3.

---

## Step 2.5: Branch Creation

Before delegating to the engineer, create a feature branch from the plan's frontmatter so engineer-written changes land off `main`/`master`. In `/implement` (manual mode) the user is prompted with the auto-derived name as a suggestion and may override it. Autopilot flows handle their own silent derivation in their own commands — this step is `/implement`-specific.

**Resolve the plan file path.** There are two cases:
1. **Existing PLAN-NNN was passed in `$ARGUMENTS`** (e.g. `/implement PLAN-007`): glob `./docs/plans/PLAN-NNN-*.md`. If zero matches, error out with "No plan file found for PLAN-NNN". If multiple matches, error out with "Multiple plan files matched PLAN-NNN — refusing to guess".
2. **Lightweight plan was just written in Step 2:** the path is the file you wrote moments ago (you know it from the immediately-prior write). Use it directly.

### Step 2.5a: Skip-conditions and suggestion derivation

Run the block below with the resolved plan file path passed as `$1`. This block evaluates skip conditions and derives a suggested branch name; it does NOT create the branch.

```bash
# Inputs: the plan file path, e.g. ./docs/plans/PLAN-001-add-auth.md
PLAN_FILE="$1"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "BRANCH_ACTION=skip-not-in-repo"
  exit 0
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ] && [ "$current_branch" != "master" ]; then
  echo "BRANCH_ACTION=skip-already-on-feature:$current_branch"
  exit 0
fi

# Parse plan frontmatter for id and type.
# Frontmatter is between two lines of exactly '---'. The tr pipeline strips
# any surrounding single or double quotes so `type: "feature"` and
# `type: feature` both parse identically; lowercasing on type lets
# `type: Bugfix` map correctly.
plan_id=$(awk '/^---$/{f++; next} f==1 && /^id:/ {print $2; exit}' "$PLAN_FILE" | tr -d '"' | tr -d "'")
plan_type=$(awk '/^---$/{f++; next} f==1 && /^type:/ {print $2; exit}' "$PLAN_FILE" | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')

if [ -z "$plan_id" ] || [ -z "$plan_type" ]; then
  echo "ERROR: could not parse id/type from $PLAN_FILE frontmatter"
  exit 1
fi

# Derive slug from filename: PLAN-001-add-auth.md -> add-auth
plan_basename=$(basename "$PLAN_FILE" .md)
slug=$(printf '%s' "$plan_basename" | sed -E "s/^${plan_id}-//")
# WHY: no case-insensitive flag — plan IDs are always uppercase ("PLAN-001") and
# filenames match. The GNU sed -I flag is unsupported on BSD sed (macOS), so
# omitting it keeps this portable across Git Bash on Windows and macOS/Linux.

case "$plan_type" in
  feature|design) prefix="feature" ;;
  bugfix)        prefix="fix" ;;
  refactoring)   prefix="refactor" ;;
  *)             prefix="feature" ;;
esac

SUGGESTED_BRANCH="${prefix}/${plan_id}-${slug}"
echo "SUGGESTED_BRANCH=${SUGGESTED_BRANCH}"
```

### Step 2.5b: Branch from `BRANCH_ACTION` line

Read the block's output:
- `BRANCH_ACTION=skip-not-in-repo` or `BRANCH_ACTION=skip-already-on-feature:*` → skip the prompt entirely and continue to Step 3. Do NOT show a suggestion. Do NOT run the second bash block.
- `ERROR: ...` (exit 1) → STOP the pipeline and surface the error verbatim.
- `SUGGESTED_BRANCH=<name>` → proceed to Step 2.5c.

### Step 2.5c: Prompt the user

Capture `SUGGESTED_BRANCH` from the previous block's output. Show the user this exact prompt and wait for their reply:

```
Suggested branch: <SUGGESTED_BRANCH>
Press Enter to accept, or type a different name (e.g. fix/auth-bug, feature/team/auth):
```

Decide the chosen name:
1. **Empty reply** (user pressed Enter) → set `CHOSEN_BRANCH = SUGGESTED_BRANCH`. Skip directly to Step 2.5e.
2. **Non-empty reply** → run the sanitize block in Step 2.5d with the raw input as `$1`, then validate.

### Step 2.5d: Sanitize and validate user input (re-prompt up to 3 times)

Run this block with the raw user reply as `$1`. The pipeline is intentionally looser than project-name sanitize — `/` is preserved because branch prefixes use it (e.g. `feature/team/auth`).

```bash
# $1 = raw user input
SANITIZED=$(printf '%s' "$1" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed -E 's/[^a-z0-9/-]//g; s/-+/-/g; s/^-+//; s/-+$//')

if [ -z "$SANITIZED" ]; then
  echo "ERROR: branch name is empty after sanitization"
  exit 3
fi

if ! git check-ref-format --branch "$SANITIZED" >/dev/null 2>&1; then
  echo "ERROR: $SANITIZED is not a valid git branch name"
  exit 3
fi

echo "CHOSEN_BRANCH=${SANITIZED}"
```

Branch on the result:
- `CHOSEN_BRANCH=<name>` → proceed to Step 2.5e with that name.
- `ERROR: ...` (exit 3) → re-prompt the user, showing the sanitized form (if any) and the failure reason. Allow up to **3 total attempts**. After the 3rd failed attempt, STOP the pipeline with:
  ```
  ERROR: could not obtain a valid branch name after 3 attempts.
  Resolution: re-run /implement and supply a name matching git's branch ref format (e.g. feature/auth, fix/PLAN-007-cors).
  ```
  Do NOT invoke the engineer.

### Step 2.5e: Create the branch

Run this block with the chosen branch name as `$1`.

```bash
# $1 = user-chosen branch name (or accepted suggestion)
CHOSEN="$1"
if git rev-parse --verify "$CHOSEN" >/dev/null 2>&1; then
  echo "ERROR: branch $CHOSEN already exists"
  echo "Resolution: try a different name, delete the old branch (git branch -D $CHOSEN), or supersede the plan."
  exit 2
fi
git checkout -b "$CHOSEN"
echo "BRANCH_ACTION=created:$CHOSEN"
```

Read the result:
- `BRANCH_ACTION=created:*` → continue to Step 3 and mention the new branch in the user-facing summary.
- `ERROR: branch ... already exists` (exit 2) → re-prompt the user for a different name and loop back to Step 2.5d. The "branch already exists" attempt counts toward the same 3-attempt budget as sanitize/validate failures. After exhausting the budget, STOP the pipeline and surface the error verbatim. Do NOT invoke the engineer.

---

## Step 3: Implement

Delegate to the **engineer** subagent with:
- The plan (full or lightweight) as context
- The original request: $ARGUMENTS
- Instruction to implement with production-grade quality

---

## Step 4: Update plan status

After implementation, update the plan's status to `implemented`.

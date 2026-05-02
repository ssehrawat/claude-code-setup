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

## Step 0: Bootstrap Detection (only when starting stage is `plan`)

If the starting stage is `plan`, run bootstrap detection BEFORE creating the sentinel — same logic as `/autopilot` Step 0. For starting stages `implement`, `test`, `docs`, SKIP this section entirely and create the sentinel as today (the block below this section).

When starting stage is `plan`:

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

**If `NEEDS_BOOTSTRAP=0`:** Skip to sentinel creation below.

**If `NEEDS_BOOTSTRAP=1`:** Auto-derive the project name from the task description portion of `$ARGUMENTS` (everything after the `plan` keyword), passed as `$1`:

```bash
# Inputs: the raw $ARGUMENTS string passed to /autopilot.
DESCRIPTION="$1"
NAME=$(printf '%s' "$DESCRIPTION" \
  | cut -d' ' -f1-4 \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-+//; s/-+$//')
if [ -z "$NAME" ]; then
  NAME="new-project"
fi
echo "AUTO_NAME=$NAME"
```

Read `AUTO_NAME` and feed it as `$1` to the bootstrap execution block:

```bash
# Sanitize the proposed name. Pipeline:
#   lowercase -> spaces/underscores to hyphens -> strip everything outside
#   [a-z0-9-] -> collapse runs of hyphens -> trim leading/trailing hyphens.
PROPOSED_NAME="$1"  # passed in by Claude after prompt or auto-derivation
SANITIZED=$(printf '%s' "$PROPOSED_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | tr ' _' '--' \
  | sed -E 's/[^a-z0-9-]//g; s/-+/-/g; s/^-+//; s/-+$//')

if [ -z "$SANITIZED" ]; then
  echo "ERROR: project name produced empty string after sanitization"
  exit 1
fi

if [ -e "$SANITIZED" ]; then
  echo "ERROR: ./$SANITIZED already exists"
  exit 1
fi

mkdir "$SANITIZED"
cd "$SANITIZED"
git init -q -b main 2>/dev/null || git init -q  # -b main on git >=2.28; fallback for older
# If git defaulted to master, rename to main for consistency
current=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
if [ "$current" = "master" ]; then
  git branch -M main
fi

cat > .gitignore <<'EOF'
node_modules/
dist/
build/
__pycache__/
*.pyc
.env
.env.local
.DS_Store
.claude/.autopilot-active
.claude/settings.local.json
EOF

# Verify git identity is configured before attempting the initial commit.
# Without this guard, `git commit` on a fresh machine fails with
# "Please tell me who you are" — which is opaque inside an automated pipeline.
if ! git config --get user.email >/dev/null 2>&1 || ! git config --get user.name >/dev/null 2>&1; then
  echo "ERROR: git identity not configured."
  echo "Run: git config --global user.email \"you@example.com\" && git config --global user.name \"Your Name\""
  echo "Then retry the command. The directory ./$SANITIZED has been created — delete it with: cd .. && rm -rf $SANITIZED"
  exit 1
fi

git add .gitignore && git commit -q -m "Initial commit"
echo "BOOTSTRAPPED=$SANITIZED"
pwd
```

Read `pwd`. The new directory is the project root for all subsequent steps. If bootstrap failed, surface the error and stop (the sentinel was never created — nothing to clean up).

---

**IMPORTANT — Sentinel file:** Now (in the possibly-new cwd) create `.claude/.autopilot-active` to prevent the Stop hook from double-triggering. Delete it at the end. Note: stale sentinels older than 2 hours are auto-cleaned by the Stop hook, so a crash won't permanently block agent triggers.

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

## Step 1.75: Branch Creation (only when starting stage is `plan` or `implement`)

**Skip this step entirely when starting stage is `test` or `docs`.** Those stages assume code is already written on the user's chosen branch and must not auto-checkout anything.

When starting stage is `plan` or `implement`, run the branch-creation block below with the resolved plan file path passed as `$1`. For starting stage `implement`, the plan path is derived from the PLAN-NNN argument (glob `./docs/plans/PLAN-NNN-*.md`). For starting stage `plan`, the plan path is the file the planner just wrote in Step 1.

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

target_branch="${prefix}/${plan_id}-${slug}"

if git rev-parse --verify "$target_branch" >/dev/null 2>&1; then
  echo "ERROR: branch $target_branch already exists"
  echo "Resolution: delete the old branch (git branch -D $target_branch) or supersede the plan with a new ID."
  exit 2
fi

git checkout -b "$target_branch"
echo "BRANCH_ACTION=created:$target_branch"
```

Read `BRANCH_ACTION`:
- `skip-not-in-repo` or `skip-already-on-feature:*` → continue silently to Step 2.
- `created:*` → continue to Step 2 and mention in the final summary.
- exit 2 (branch exists) → STOP the pipeline. **Before exiting, remove the autopilot sentinel** so subsequent runs aren't blocked:

```bash
rm -f .claude/.autopilot-active
```

Then surface the error message verbatim and stop.

## Step 2: Implement (skip if starting after this stage)

Delegate to the **engineer** subagent:
- If a plan ID was specified (e.g., PLAN-003), read that plan from `/docs/plans/`
- If coming from Step 1, use the plan just created
- Read the existing codebase to understand patterns and conventions
- Implement everything with production-grade quality
- Update the plan status to `implemented`

## Step 3: Test (skip if starting after this stage)

Before delegating to qa-expert, run:

```bash
non_md=$(git diff --name-only HEAD; git ls-files --others --exclude-standard)
if printf '%s\n' "$non_md" | grep -v '\.md$' | grep -q .; then
  echo "MD_ONLY=0"
else
  echo "MD_ONLY=1"
fi
```

If `MD_ONLY=1`, skip Step 3 entirely — do NOT delegate to qa-expert — and proceed directly to Step 4 (Document). Record this in the Step 5 summary as `Tests: skipped (markdown-only)`.

If `MD_ONLY=0`, delegate to qa-expert as normal (the existing instructions below).

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
- {one of the following lines, depending on whether Step 3 ran:}
  - `All passing: {yes/no}` (when qa-expert ran)
  - `Skipped: markdown-only change set, no automated tests applicable` (when Step 3 was bypassed)

### Documentation Updated (if ran)
- {list of docs updated}

### Issues / Warnings
- {anything that needs human attention}
```

Now remove the sentinel file (must be the very last action):
```bash
rm -f .claude/.autopilot-active
```

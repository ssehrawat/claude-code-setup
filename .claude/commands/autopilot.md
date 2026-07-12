AUTOMODE — Run the full development pipeline automatically for: $ARGUMENTS

Execute ALL steps below in order. Do NOT stop between steps. Do NOT ask for confirmation. Complete the entire chain autonomously.

---

## Flag Parsing (run before Step 0)

`$ARGUMENTS` may contain delivery flags mixed into the task description. Strip them FIRST, before anything else reads `$ARGUMENTS`. Run this block with the raw `$ARGUMENTS` string as `$1`:

```bash
# Inputs: the raw $ARGUMENTS string. Recognized flags may appear anywhere in it.
# WHY strip before name/task derivation: "--deliver add auth" would otherwise
# leak into the Step 0 auto-derived project name ("deliver-add-auth") and the
# Step 1 planning brief.
RAW_ARGS="$1"
DELIVER=0
DEPLOY=0
TASK=""
# WHY set -f: the unquoted $RAW_ARGS word-split is intentional, but without
# noglob a task containing * or ? would expand to cwd filenames and corrupt
# the task text (and the Step 0 auto-derived project name).
set -f
for word in $RAW_ARGS; do
  case "$word" in
    --deliver) DELIVER=1 ;;
    --deploy)  DEPLOY=1; DELIVER=1 ;;  # --deploy implies --deliver
    *)         TASK="$TASK $word" ;;
  esac
done
set +f
TASK=${TASK# }
echo "DELIVER=$DELIVER"
echo "DEPLOY=$DEPLOY"
echo "TASK=$TASK"
```

Use `TASK` (the flag-stripped remainder) as the task description everywhere below that refers to `$ARGUMENTS` — Step 0 auto-naming and the Step 1 planning brief. `DELIVER=1` activates Step 4.5. `DEPLOY=1` currently only implies `--deliver`; the deploy stage itself is Phase 3 of the outer-loop plan and is a no-op today.

Outward-facing actions (commit, push, PR) are OFF by default: with no flag, this pipeline never touches a remote — identical to a run before delivery existed. The upfront flag IS the confirmation, so the run stays hands-free either way and no mid-run prompt is ever needed.

---

## Step 0: Bootstrap Detection

Before creating the autopilot sentinel or invoking any subagent, check whether the cwd looks like an existing project. If not, auto-derive a project name from `$ARGUMENTS` and bootstrap a fresh project directory. There is NO human Q&A in autopilot mode — the name is derived deterministically from the task description.

Run the detection block:

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

**If `NEEDS_BOOTSTRAP=0`:** Skip directly to the sentinel creation below.

**If `NEEDS_BOOTSTRAP=1`:** Run the auto-derivation block, passing `$ARGUMENTS` as `$1`:

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

Read `AUTO_NAME` from the output and feed it as `$1` into the bootstrap execution block:

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
.claude/.autopilot-finished
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

Read `pwd` output. The new directory is the project root for ALL subsequent steps. If the bootstrap script exits non-zero, surface the error and stop the pipeline (do NOT create the sentinel — there is nothing to clean up since the sentinel was never created).

---

**IMPORTANT — Sentinel file:** Now create `.claude/.autopilot-active` (in the possibly-new cwd) to prevent the Stop hook from double-triggering the test/doc agents. At the end of the run (Step 5), the cleanup replaces it with a `.claude/.autopilot-finished` marker that the hook consumes on its next fire to save the run's fingerprint — this covers single-turn runs where the hook never fires while the sentinel exists. Note: stale sentinels older than 2 hours are auto-cleaned by the Stop hook, so a crash won't permanently block agent triggers.

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

## Step 1.75: Branch Creation

Before delegating to the engineer, create a feature branch from the plan's frontmatter (id + type) so engineer-written changes land off `main`/`master`. Run the block below with the plan file path passed as `$1`.

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

Read `BRANCH_ACTION` from output:
- `skip-not-in-repo` or `skip-already-on-feature:*` → continue silently to Step 2.
- `created:*` → continue to Step 2 and mention the new branch in the final summary.
- exit 2 (branch exists) → STOP the pipeline. **Before exiting, remove the autopilot sentinel** so subsequent runs aren't blocked by it:

```bash
rm -f .claude/.autopilot-active
```

Then surface the error message verbatim to the user and stop. Do NOT proceed to Step 2.

## Step 2: Implement

Delegate to the **engineer** subagent:
- Read the plan from Step 1
- Read the existing codebase to understand patterns and conventions
- Implement everything specified in the plan with production-grade quality
- Update the plan status to `implemented` when done

## Step 2.5: Review

Delegate to the **reviewer** subagent to adversarially critique the Step 2 diff before tests run:
- It reviews the working-tree diff (`git diff HEAD` plus untracked files) against `.claude/CLAUDE.md` standards and the plan's `## Acceptance Criteria` (if present)
- Its final output line is machine-readable: `REVIEW_VERDICT=approve BLOCKERS=0` or `REVIEW_VERDICT=changes-requested BLOCKERS=<n>`

Parse that final line and apply the bounded fix loop:

1. `REVIEW_VERDICT=approve` (or `BLOCKERS=0`) → record `review: approved` and continue to Step 3.
2. Otherwise, delegate to the **engineer** subagent with the reviewer's **Blockers** list as the fix brief — fix ONLY the listed blockers, no scope creep — then delegate to the reviewer again and re-parse its final line.
3. Hard cap: at most **2** fix/re-review iterations after the initial review. If blockers remain after the cap, record `review: blockers-remaining` and continue to Step 3 anyway — a hands-free pipeline must terminate. This outcome feeds the Step 5 summary and, when `--deliver` was passed, makes Step 4.5 open the PR as a **draft** with the remaining blockers listed in the body.

WHY the loop lives in this command and not in the reviewer agent: agents are stateless single-shot subagents; orchestration and loop caps belong in the command layer, exactly as the branch-creation retry budget lives in the calling command rather than in the engineer.

## Step 3: Test

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

## Step 4.5: Deliver (only when `--deliver`/`--deploy` was passed)

Runs ONLY if Flag Parsing set `DELIVER=1`. If `DELIVER=0`, skip this entire step — nothing touches the remote — and record in the Step 5 summary: `Delivery: skipped (no --deliver flag). Deliver manually with: /autopilot-from docs --deliver`.

### Step 4.5a: Compose the commit message and PR body

Before running any git command, write two files under `${TMPDIR:-/tmp}` (outside the repo, so `git add -A` can never stage them):

1. **Commit message** → `${TMPDIR:-/tmp}/autopilot-commit-msg.txt`. Subject is a Conventional Commit derived from the plan frontmatter: map `type:` `feature`/`design` → `feat`, `bugfix` → `fix`, `refactoring` → `refactor`, anything else → `chore`. Format: `{cc-type}: {slug with hyphens as spaces} ({PLAN-ID})`, e.g. `feat: add auth (PLAN-007)`. Body: the plan's `summary:` line. **NO AI-attribution trailer** — do NOT use the Bash tool's HEREDOC commit example, which appends `Co-Authored-By: Claude …`; that line must not appear in any form.

2. **PR body** → `${TMPDIR:-/tmp}/autopilot-pr-body.md`. Synthesize from the plan file:
   - **Goals** — from `## Goals & Non-Goals` (or `## Task` for lightweight plans)
   - **Test summary** — from the qa-expert Step 3 report, or the `skipped (markdown-only)` note
   - **Verification** — include only if a verification result exists for this run; omit the section otherwise
   - **Rollback** — from `## Rollback Strategy`, if the plan has one
   - **Review blockers** — only if Step 2.5 recorded `review: blockers-remaining`: list the remaining blockers verbatim
   - No AI-attribution anywhere in the body.

### Step 4.5b: Commit and guarded push

Run with the commit message file path as `$1`:

```bash
# Inputs: $1 = path to the composed commit message file.
COMMIT_MSG_FILE="$1"

# Preconditions — degrade to a recorded skip, never a crash.
command -v gh >/dev/null 2>&1 || { echo "DELIVER=skip-no-gh"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "DELIVER=skip-no-auth"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "DELIVER=skip-not-in-repo"; exit 0; }
git remote get-url origin >/dev/null 2>&1 || { echo "DELIVER=skip-no-remote"; exit 0; }

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "DELIVER=skip-on-default-branch"; exit 0
fi

# Stage everything the pipeline produced on this branch.
git add -A
# The autopilot sentinel/finished marker (and local settings, if present) are runtime
# state, never content — keep them out of the commit in repos whose .gitignore predates them.
git reset -q -- .claude/.autopilot-active .claude/.autopilot-finished .claude/settings.local.json 2>/dev/null || true

# WHY test the index instead of inferring from commit's exit code: `git commit`
# also fails on an unreadable message file or a failing pre-commit hook — reporting
# those as "nothing-to-commit" would swallow a real error and leave staged work behind.
if git diff --cached --quiet; then
  echo "DELIVER=nothing-to-commit"
  # Still push if the branch has unpushed commits from an earlier step (e.g. a resume),
  # but never on a clean, fully-pushed branch.
  ahead=$(git rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo 0)
  if [ "${ahead:-0}" -gt 0 ]; then
    git push -u origin "$branch" || { echo "DELIVER=push-failed"; exit 1; }
    echo "DELIVER=pushed:$branch"
  fi
else
  # WHY guard the push: only push when this run actually created a commit.
  git commit -q -F "$COMMIT_MSG_FILE" || { echo "DELIVER=commit-failed"; exit 1; }
  git push -u origin "$branch" || { echo "DELIVER=push-failed"; exit 1; }
  echo "DELIVER=pushed:$branch"
fi
```

Read the `DELIVER=` output:
- Any `skip-*` → record it verbatim in the Step 5 summary and skip the rest of Step 4.5.
- `commit-failed` (exit 1) → surface git's error (message file unreadable, pre-commit hook failure, etc.), record `DELIVER=commit-failed` in the summary, and skip Step 4.5c. Staged work is left intact for the human. Do NOT retry.
- `push-failed` (exit 1) → surface git's error, record `DELIVER=push-failed` in the summary, and skip Step 4.5c. Do NOT retry.
- `pushed:*` → proceed to Step 4.5c.
- `nothing-to-commit` with no `pushed:` line → still proceed to Step 4.5c: an earlier run may have pushed without opening the PR, and the block there handles both "no upstream" and "PR already exists".

### Step 4.5c: Open the PR

PR title = the commit subject from Step 4.5a. Mode: `draft` if and only if Step 2.5 recorded `review: blockers-remaining`; otherwise `ready`. Run with those as arguments:

```bash
# Inputs: $1 = PR title, $2 = path to the composed PR body file, $3 = "draft" or "ready".
PR_TITLE="$1"
PR_BODY_FILE="$2"
PR_MODE="$3"

# The branch must exist on the remote before a PR can reference it.
git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || { echo "DELIVER=skip-pr-no-upstream"; exit 0; }

# Reuse an existing PR rather than erroring on a resumed run.
if gh pr view >/dev/null 2>&1; then
  echo "DELIVER=pr-already-exists"
  gh pr view --json url --jq .url
  exit 0
fi

if [ "$PR_MODE" = "draft" ]; then
  gh pr create --draft --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
else
  gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
fi
echo "DELIVER=pr-created:$PR_MODE"
```

Record the final `DELIVER=` line and the PR URL (printed by `gh pr create`/`gh pr view`) for the Step 5 summary, then clean up the composed files:

```bash
rm -f "${TMPDIR:-/tmp}/autopilot-commit-msg.txt" "${TMPDIR:-/tmp}/autopilot-pr-body.md"
```

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

### Review
- Verdict: {approved | approved-after-fixes | blockers-remaining ({n} blockers)}
- Fix/re-review iterations used: {0–2}

### Tests (if ran)
- Tests written: {count}
- Test files: {list}
- {one of the following lines, depending on whether Step 3 ran:}
  - `All passing: {yes/no}` (when qa-expert ran)
  - `Skipped: markdown-only change set, no automated tests applicable` (when Step 3 was bypassed)

### Documentation Updated
- {list of docs updated}

### Delivery
- {one of the following, depending on flags and outcome:}
  - `Skipped (no --deliver flag). Deliver manually with: /autopilot-from docs --deliver`
  - `{final DELIVER=... outcome}` plus the PR URL and mode (draft/ready) when a PR was opened

### Issues / Warnings
- {anything that needs human attention}
```

Now hand off to the Stop hook and remove the sentinel (must be the very last action):
```bash
# WHY the finished marker: a single-turn autopilot run creates and removes the
# sentinel inside one turn, so the Stop hook's sentinel bypass never fires and
# no fingerprint is saved — the next Stop would re-trigger qa/doc agents on work
# this run already did. This command cannot save the fingerprint itself (the
# fingerprint file is keyed by session_id, which only the hook receives), so the
# marker tells the hook's next fire to save it and skip. The hook consumes the
# marker on first sight.
touch .claude/.autopilot-finished
rm -f .claude/.autopilot-active
```

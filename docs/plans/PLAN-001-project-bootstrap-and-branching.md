---
id: PLAN-001
date: 2026-05-02
status: implemented
type: feature
mode: manual
summary: Add project bootstrapping (auto-create new project dir on empty cwd) and automatic git feature-branch creation before the engineer subagent runs.
---

## Context & Motivation

The repository at `C:\Users\saura\OneDrive\Documents\cursor_projects\claude-code-setup` ships five slash commands (`build-plan`, `review-plan`, `implement`, `autopilot`, `autopilot-from`) and four subagents (`planner`, `engineer`, `qa-expert`, `doc-maintainer`) installed globally to `~/.claude/` via `install.sh`. The slash commands are markdown files that Claude reads and executes step-by-step using its Bash, Read, Write, and Edit tools.

Today the pipeline assumes the user is already inside an existing project root with a git repo. Two friction points fall out of that assumption:

1. **Cold-start friction.** A user running `/build-plan` or `/autopilot` from an empty scratch directory (e.g. `~/projects/scratch/`) gets a plan written to `./docs/plans/` of an unrelated parent and code scaffolded in the wrong place. There is no detection of "this is not a project yet" — see `.claude/commands/build-plan.md` Phase 1 (line 7) and `.claude/commands/autopilot.md` Step 1 (line 13), neither of which has a precondition check.

2. **No git hygiene.** When the engineer subagent runs (`.claude/commands/implement.md` Step 3 line 86, `.claude/commands/autopilot.md` Step 2 line 34, `.claude/commands/autopilot-from.md` Step 2 line 46), it writes files into the working tree of whatever branch the user happened to be on — typically `main`/`master`. The engineer does not commit; the user commits later. But because the working-tree changes land on `main`/`master`, there is no separation between in-flight work and the trunk, and the user's eventual commit goes straight onto trunk — breaking normal team workflow (PRs, code review, reverting a single feature).

This plan adds those two behaviors as edits to existing markdown command files. No new code is introduced. After the user re-runs `install.sh`, both behaviors apply globally.

## Goals & Non-Goals

### Goals

1. When `/build-plan` or `/autopilot` (or `/autopilot-from plan ...`) is invoked in a directory that looks empty/non-project, prompt the user for a project name, create `./<name>/`, `cd` into it, run `git init`, write a stack-agnostic `.gitignore`, make an initial commit on `main` containing that `.gitignore`, then continue the pipeline with the new directory as project root.
2. Before the engineer subagent runs in `/implement`, `/autopilot` Step 2, and `/autopilot-from implement` (or `/autopilot-from plan` after planning), automatically create and check out a feature branch named `<type-prefix>/<plan-id>-<slug>` from `main`/`master`.
3. The branching logic skips silently when (a) not in a git repo or (b) already on a non-main/master branch. It bails loudly when the target branch already exists.
4. Bootstrapping does not run inside `/implement`, `/review-plan`, `/autopilot-from test`, or `/autopilot-from docs` — those stages presume the project already exists.
5. After the user re-runs `install.sh`, existing flows in established projects (running `/implement PLAN-005` on a feature branch in a real repo) behave identically to today. Backward compatibility is non-negotiable.
6. All edits are confined to existing command files where possible. New files require explicit justification.
7. Cross-platform: the embedded shell snippets work on Git Bash on Windows and on macOS/Linux. POSIX only — no PowerShell-specific syntax in the prescribed steps.

### Non-Goals

- Auto-commit of generated code at the end of implementation.
- Auto-push to a remote.
- Auto-PR creation (gh, glab, etc.).
- Branch deletion or cleanup at any stage.
- Triggering branch creation off branch names other than `main`/`master` (e.g. `develop`, `trunk`, `dev`).
- Detection of project type / stack-aware scaffolding (the engineer agent already scaffolds during implementation; bootstrap stops at `git init` + `.gitignore` + initial commit).
- New tooling dependencies. The plan uses only `git`, POSIX shell builtins, and `find`/`ls`, all already required by `install.sh`.
- New helper shell scripts under `hooks/` or anywhere else. All logic lives inline in the command markdown.
- Renaming or restructuring existing commands.

## Assumptions & Decisions

The decisions below were finalized in the manual-mode Q&A and are inputs to this plan, not open questions.

1. **Project detection signal.** Trigger the bootstrap prompt when ALL of:
   - cwd does NOT contain any of: `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `.git/`
   - cwd has fewer than 3 non-hidden entries at top level (excluding dotfiles)

   This avoids false positives in `~`, `Documents/`, `Downloads/`, etc., while reliably catching empty bootstrap directories.

2. **Bootstrap action sequence.** Prompt for name, sanitize (lowercase, replace separators with hyphens, strip everything outside `[a-z0-9-]`, collapse runs of hyphens, trim leading/trailing hyphens, reject if empty), `mkdir <name>`, `cd <name>`, `git init`, write minimal stack-agnostic `.gitignore`, `git add .gitignore && git commit -q -m "Initial commit"`. Then the rest of the pipeline runs with the new dir as the project root.

3. **Stack-agnostic `.gitignore` content.**
   ```
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
   ```

4. **Branch slug format.** `<type-prefix>/<plan-id>-<slug>`:
   - `type: feature` → `feature/PLAN-001-add-auth`
   - `type: bugfix` → `fix/PLAN-001-fix-cors`
   - `type: refactoring` → `refactor/PLAN-001-extract-router`
   - `type: design` → `feature/PLAN-001-system-redesign` (design plans become features)

   The plan ID is part of the branch name for traceability in `git log`, PR titles, and commit messages.

5. **Branching trigger points.** Branch creation runs at the START of the implement stage in:
   - `/implement` (after Step 2 plan resolution / lightweight plan creation, before Step 3 engineer delegation)
   - `/autopilot` Step 2 (between Step 1.5 plan validation and the engineer delegation in Step 2)
   - `/autopilot-from implement` (after the plan is loaded, before engineer delegation)
   - `/autopilot-from plan` (after the plan is created and validated, before the engineer delegation; same hook point as `/autopilot` Step 2)

   It does NOT run in `/build-plan`, `/review-plan`, `/autopilot-from test`, or `/autopilot-from docs`.

6. **Skip conditions for branching, in priority order.**
   1. Not in a git repo (`git rev-parse --git-dir` exits non-zero) → skip silently.
   2. Current branch is anything other than `main` or `master` → skip silently. The user has already chosen their branch.
   3. Current branch is `main`/`master`:
      - Compute the target branch name.
      - If it already exists locally (`git rev-parse --verify <branch>` exits zero) → BAIL the pipeline with a clear message naming the branch and suggesting the user delete the old branch or supersede the plan with a new ID. Do NOT auto-suffix or force-checkout.
      - Otherwise: `git checkout -b <branch>` and continue.

7. **Lightweight plans.** The `/implement` lightweight-plan path (`.claude/commands/implement.md` lines 38–61) emits a plan with `id`, `type`, and inferred slug in frontmatter. The branching logic uses the same fields as full plans — no special case needed.

8. **Writing the project name to disk.** Stored only as the directory name. We do not persist it in `package.json`, `pyproject.toml`, etc. — language detection and scaffolding remain the engineer subagent's responsibility during implementation.

9. **Preserving the autopilot sentinel during bootstrap.** Bootstrap creates and `cd`s into a NEW directory, but the sentinel file lives at `.claude/.autopilot-active`. Both `/autopilot` and `/autopilot-from` create the sentinel in the OUTER directory before bootstrap detection. The fix: in `/autopilot` and `/autopilot-from plan`, move sentinel creation to AFTER bootstrap so it lands inside the new project. The Stop hook keys its skip on the sentinel's existence in `<cwd>/.claude/.autopilot-active`, which after `cd` is the new dir — correct behavior.

10. **Engineer agent contract.** Add a one-line precondition to `.claude/agents/engineer.md` stating: by the time you run, you may already be on a feature branch — do not check out branches yourself, do not commit. The agent already does not commit (verified by reading the file end to end), so this is a documentation tightening, not a behavior change.

## Alternatives Considered

| Alternative | Rejected Because |
|---|---|
| Add a new helper script `hooks/bootstrap-and-branch.sh` and call it from each command. | Constraints forbid new files unless justified. The logic is short enough (≤30 shell lines per concern) to inline as fenced bash blocks in markdown. A separate script also adds a `chmod +x` step in `install.sh` and another file to keep in sync with five caller commands. Inline is simpler and easier for Claude to read in context. |
| Use a `git` pre-commit hook to enforce branching. | Wrong layer — and wrong trigger. The engineer never commits (the user does, after review), so a pre-commit hook would fire only at the user's eventual commit, long after the engineer wrote files into the working tree of `main`/`master`. We want to relocate work to a feature branch BEFORE the engineer writes anything, which means acting at the slash-command layer, not the git-commit layer. |
| Detect "non-project" by `.git/` absence alone. | False positive in any new directory the user happens to be in (e.g. `~/Downloads`). The 3-file threshold + absence of recognized manifest files is a much tighter signal. |
| Auto-suffix the branch name with `-2`, `-3`, ... when one already exists. | Silently masks user error. If `feature/PLAN-001-add-auth` exists, the user almost certainly forgot to clean up a prior failed run, or they're trying to re-implement an already-implemented plan. Bailing forces the right conversation. |
| Trigger branching at the start of the engineer subagent itself (inside `agents/engineer.md`). | Subagents run in isolated context and have varied tool permissions — embedding git plumbing inside the engineer persona conflates planning concerns (what branch?) with execution concerns (write the code). The slash-command layer is the right place because it already orchestrates the pipeline. |
| Trigger bootstrap inside the planner subagent. | Same isolation argument. The planner needs to know the final project root to write `docs/plans/` correctly; doing the bootstrap in the slash-command layer ensures the planner is invoked with the correct cwd from the start. |
| Force users to opt in via a flag like `/autopilot --bootstrap`. | Defeats the purpose. The whole point is to remove cold-start friction. The detection signal is conservative enough that opt-out is the right default — and is implicit (the user can just say "no" when asked for a name, or run inside a non-empty dir). |

## Technical Design

### Architecture

Two pieces of inline logic, embedded as fenced bash blocks in command markdown, each preceded by prose telling Claude exactly when and how to evaluate the result.

```
/build-plan ─┐
/autopilot ──┼─ Phase/Step 0: Bootstrap detection ──┐
/autopilot-from plan ─┘                             │
                                                    ▼
                                       (cd into new project if bootstrapped)
                                                    │
/implement ──┐                                      │
/autopilot Step 2 ──┼─ Pre-engineer: Branch creation ─┐
/autopilot-from implement ──┘                          │
                                                       ▼
                                              engineer subagent
```

### Bootstrap detection — exact logic

The block below goes verbatim into the relevant command files (with command-specific prose around it). It uses POSIX-only shell.

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

Claude reads `NEEDS_BOOTSTRAP` from output. If `1`, it asks the user (in `/build-plan`) or auto-picks a name from the task description (in `/autopilot`, `/autopilot-from plan`).

### Bootstrap execution — exact logic

```bash
# Sanitize the proposed name. Pipeline:
#   lowercase → spaces/underscores to hyphens → strip everything outside
#   [a-z0-9-] → collapse runs of hyphens → trim leading/trailing hyphens.
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

Claude reads `pwd` output and from this point treats the new directory as the project root for all subsequent steps in the pipeline (planner writes `docs/plans/` here, engineer scaffolds here).

### Auto-derivation of project name in autopilot mode

In `/autopilot <description>` and `/autopilot-from plan <description>`, there is no human Q&A. Claude derives the name from `$ARGUMENTS` using the block below.

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

Claude reads `AUTO_NAME` from output and feeds it into the bootstrap execution block as `$1`. The pipeline is identical to user-prompt sanitization (see "Bootstrap execution"), so a name auto-derived here and a name typed by the user pass through the same normalization.

Example: `/autopilot Build a URL shortener with Postgres` → `AUTO_NAME=build-a-url-shortener`.

### Branch creation — exact logic

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

Claude reads `BRANCH_ACTION` from output:
- `skip-not-in-repo` or `skip-already-on-feature:*` → continue silently to engineer.
- `created:*` → mention in the user-facing summary that a feature branch was created.
- `exit 2` (branch exists) → STOP the pipeline. In `/autopilot` and `/autopilot-from` flows, run `rm -f .claude/.autopilot-active` BEFORE surfacing the error so the sentinel does not block subsequent runs (the Stop hook's 2-hour auto-clean is only a safety net, not the primary path). Then surface the error message verbatim to the user.

### Engineer agent contract update

`.claude/agents/engineer.md` already does not run `git checkout` or `git commit`. We add one prose paragraph after the existing "How You Work" section item 6, explicitly stating the precondition. This is a doc tightening, not a behavior change.

### Sentinel-file ordering in autopilot

Current `.claude/commands/autopilot.md` (line 8) creates the sentinel at the very top. After this plan, the sequence becomes:

1. (no sentinel yet) Run bootstrap detection. If bootstrap fires, `cd` into new dir.
2. Create `.claude/.autopilot-active` in the (possibly new) cwd.
3. Step 1: Plan.
4. Step 1.5: Validation.
5. Run branch creation logic.
6. Step 2: Engineer.
7. ...remaining steps.
8. Remove sentinel.

This way the sentinel is correctly placed inside the project root the rest of the pipeline operates on.

For `/autopilot-from`, the sentinel placement depends on the starting stage:
- `plan`: same as `/autopilot` — sentinel created after bootstrap.
- `implement`/`test`/`docs`: bootstrap is not run; sentinel is created at the top of the existing flow as today.

## Implementation Steps

| Step | Description | Dependencies | Estimated Effort |
|------|-------------|--------------|------------------|
| 1 | Edit `.claude/commands/build-plan.md`: add a new "Phase 0: Bootstrap Detection" section before the existing "Phase 1: Discovery" (currently line 7). The phase contains the detection block, an interactive prompt to the user ("What would you like to call this project? I'll create `./<name>/` and treat it as the project root."), name sanitization, the bootstrap execution block, and a sentence telling Claude that all subsequent paths in this command are relative to the new cwd. If `NEEDS_BOOTSTRAP=0`, skip Phase 0 silently and proceed to Phase 1 unchanged. | None | 30 min |
| 2 | Edit `.claude/commands/autopilot.md`: move sentinel creation (currently lines 5–9) to AFTER a new "Step 0: Bootstrap Detection" section. Step 0 runs the detection block and, if triggered, auto-derives the project name from `$ARGUMENTS` (first 4 words, sanitized) and runs the bootstrap execution block without prompting. Document this in prose so Claude knows there is no human Q&A here. After bootstrap (or if skipped), proceed to sentinel creation, then Step 1, etc. | Step 1 (review the prose pattern for re-use) | 30 min |
| 3 | Edit `.claude/commands/autopilot-from.md`: only run bootstrap detection when the starting stage is `plan` (mirror Step 2's logic — sentinel-after-bootstrap, auto-derive name from `$ARGUMENTS`). For starting stages `implement`, `test`, `docs`, do NOT run bootstrap; create sentinel at top as today. | Step 2 | 25 min |
| 4 | Edit `.claude/commands/implement.md`: insert a new "Step 2.5: Branch Creation" section between Step 2 (complexity check / lightweight plan) and Step 3 (delegate to engineer). The block runs the branch-creation logic with the resolved plan file path as input. On `BRANCH_ACTION=created:*` continue. On the branch-already-exists error, STOP the pipeline and surface the message to the user verbatim. The Step 2.5 prose must explicitly handle two plan sources: existing PLAN-NNN passed in $ARGUMENTS (resolve to `./docs/plans/PLAN-NNN-*.md` via glob) and lightweight plans just created in Step 2 (path is known from the immediately-prior write). | None | 40 min |
| 5 | Edit `.claude/commands/autopilot.md`: insert a new "Step 1.75: Branch Creation" section between Step 1.5 (Plan Validation) and Step 2 (Implement). Same logic as `/implement` Step 2.5. On branch-already-exists, STOP the pipeline AND remove the sentinel (`rm -f .claude/.autopilot-active`) before exiting, so subsequent runs aren't blocked by a stale sentinel. | Step 4 (re-use the embedded block) | 25 min |
| 6 | Edit `.claude/commands/autopilot-from.md`: insert the same "Branch Creation" step between Step 1.5 (Plan Validation) and Step 2 (Implement) when the starting stage is `plan` or `implement`. For starting stages `test` or `docs`, do NOT run branch creation. Same sentinel-cleanup-on-bail behavior as Step 5. | Step 5 | 25 min |
| 7 | Edit `.claude/agents/engineer.md`: add a 2-3 sentence paragraph at the end of "How You Work" stating: (a) by the time you run, the calling slash command may have placed you on a feature branch — do not run `git checkout`, do not switch branches, (b) do not auto-commit or auto-push your work; the user will commit when ready. Phrase it as a precondition, not a rule, since the engineer already complies. | None | 10 min |
| 8 | Update `README.md`: add a "Project Bootstrapping" subsection under "Usage" describing the empty-cwd detection and the prompt. Add a "Git Branching" subsection describing the auto-checkout, the type-prefix mapping, the skip conditions, and the bail-on-conflict behavior. Update the "Smart /implement" subsection to mention branch creation as part of the flow. | Steps 1–6 (so the documented behavior matches the implementation) | 25 min |
| 9 | Update `docs/architecture.md`: revise the "Data Flow" section's Manual Mode and Autopilot Mode blocks to show the bootstrap step at the top and the branch-creation step between plan validation and engineer. Add a "Bootstrap Detection" subsection under "Components" briefly summarizing the trigger condition. Add a "Branch Creation" subsection summarizing the trigger and skip conditions. | Step 8 | 20 min |
| 10 | Verify `install.sh`: confirm that no new files were introduced (per the constraint). The five command files and the engineer agent file are already copied. No installer change needed unless steps 1–7 added a new file (they did not). Add a comment in `install.sh` only if a behavioral note is helpful — otherwise leave untouched. | Steps 1–7 | 5 min (verification only) |
| 11 | Smoke-test on Git Bash on Windows: in an empty temp dir, run `bash -c` simulations of each embedded block (detection, sanitize, bootstrap, branch creation with parsing) and verify the output keys (`NEEDS_BOOTSTRAP`, `BOOTSTRAPPED`, `BRANCH_ACTION`) appear as specified. Document any portability issues (e.g. `git init -b main` not supported on git <2.28) and confirm the fallback handles them. | Steps 1–7 | 30 min |
| 12 | End-to-end smoke test: from an empty scratch directory, run the full `/autopilot "build a tiny CLI tool"` flow against a stub task, verify a project is created, sentinel placement is correct, plan is written inside the new dir, branch is created with the right name, and engineer runs on the feature branch. | Step 11 | 30 min |

## Affected Components

### Source code (the slash command markdown files and one agent file)

- `.claude/commands/build-plan.md` — add Phase 0 (bootstrap detection + interactive prompt).
- `.claude/commands/autopilot.md` — add Step 0 (bootstrap detection + auto-derive name); move sentinel creation; add Step 1.75 (branch creation).
- `.claude/commands/autopilot-from.md` — add bootstrap detection conditional on starting stage; add branch creation conditional on starting stage.
- `.claude/commands/implement.md` — add Step 2.5 (branch creation).
- `.claude/agents/engineer.md` — add precondition paragraph about feature branch and no-auto-commit.

### Tests
- No automated tests exist in this repo (no test runner configured). Smoke tests are manual; see Implementation Steps 11–12 and the Testing Strategy section.

### Configs
- None. `.claude/settings.json`, `.claude/settings.local.json` unchanged.

### Docs
- `README.md` — bootstrap and branching subsections.
- `docs/architecture.md` — data flow + components updates.

### Infrastructure / installer
- `install.sh` — no change required (no new files).

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| User invokes `/autopilot` or `/build-plan` from `~` or `~/Documents` and the detection misfires, creating an unwanted child directory. | Low | Medium | The 3-file threshold + manifest absence is conservative; `~` and `~/Documents` typically have many entries. In `/autopilot` mode the name is auto-derived and surfaced as `AUTO_NAME=<name>` and `BOOTSTRAPPED=<name>`; in `/build-plan` mode the user sees the prompt before any directory is created and can decline by typing nothing or canceling. Recovery in either case: `cd ..; rm -rf <name>` (the new dir contains only `.gitignore` plus an initial commit; nothing is lost). Document the recovery in README. |
| User picks a project name with shell metacharacters (`$`, `;`, backticks) → command injection. | Low | High | The sanitize step strips everything except `[a-z0-9-]` and rejects empty results. The proposed name is also passed as a single argument (`$1`), never interpolated raw into a command. |
| Branch creation succeeds, then engineer fails or crashes mid-implementation, leaving the user on a feature branch with zero commits. | Medium | Low | Document the recovery in README's Branching subsection: `git checkout main && git branch -D <branch>` to roll back. The branch is empty (no commits) so deletion is safe and loses no work. Engineer failures already require human inspection today, so this only adds one extra cleanup line. |
| Symlinked or worktree git setups: `git rev-parse --git-dir` returns a path outside cwd. | Low | Low | We only check the exit code, not the output, of `git rev-parse --git-dir`. Worktrees and symlinks return 0 and report a non-standard path, which we ignore. The detection ("are we in a repo?") is correct in all observed git layouts. |
| `git init -b main` is unsupported on git <2.28. | Medium | Low | Bootstrap script falls back to `git init` and renames `master` to `main` via `git branch -M main` if the default differs. |
| Plan file frontmatter has the type or id on a line in an unexpected form (quoted, capitalized, with a trailing comment). | Low | Medium | The awk output is post-processed: `tr -d '"' | tr -d "'"` strips surrounding quotes, and the type is additionally lowercased. So `type: "Feature"`, `type: Feature`, and `type: feature` all parse to `feature`. Lightweight plans (`.claude/commands/implement.md` lines 44–51) and full plans (`.claude/agents/planner.md` lines 49–57) write unquoted lowercase by template. If `id:` or `type:` is entirely missing the script exits with `ERROR: could not parse id/type` — fail loud. If the type is unrecognized (e.g. `type: experimental`), the case statement falls through to the `feature/` prefix — a safe default rather than a hard failure. |
| `/autopilot-from implement PLAN-001` is called with a plan whose filename slug has uppercase or unusual characters. | Low | Low | The sed strip on `^${plan_id}-` is case-sensitive — plan IDs are uppercase by convention (`PLAN-001`) and filenames match. The slug after the prefix is then used verbatim in the branch name. Git accepts mixed-case branch names, so this is harmless. If a plan is created with a lowercase ID or truly bizarre filename characters (spaces, slashes), the sed prefix-strip will not match and the branch name will be malformed; `git checkout -b` will reject it with git's own error, which is the correct outcome. |
| Branch already exists → bail leaves autopilot sentinel in place, blocking the next run for up to 2 hours. | Medium | Medium | Step 5 and Step 6 explicitly `rm -f .claude/.autopilot-active` BEFORE exiting on bail. The Stop hook's existing 2h auto-clean is the second safety net. |
| Bootstrap creates a directory the user already had open in another tool (IDE, editor) → confusion about which dir is "the project". | Low | Low | Bootstrap explicitly prints `pwd` after `cd`; Claude surfaces this in its next response. The user sees the new path before any files are written there. |
| Re-running `/autopilot` in the same project after a successful run, with the same plan ID still in `docs/plans/`, causes branch-already-exists bail. | Medium | Low | This is the *correct* failure mode — running autopilot twice on the same plan was never the intended workflow. The bail message tells the user how to recover (delete branch or supersede the plan). |
| Cross-platform: `wc -l | tr -d ' '` and `awk '/^---$/{f++; next}'` syntax differences between BSD and GNU. | Low | Low | These idioms work identically on Git Bash for Windows (which uses GNU coreutils + GNU awk) and on macOS (BSD awk supports the same constructs used here — basic field splitting, no GNU extensions). Validated in Step 11. |
| Bootstrap's `git commit -q -m "Initial commit"` fails on a machine where `git config --global user.email` and/or `user.name` are unset (fresh dev container, new VM, CI runner). | Low | Medium | Detect before committing: `git config --get user.email >/dev/null && git config --get user.name >/dev/null`. If either is missing, surface a clear error ("Bootstrap aborted: git identity not configured. Run `git config --global user.email \"you@example.com\" && git config --global user.name \"Your Name\"` and retry") and exit 1 BEFORE running `git commit`. Do NOT inject placeholder identity (e.g. `claude@local`) — that would silently attach junk authorship to the user's first real commit. |

## Rollback Strategy

All changes are confined to markdown files. To revert:

1. `git checkout HEAD~1 -- .claude/commands/build-plan.md .claude/commands/autopilot.md .claude/commands/autopilot-from.md .claude/commands/implement.md .claude/agents/engineer.md README.md docs/architecture.md`
2. Re-run `install.sh` to push the reverted files to `~/.claude/`.

The runtime side effects of an in-progress invocation can also be undone:

- **Bootstrap created a directory the user didn't want.** `cd ..; rm -rf <name>` (the dir contains only an initial commit and the `.gitignore` it wrote — nothing else has been written yet).
- **Branch was created and engineer failed before writing any files.** `git checkout main && git branch -D <branch>`. The branch has no commits and no working-tree changes — no work is lost.
- **Branch was created and engineer wrote code (uncommitted, since the engineer never commits).** To keep the work: stay on the feature branch and commit when ready (`git add -A && git commit -m "..."`). To discard: `git checkout -- . && git clean -fd && git checkout main && git branch -D <branch>`. Do not `git stash` then `git checkout main` — the stash is decoupled from the branch and you'd lose the branch-stash association.

No database, no infrastructure, no irreversible side effects. The plan is fully reversible.

## Testing Strategy

This repo has no test runner. Verification is manual and split across two layers.

### Layer 1: Block-level shell verification

For each embedded shell block (detection, sanitize, bootstrap execution, branch creation), copy the block into a Git Bash session in an isolated `mktemp -d` directory and verify:

- **Detection in empty dir:** `NEEDS_BOOTSTRAP=1`.
- **Detection with package.json:** `NEEDS_BOOTSTRAP=0`.
- **Detection with .git/:** `NEEDS_BOOTSTRAP=0`.
- **Detection with 5 random dotfiles + 0 non-hidden entries:** `NEEDS_BOOTSTRAP=1`.
- **Detection with 4 non-hidden entries:** `NEEDS_BOOTSTRAP=0`.
- **Sanitize "My Project!"** → `my-project`.
- **Sanitize "My  Project!!!"** (double space, exclamation runs) → `my-project` (hyphen-collapse and trailing-hyphen-trim verified).
- **Sanitize "---weird---name---"** (leading and trailing hyphens) → `weird-name` (trim verified).
- **Sanitize "../etc/passwd"** → `etcpasswd` (path separators stripped, no traversal possible).
- **Sanitize "$(rm -rf ~)"** → `rm-rf`. The safety property is NOT that `mkdir` rejects this string — `mkdir rm-rf` succeeds and creates a harmless literal directory. The safety property is that the sanitized string is passed as a single positional argument (`"$1"` quoted) and never re-interpolated as shell, so the original `$(...)` substitution cannot execute. Verify by tracing the dataflow: prompt input → tr/sed pipeline → `mkdir "$SANITIZED"` (quoted) → no eval, no backtick expansion at any stage.
- **Sanitize "   "** → empty → script exits 1 with error.
- **Bootstrap with git identity unset:** unset `user.email` and/or `user.name` (in a temp `HOME=$(mktemp -d)`), run bootstrap → expect exit 1 with the "git identity not configured" error and the recovery instructions; verify the partially-created directory contains only `.gitignore` (no commit).
- **Auto-derive from "Build a URL shortener with Postgres":** outputs `AUTO_NAME=build-a-url-shortener` (first 4 words taken).
- **Auto-derive from "fix":** outputs `AUTO_NAME=fix` (single-word input, no truncation).
- **Auto-derive from "" (empty):** outputs `AUTO_NAME=new-project` (fallback).
- **Bootstrap on a fresh dir:** new subdir created, `git init` ran, `.gitignore` written, initial commit on `main` containing `.gitignore`, `pwd` prints new path.
- **Branch creation in a non-repo:** outputs `BRANCH_ACTION=skip-not-in-repo`.
- **Branch creation on `feature/whatever`:** outputs `BRANCH_ACTION=skip-already-on-feature:feature/whatever`.
- **Branch creation on `main` with valid plan, branch doesn't exist:** outputs `BRANCH_ACTION=created:feature/PLAN-001-test`.
- **Branch creation on `main` with valid plan, branch already exists:** exit 2, error message includes branch name and resolution hint.
- **Branch creation on `master`:** same behavior as `main`.
- **Branch creation, plan type=bugfix:** prefix is `fix/`.
- **Branch creation, plan type=refactoring:** prefix is `refactor/`.
- **Branch creation, plan type=design:** prefix is `feature/`.
- **Branch creation, plan type=unknown:** prefix defaults to `feature/`.
- **Branch creation, plan file with no `type:` field:** exits with `ERROR: could not parse id/type`.
- **Branch creation, plan with `type: "Feature"` (quoted, capitalized):** prefix is `feature/` — quote stripping and lowercasing both fire.
- **Branch creation, plan with `type: experimental` (unrecognized):** prefix defaults to `feature/` — case-statement fall-through.

### Layer 2: End-to-end command flow

After re-running `install.sh`, exercise the full flows:

1. **Cold start `/build-plan`:** in `mktemp -d`, run `/build-plan add a hello world cli` → expect prompt for name, accept, verify project created, plan written inside, no branch action (build-plan does not branch).
2. **Cold start `/autopilot`:** in `mktemp -d`, run `/autopilot build a hello world cli` → expect auto-derived name, project created, plan + branch created, engineer runs.
3. **Warm `/implement` on existing repo on `main`:** in an existing repo, run `/implement PLAN-005` → expect feature branch created, engineer runs.
4. **Warm `/implement` on existing repo on `feature/x`:** run `/implement PLAN-005` → expect skip-already-on-feature, engineer runs on `feature/x`.
5. **Branch already exists:** create `feature/PLAN-005-foo`, run `/implement PLAN-005` (with PLAN-005 having matching slug) → expect bail with error.
6. **`/autopilot-from test PLAN-005`:** run in any state → expect no bootstrap, no branch creation, agents proceed.
7. **`/autopilot-from docs`:** run in any state → expect no bootstrap, no branch creation, doc-maintainer proceeds.
8. **Re-running `install.sh`:** confirm no new files copied, no errors, behavior identical after reinstall.

### Edge cases explicitly covered

- Empty inputs (empty project name, empty $ARGUMENTS in autopilot mode).
- Names with shell metacharacters, path separators, Unicode.
- Pre-existing target directories.
- Pre-existing target branches.
- Non-git working directories.
- Detached-HEAD state (`git rev-parse --abbrev-ref HEAD` returns `HEAD` — falls through to "not on main/master" → skip).
- git versions <2.28 lacking `-b main`.
- Plans missing one or both of `id:`/`type:` frontmatter fields.

## Success Criteria

1. Running `/build-plan` in an empty `mktemp -d` produces the prompt and, after a name is given, leaves the user with a new git-initialized subdirectory containing `docs/plans/PLAN-001-*.md`.
2. Running `/autopilot "build a thing"` in an empty `mktemp -d` auto-derives the name `build-a-thing`, creates the directory, runs the full pipeline inside it, and ends on a feature branch (`feature/PLAN-001-build-a-thing`) with the engineer's uncommitted changes in the working tree (the engineer does not commit; the user commits when ready).
3. Running `/implement PLAN-NNN` from `main` in an existing project creates a feature branch named `<prefix>/PLAN-NNN-<slug>` before the engineer runs, where prefix is `feature`/`fix`/`refactor` based on plan type.
4. Running `/implement PLAN-NNN` from a non-main/master branch leaves the branch untouched and proceeds.
5. When the target branch already exists, the pipeline stops with a clear error message naming the branch and the recovery options, no engineer subagent is invoked, and (in `/autopilot` and `/autopilot-from` flows only) the autopilot sentinel is removed before exit. In `/implement` flows there is no sentinel to clean up.
6. `/build-plan`, `/review-plan`, `/autopilot-from test`, `/autopilot-from docs` do not create branches under any circumstance.
7. `/build-plan`, `/review-plan`, `/implement`, `/autopilot-from implement`, `/autopilot-from test`, `/autopilot-from docs` do not bootstrap directories under any circumstance.
8. After re-running `install.sh`, all of the above hold in any project where the user installs this version, and existing established projects (real repo, real branches, real PLAN-NNN files) behave identically to the prior version when no bootstrap or branching action is triggered.
9. The README and `docs/architecture.md` accurately describe both new behaviors, including skip conditions and recovery paths, with no description matching the OLD (pre-change) behavior.
10. No new files have been added to the repo or to `~/.claude/` (verified by `diff` of `find ~/.claude -type f` before and after `install.sh`, ignoring `settings.local.json` and runtime logs/fingerprints/sentinels).

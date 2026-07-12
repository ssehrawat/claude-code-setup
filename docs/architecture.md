# Architecture

## Overview

This project is a global Claude Code configuration that installs slash commands, expert subagents, and a Stop hook into `~/.claude/`. It adds a multi-agent development pipeline to any project Claude Code is used with.

There is no runtime application. The "architecture" is the interaction between Claude Code's hook system, the slash commands that invoke subagents, and the dedup mechanism that prevents redundant agent runs.

## Components

### Slash Commands (`commands/`)

User-facing entry points registered as Claude Code slash commands.

| Command | File | Purpose |
|---------|------|---------|
| `/build-plan` | `commands/build-plan.md` | Interactive Q&A with planner agent |
| `/review-plan` | `commands/review-plan.md` | Review/approve a plan (never implements) |
| `/review` | `commands/review.md` | One-shot adversarial code review of the working tree (report only) |
| `/implement` | `commands/implement.md` | Smart implement with complexity detection |
| `/autopilot` | `commands/autopilot.md` | Full pipeline: plan, implement, review, test, docs (+ opt-in delivery) |
| `/autopilot-from` | `commands/autopilot-from.md` | Resume pipeline from any stage |

### Subagents (`agents/`)

Specialized personas delegated to via Claude Code's subagent system. Each agent runs in its own context to preserve the main session's context window.

| Agent | File | Triggered By |
|-------|------|-------------|
| planner | `agents/planner.md` | `/build-plan`, `/autopilot` Step 1 |
| engineer | `agents/engineer.md` | `/implement`, `/autopilot` Step 2 |
| reviewer | `agents/reviewer.md` | `/review`, `/autopilot` Step 2.5 |
| qa-expert | `agents/qa-expert.md` | Stop hook, `/autopilot` Step 3 |
| doc-maintainer | `agents/doc-maintainer.md` | Stop hook, `/autopilot` Step 4 |

The reviewer is deliberately NOT wired into the Stop hook: the hook runs its agents in parallel, but review must gate *before* docs and be able to loop with the engineer, so it lives as an ordered autopilot step (2.5) plus the manual `/review` command. Its tools exclude Write/Edit (a reviewer that can edit is a second engineer), and it pins `model: claude-opus-4-8`.

### Stop Hook (`hooks/update-docs.sh`)

The single hook registered in `settings.json` under the `Stop` event. Fires every time Claude Code finishes a response. Detects source file changes via git and triggers qa-expert + doc-maintainer.

### Installer (`install.sh`)

Copies all files to `~/.claude/`, sets execute permissions on the hook, backs up existing `settings.json`, and cleans up artifacts from previous versions (turn-lock files, session-state dirs, renamed agents).

After copying `settings.json`, the installer runs a node one-liner that re-reads `~/.claude/settings.json` and sets `remoteControlAtStartup: true`. This is patched at install time (not stored in the source `.claude/settings.json`) so the Remote Control bridge auto-starts every session without a per-session toggle, while the source settings file stays minimal.

### Settings (`settings.json`)

Registers the Stop hook. No other hooks are configured. Previous versions used a `UserPromptSubmit` hook for turn-lock dedup; that was removed in favor of fingerprint-based dedup handled entirely within the Stop hook.

The source `.claude/settings.json` in this repo does NOT contain `remoteControlAtStartup`. That key is injected into `~/.claude/settings.json` by `install.sh` after the copy step (see Installer above).

### Bootstrap Detection

Inline shell logic embedded at the top of `/build-plan`, `/autopilot`, and `/autopilot-from plan`. Triggers when ALL of the following are true: cwd contains none of `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `.git/`, and has fewer than 3 non-hidden top-level entries.

When triggered, the command sanitizes a project name (interactively prompted in `/build-plan`, auto-derived from `$ARGUMENTS` in autopilot flows), runs `mkdir <name> && cd <name>`, `git init` on `main`, writes a stack-agnostic `.gitignore`, and creates an initial commit. The rest of the pipeline runs inside the new directory.

Skipped entirely in `/implement`, `/review-plan`, `/review`, `/autopilot-from implement`, `/autopilot-from test`, and `/autopilot-from docs`.

### Branch Creation

Inline shell logic embedded between plan validation and engineer delegation in `/implement`, `/autopilot` Step 2, `/autopilot-from implement`, and `/autopilot-from plan`. Parses the plan's `id:` and `type:` from frontmatter, derives a branch name `<prefix>/<plan-id>-<slug>`, and runs `git checkout -b`.

Skip conditions (in priority order): not in a git repo (silent skip), already on a non-`main`/`master` branch (silent skip), target branch already exists (loud bail — the autopilot flows also `rm -f .claude/.autopilot-active` before exiting).

Skipped entirely in `/build-plan`, `/review-plan`, `/review`, `/autopilot-from test`, and `/autopilot-from docs`.

`/implement` has its own guard (Step 0): in a non-project cwd it refuses and redirects to `/build-plan`/`/autopilot` rather than bootstrapping — the detection block is byte-identical to `/build-plan` Phase 0 so all entry points agree on what "a project" means.

### Review Gate (autopilot Step 2.5)

Between implement and test, the reviewer subagent critiques the working-tree diff (`git diff HEAD` + untracked) against `.claude/CLAUDE.md`, emitting blocker/should-fix/nit findings and a machine-readable final line (`REVIEW_VERDICT=... BLOCKERS=<n>`) that the command parses. Blockers dispatch the engineer with the blocker list as a fix brief, then a re-review — capped at 2 fix/re-review iterations so the hands-free run always terminates. Surviving blockers are recorded as `review: blockers-remaining`, which downgrades any delivered PR to a draft. In `/autopilot-from`, the step is skipped for `test`/`docs` starts (nothing new to review on a resume).

### Delivery (autopilot Step 4.5, opt-in)

Runs only when `--deliver` (or `--deploy`, which implies it) was passed — the flags are parsed and stripped from `$ARGUMENTS` before Step 0 so they never pollute project-name derivation. Without a flag, no autopilot run touches a remote; the upfront flag is the confirmation, which preserves the "never ask" contract without a mid-run prompt.

The stage composes a Conventional Commit message and PR body from the plan (Goals, Test summary, Rollback — no AI-attribution trailer anywhere), then runs a gh-guarded shell block: preconditions (`gh` present + authenticated, in a repo, `origin` exists, not on `main`/`master`) degrade to recorded skips; the push is guarded (only after a real commit, or when the branch is ahead of upstream); a failing commit or push is a distinct terminal outcome (`commit-failed`/`push-failed` — the block tests the index with `git diff --cached --quiet` rather than inferring from commit's exit code, so a hook or message-file failure is never misreported as `nothing-to-commit`) that leaves staged work intact and skips the PR; the PR opens as a draft iff the review recorded `blockers-remaining`. In `/autopilot-from`, delivery is flag-gated, not stage-gated — a `test`/`docs` resume still delivers with the flag. Merging is always human (`--deploy`'s deploy stage is a later phase, currently a no-op beyond implying `--deliver`).

## Data Flow

### Manual Mode

```
User runs /build-plan
  -> Phase 0: bootstrap detection; if triggered, prompt for name and cd into new dir
  -> planner subagent writes docs/plans/PLAN-NNN-slug.md
  -> returns to user for review

User runs /review-plan
  -> reviews plan, approves/rejects (never implements)

User runs /implement PLAN-NNN
  -> Step 2.5: branch creation (creates feature/PLAN-NNN-slug from main/master, or skips)
  -> engineer subagent reads plan, implements code on the feature branch
  -> Claude stops
  -> Stop hook fires
  -> update-docs.sh detects source changes, computes fingerprint
  -> returns decision:block with instructions
  -> Claude spawns qa-expert + doc-maintainer in parallel
  -> agents finish, Claude stops again
  -> Stop hook fires, same fingerprint -> skip

User runs /review (optional, any time)
  -> reviewer subagent critiques the working-tree diff once, prints the report
  -> no fixes applied, no other agents invoked — the human decides
```

### Autopilot Mode

```
User runs /autopilot <description> [--deliver|--deploy]
  -> Flag parsing: strips --deliver/--deploy from $ARGUMENTS before anything reads it
  -> Step 0: bootstrap detection; if triggered, auto-derive name and cd into new dir
  -> creates .claude/.autopilot-active sentinel (in possibly-new cwd)
  -> planner runs (auto mode, self-review)
  -> main agent validates plan
  -> Step 1.75: branch creation (creates feature/PLAN-NNN-slug from main/master, or skips;
       on branch-exists bail, removes sentinel before exiting)
  -> engineer implements on the feature branch
  -> Step 2.5: reviewer critiques the diff; blockers -> engineer fix pass + re-review
       (capped at 2 iterations; surviving blockers recorded, run continues)
  -> qa-expert runs tests
  -> doc-maintainer updates docs
  -> Step 4.5 (ONLY with --deliver/--deploy): commit -> guarded push -> gh PR
       (draft iff blockers remained; without the flag, nothing touches the remote)
  -> touches .claude/.autopilot-finished marker, removes sentinel
  -> Claude stops
  -> Stop hook fires, sees the finished-marker, saves the fingerprint,
     consumes the marker -> skip (works even for single-turn runs, where
     the hook never fired while the sentinel existed)
```

## Dedup: Fingerprint Mechanism

The Stop hook can fire multiple times per turn (once per subagent return, once per follow-up). To prevent redundant agent runs:

1. Collect all uncommitted + untracked source files via `git diff --name-only HEAD` and `git ls-files --others`
2. Filter to source extensions (`.ts`, `.py`, `.rs`, `.go`, etc.)
3. Sort the file list and hash it (`md5sum`, `md5`, or `cksum` as fallback)
4. **Session baseline**: the first Stop of a session snapshots this hash to `~/.claude/hooks/.fingerprints/{session_id}.baseline` and exits — so a dirty tree that predates the session never triggers agents. Subsequent Stops that still match the baseline also exit: agents fire only on deltas made during the session.
5. Compare against `~/.claude/hooks/.fingerprints/{session_id}.fingerprint`
6. If identical, skip. If different, save new fingerprint and trigger agents.

Ordering is load-bearing: `stop_hook_active` guard → sentinel bypass → finished-marker consumption → baseline capture/compare → fingerprint dedup. The sentinel/marker paths exit before baseline capture, which is what keeps a second session quiet when it encounters another session's already-processed autopilot output.

Four layers prevent infinite loops and redundant agent runs:
- **`stop_hook_active` flag** -- Claude Code's built-in guard, set when a hook already caused continuation
- **Fingerprint file** -- same files produce same hash, so re-fires after agent runs skip
- **Autopilot sentinel** -- `.claude/.autopilot-active` short-circuits the hook during autopilot (which handles agents itself)
- **Autopilot finished-marker** -- `.claude/.autopilot-finished`, touched by autopilot cleanup and consumed by the hook's next fire, which saves the fingerprint then skips. Covers single-turn autopilot runs: Stop only fires between turns, so a run that creates and removes its sentinel inside one turn never triggers the sentinel bypass, and without the marker the first post-run Stop would re-trigger agents on already-processed work. The command cannot save the fingerprint itself -- the fingerprint file is keyed by `session_id`, which only the hook receives.

## File Layout

```
.claude/
  CLAUDE.md                  -- global code quality and convention rules
  settings.json              -- Stop hook registration (single hook)
  commands/
    build-plan.md            -- /build-plan slash command
    review-plan.md           -- /review-plan slash command
    review.md                -- /review slash command
    implement.md             -- /implement slash command
    autopilot.md             -- /autopilot slash command
    autopilot-from.md        -- /autopilot-from slash command
  agents/
    planner.md               -- planning expert persona
    engineer.md              -- coding expert persona
    reviewer.md              -- adversarial diff reviewer persona
    qa-expert.md             -- testing expert persona
    doc-maintainer.md        -- documentation expert persona
  hooks/
    update-docs.sh           -- Stop hook script
install.sh                   -- installer
README.md                    -- user-facing documentation
docs/
  architecture.md            -- this file
```

Runtime artifacts (not committed):
- `~/.claude/hooks/.fingerprints/` -- per-session `.fingerprint` (last-processed) and `.baseline` (session-start snapshot) files
- `~/.claude/hooks/update-docs.log` -- debug log
- `.claude/.autopilot-active` -- sentinel file during autopilot runs
- `.claude/.autopilot-finished` -- handoff marker from autopilot cleanup to the Stop hook (consumed on the hook's next fire)

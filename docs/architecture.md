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
| `/implement` | `commands/implement.md` | Smart implement with complexity detection |
| `/autopilot` | `commands/autopilot.md` | Full pipeline: plan, implement, test, docs |
| `/autopilot-from` | `commands/autopilot-from.md` | Resume pipeline from any stage |

### Subagents (`agents/`)

Specialized personas delegated to via Claude Code's subagent system. Each agent runs in its own context to preserve the main session's context window.

| Agent | File | Triggered By |
|-------|------|-------------|
| planner | `agents/planner.md` | `/build-plan`, `/autopilot` Step 1 |
| engineer | `agents/engineer.md` | `/implement`, `/autopilot` Step 2 |
| qa-expert | `agents/qa-expert.md` | Stop hook, `/autopilot` Step 3 |
| doc-maintainer | `agents/doc-maintainer.md` | Stop hook, `/autopilot` Step 4 |

### Stop Hook (`hooks/update-docs.sh`)

The single hook registered in `settings.json` under the `Stop` event. Fires every time Claude Code finishes a response. Detects source file changes via git and triggers qa-expert + doc-maintainer.

### Installer (`install.sh`)

Copies all files to `~/.claude/`, sets execute permissions on the hook, backs up existing `settings.json`, and cleans up artifacts from previous versions (turn-lock files, session-state dirs, renamed agents).

### Settings (`settings.json`)

Registers the Stop hook. No other hooks are configured. Previous versions used a `UserPromptSubmit` hook for turn-lock dedup; that was removed in favor of fingerprint-based dedup handled entirely within the Stop hook.

### Bootstrap Detection

Inline shell logic embedded at the top of `/build-plan`, `/autopilot`, and `/autopilot-from plan`. Triggers when ALL of the following are true: cwd contains none of `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `.git/`, and has fewer than 3 non-hidden top-level entries.

When triggered, the command sanitizes a project name (interactively prompted in `/build-plan`, auto-derived from `$ARGUMENTS` in autopilot flows), runs `mkdir <name> && cd <name>`, `git init` on `main`, writes a stack-agnostic `.gitignore`, and creates an initial commit. The rest of the pipeline runs inside the new directory.

Skipped entirely in `/implement`, `/review-plan`, `/autopilot-from implement`, `/autopilot-from test`, and `/autopilot-from docs`.

### Branch Creation

Inline shell logic embedded between plan validation and engineer delegation in `/implement`, `/autopilot` Step 2, `/autopilot-from implement`, and `/autopilot-from plan`. Parses the plan's `id:` and `type:` from frontmatter, derives a branch name `<prefix>/<plan-id>-<slug>`, and runs `git checkout -b`.

Skip conditions (in priority order): not in a git repo (silent skip), already on a non-`main`/`master` branch (silent skip), target branch already exists (loud bail — the autopilot flows also `rm -f .claude/.autopilot-active` before exiting).

Skipped entirely in `/build-plan`, `/review-plan`, `/autopilot-from test`, and `/autopilot-from docs`.

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
```

### Autopilot Mode

```
User runs /autopilot <description>
  -> Step 0: bootstrap detection; if triggered, auto-derive name and cd into new dir
  -> creates .claude/.autopilot-active sentinel (in possibly-new cwd)
  -> planner runs (auto mode, self-review)
  -> main agent validates plan
  -> Step 1.75: branch creation (creates feature/PLAN-NNN-slug from main/master, or skips;
       on branch-exists bail, removes sentinel before exiting)
  -> engineer implements on the feature branch
  -> qa-expert runs tests
  -> doc-maintainer updates docs
  -> removes sentinel
  -> Claude stops
  -> Stop hook fires, sentinel gone, fingerprint saved during bypass -> skip
```

## Dedup: Fingerprint Mechanism

The Stop hook can fire multiple times per turn (once per subagent return, once per follow-up). To prevent redundant agent runs:

1. Collect all uncommitted + untracked source files via `git diff --name-only HEAD` and `git ls-files --others`
2. Filter to source extensions (`.ts`, `.py`, `.rs`, `.go`, etc.)
3. Sort the file list and hash it (`md5sum`, `md5`, or `cksum` as fallback)
4. Compare against `~/.claude/hooks/.fingerprints/{session_id}.fingerprint`
5. If identical, skip. If different, save new fingerprint and trigger agents.

Three layers prevent infinite loops:
- **`stop_hook_active` flag** -- Claude Code's built-in guard, set when a hook already caused continuation
- **Fingerprint file** -- same files produce same hash, so re-fires after agent runs skip
- **Autopilot sentinel** -- `.claude/.autopilot-active` short-circuits the hook during autopilot (which handles agents itself)

## File Layout

```
.claude/
  CLAUDE.md                  -- global code quality and convention rules
  settings.json              -- Stop hook registration (single hook)
  commands/
    build-plan.md            -- /build-plan slash command
    review-plan.md           -- /review-plan slash command
    implement.md             -- /implement slash command
    autopilot.md             -- /autopilot slash command
    autopilot-from.md        -- /autopilot-from slash command
  agents/
    planner.md               -- planning expert persona
    engineer.md              -- coding expert persona
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
- `~/.claude/hooks/.fingerprints/` -- per-session fingerprint files
- `~/.claude/hooks/update-docs.log` -- debug log
- `.claude/.autopilot-active` -- sentinel file during autopilot runs
